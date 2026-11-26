import Foundation
import Testing
@testable import TokinoKit

/// The brief (§14) requires explicit state transitions, idempotent publishing and
/// duplicate-post prevention. These tests are the enforcement of that, so they
/// aim for exhaustiveness over the whole (state × event) matrix rather than
/// spot-checking the happy path.
@Suite("Publication state machine")
struct PublicationStateMachineTests {

    // A fixed clock. Scheduling rules compare against `now`, so pinning it keeps
    // these tests deterministic rather than quietly time-dependent.
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let future = now.addingTimeInterval(3600)
    static let past = now.addingTimeInterval(-3600)

    static let sampleFailure = PublishFailure(kind: .transient, message: "connection reset")

    /// One representative value per event case, so the matrix test can iterate
    /// every event without caring about associated values.
    static let allEvents: [PublicationEvent] = [
        .drafted,
        .submittedForReview,
        .approved,
        .rejected(reason: "not my voice"),
        .revisionRequested(note: "tighten the caption"),
        .revised,
        .scheduled(at: future),
        .rescheduled(at: future),
        .unscheduled,
        .publishStarted(idempotencyKey: "key-1"),
        .publishSucceeded(remoteID: "ig-123"),
        .publishFailed(error: sampleFailure),
        .publishOutcomeUnknown(idempotencyKey: "key-1"),
        .reconciledAsPublished(remoteID: "ig-123"),
        .reconciledAsFailed(error: sampleFailure),
        .retryRequested,
        .cancelled(reason: "changed my mind")
    ]

    /// The complete set of legal transitions, written out by hand.
    ///
    /// This is deliberately a duplicate of the state machine's own logic. If the
    /// two ever disagree, one of them is a bug, and the matrix test below will
    /// say which pair. A generated expectation would just restate the
    /// implementation and prove nothing.
    static let legalTransitions: [(PublicationState, PublicationEvent, PublicationState)] = [
        (.idea, .drafted, .draft),
        (.draft, .submittedForReview, .review),
        (.draft, .revisionRequested(note: nil), .needsRevision),
        (.draft, .cancelled(reason: nil), .cancelled),
        (.review, .approved, .approved),
        (.review, .rejected(reason: nil), .rejected),
        (.review, .revisionRequested(note: nil), .needsRevision),
        (.review, .cancelled(reason: nil), .cancelled),
        (.needsRevision, .revised, .review),
        (.needsRevision, .cancelled(reason: nil), .cancelled),
        (.approved, .scheduled(at: future), .scheduled),
        (.approved, .cancelled(reason: nil), .cancelled),
        (.scheduled, .rescheduled(at: future), .scheduled),
        (.scheduled, .unscheduled, .approved),
        (.scheduled, .publishStarted(idempotencyKey: "k"), .publishing),
        (.scheduled, .cancelled(reason: nil), .cancelled),
        (.publishing, .publishSucceeded(remoteID: "r"), .published),
        (.publishing, .publishFailed(error: sampleFailure), .failed),
        (.publishing, .publishOutcomeUnknown(idempotencyKey: "k"), .awaitingReconciliation),
        (.awaitingReconciliation, .reconciledAsPublished(remoteID: "r"), .published),
        (.awaitingReconciliation, .reconciledAsFailed(error: sampleFailure), .failed),
        (.failed, .retryRequested, .scheduled),
        (.failed, .cancelled(reason: nil), .cancelled),
        (.idea, .cancelled(reason: nil), .cancelled)
    ]

    // MARK: - The matrix

    /// Every legal transition produces the documented state.
    @Test("legal transitions reach their documented state")
    func legalTransitionsSucceed() throws {
        for (from, event, expected) in Self.legalTransitions {
            let result = PublicationStateMachine.transition(from: from, on: event, now: Self.now)
            let actual = try result.get()
            #expect(
                actual == expected,
                "\(from.rawValue) --\(event.label)--> expected \(expected.rawValue), got \(actual.rawValue)"
            )
        }
    }

    /// Everything not on the legal list is refused. This is the test that catches
    /// an accidentally-permissive `case` added to the state machine later.
    @Test("every transition outside the legal set is refused")
    func illegalTransitionsFail() {
        let legalPairs = Set(Self.legalTransitions.map { "\($0.0.rawValue)|\($0.1.label)" })

        for state in PublicationState.allCases {
            for event in Self.allEvents {
                let key = "\(state.rawValue)|\(event.label)"
                guard !legalPairs.contains(key) else { continue }

                let result = PublicationStateMachine.transition(from: state, on: event, now: Self.now)
                switch result {
                case .success(let unexpected):
                    Issue.record(
                        "\(state.rawValue) --\(event.label)--> \(unexpected.rawValue) was allowed but is not in the legal set"
                    )
                case .failure:
                    break
                }
            }
        }
    }

    // MARK: - Terminal states

    @Test("terminal states absorb every event", arguments: [
        PublicationState.published, .rejected, .cancelled
    ])
    func terminalStatesAbsorbEverything(state: PublicationState) {
        #expect(state.isTerminal)
        for event in Self.allEvents {
            let result = PublicationStateMachine.transition(from: state, on: event, now: Self.now)
            guard case .failure(let error) = result else {
                Issue.record("\(state.rawValue) accepted \(event.label)")
                continue
            }
            #expect(error.reason == .stateIsTerminal)
        }
    }

    /// A replayed webhook or a duplicated job must not disturb a published row.
    @Test("a published row ignores a repeated success event")
    func publishedIsIdempotentAgainstReplay() {
        let result = PublicationStateMachine.transition(
            from: .published,
            on: .publishSucceeded(remoteID: "ig-123"),
            now: Self.now
        )
        guard case .failure(let error) = result else {
            Issue.record("a replayed success mutated a published row")
            return
        }
        #expect(error.reason == .stateIsTerminal)
    }

    // MARK: - Duplicate-post prevention

    /// The core safety property: only a scheduled row may call the platform.
    @Test("only scheduled rows may issue a publish call")
    func onlyScheduledMayPublish() {
        for state in PublicationState.allCases {
            #expect(
                PublicationStateMachine.mayIssuePublishCall(from: state) == (state == .scheduled),
                "mayIssuePublishCall was wrong for \(state.rawValue)"
            )
        }
    }

    /// States where a post may already exist must refuse cancellation, or we
    /// would strand a live post with no local record of it.
    @Test("cancellation is refused where a post may already exist")
    func cancellationRefusedWhenSideEffectsPossible() {
        for state in PublicationState.allCases where !state.isTerminal {
            let result = PublicationStateMachine.transition(
                from: state,
                on: .cancelled(reason: nil),
                now: Self.now
            )
            if state.mayHaveRemoteSideEffects {
                guard case .failure(let error) = result else {
                    Issue.record("\(state.rawValue) allowed cancellation despite possible side effects")
                    continue
                }
                #expect(error.reason == .wouldRiskDuplicatePublication)
            } else {
                #expect((try? result.get()) == .cancelled, "\(state.rawValue) should cancel cleanly")
            }
        }
    }

    @Test("states that may hold a remote post are exactly the three we expect")
    func sideEffectStatesAreTheExpectedOnes() {
        let flagged = Set(PublicationState.allCases.filter(\.mayHaveRemoteSideEffects))
        #expect(flagged == [.publishing, .published, .awaitingReconciliation])
        // `failed` means we established no post exists; if we are unsure, the
        // state must be awaitingReconciliation instead.
        #expect(!PublicationState.failed.mayHaveRemoteSideEffects)
    }

    // MARK: - The lost-confirmation case (§14)

    /// A worker times out after the platform may have accepted the post. The row
    /// must not be retried; it must reconcile, then settle on a single outcome.
    @Test("a lost confirmation reconciles without a second publish call")
    func lostConfirmationDoesNotDoublePost() throws {
        var state = PublicationState.scheduled
        state = try PublicationStateMachine.transition(
            from: state, on: .publishStarted(idempotencyKey: "idem-7"), now: Self.now
        ).get()
        #expect(state == .publishing)

        // The response never arrives.
        state = try PublicationStateMachine.transition(
            from: state, on: .publishOutcomeUnknown(idempotencyKey: "idem-7"), now: Self.now
        ).get()
        #expect(state == .awaitingReconciliation)

        // Crucially, no worker may publish from here.
        #expect(!PublicationStateMachine.mayIssuePublishCall(from: state))

        // A naive retry must be refused rather than producing a second post.
        let retry = PublicationStateMachine.transition(
            from: state, on: .retryRequested, now: Self.now
        )
        #expect(throws: PublicationStateMachine.TransitionError.self) { try retry.get() }

        // Reconciliation finds the post was in fact live.
        state = try PublicationStateMachine.transition(
            from: state, on: .reconciledAsPublished(remoteID: "ig-999"), now: Self.now
        ).get()
        #expect(state == .published)
    }

    @Test("reconciliation can also settle as failed, which is then retryable")
    func reconciliationCanSettleAsFailed() throws {
        var state = PublicationState.awaitingReconciliation
        state = try PublicationStateMachine.transition(
            from: state,
            on: .reconciledAsFailed(error: Self.sampleFailure),
            now: Self.now
        ).get()
        #expect(state == .failed)
        // Only now, having established nothing is live, may we retry.
        #expect(!state.mayHaveRemoteSideEffects)
        state = try PublicationStateMachine.transition(from: state, on: .retryRequested, now: Self.now).get()
        #expect(state == .scheduled)
    }

    // MARK: - Scheduling rules

    /// Backdating is explicitly not required (§9), so a past time is a bug.
    @Test("scheduling in the past is refused")
    func pastScheduleRefused() {
        let result = PublicationStateMachine.transition(
            from: .approved, on: .scheduled(at: Self.past), now: Self.now
        )
        guard case .failure(let error) = result else {
            Issue.record("a past publish time was accepted")
            return
        }
        #expect(error.reason == .scheduledTimeNotInFuture(Self.past))
    }

    @Test("rescheduling into the past is refused too")
    func pastRescheduleRefused() {
        let result = PublicationStateMachine.transition(
            from: .scheduled, on: .rescheduled(at: Self.past), now: Self.now
        )
        #expect(throws: PublicationStateMachine.TransitionError.self) { try result.get() }
    }

    /// A time exactly equal to `now` is not in the future, so it is refused.
    /// Documented here because the boundary is easy to flip accidentally.
    @Test("scheduling exactly at now is refused")
    func scheduleAtNowRefused() {
        let result = PublicationStateMachine.transition(
            from: .approved, on: .scheduled(at: Self.now), now: Self.now
        )
        #expect(throws: PublicationStateMachine.TransitionError.self) { try result.get() }
    }

    // MARK: - Full happy path

    @Test("the documented lifecycle runs end to end")
    func happyPath() throws {
        var state = PublicationState.idea
        let steps: [(PublicationEvent, PublicationState)] = [
            (.drafted, .draft),
            (.submittedForReview, .review),
            (.approved, .approved),
            (.scheduled(at: Self.future), .scheduled),
            (.publishStarted(idempotencyKey: "idem-1"), .publishing),
            (.publishSucceeded(remoteID: "ig-1"), .published)
        ]
        for (event, expected) in steps {
            state = try PublicationStateMachine.transition(from: state, on: event, now: Self.now).get()
            #expect(state == expected)
        }
        #expect(state.isTerminal)
    }

    @Test("a revision loop returns to review without losing the row")
    func revisionLoop() throws {
        var state = PublicationState.review
        state = try PublicationStateMachine.transition(
            from: state, on: .revisionRequested(note: "less hype"), now: Self.now
        ).get()
        #expect(state == .needsRevision)
        state = try PublicationStateMachine.transition(from: state, on: .revised, now: Self.now).get()
        #expect(state == .review)
    }
}
