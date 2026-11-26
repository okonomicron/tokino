import Foundation

/// The single authority on whether a publication may change state.
///
/// Pure and synchronous by design: no I/O, no clock, no actor. That makes every
/// transition exhaustively testable on Linux, which is where the brief's
/// requirement for "idempotent jobs and explicit state transitions" (§14) is
/// actually enforced. Callers persist the result; they never compute it.
public enum PublicationStateMachine {

    public struct TransitionError: Error, Sendable, Hashable, CustomStringConvertible {
        public let from: PublicationState
        public let event: String
        public let reason: Reason

        public enum Reason: Sendable, Hashable {
            /// The event has no meaning from this state.
            case illegalTransition
            /// The state is terminal; nothing may move it.
            case stateIsTerminal
            /// Refused because the platform may already hold a post.
            case wouldRiskDuplicatePublication
            /// A scheduled time was in the past.
            case scheduledTimeNotInFuture(Date)
            /// Retry asked for on a failure that cannot be retried.
            case failureNotRetryable(PublishFailure.Kind)
        }

        public var description: String {
            switch reason {
            case .illegalTransition:
                return "\(event) is not legal from \(from.rawValue)"
            case .stateIsTerminal:
                return "\(from.rawValue) is terminal; \(event) rejected"
            case .wouldRiskDuplicatePublication:
                return "\(event) refused from \(from.rawValue): the platform may already hold a post; reconcile first"
            case .scheduledTimeNotInFuture(let date):
                return "\(event) refused: \(date) is not in the future"
            case .failureNotRetryable(let kind):
                return "\(event) refused: a \(kind.rawValue) failure cannot be retried automatically"
            }
        }
    }

    /// Decide the state a publication moves to, or explain why it may not.
    ///
    /// - Parameters:
    ///   - state: the publication's current, persisted state.
    ///   - event: what happened.
    ///   - now: injected so scheduling rules are testable without waiting.
    public static func transition(
        from state: PublicationState,
        on event: PublicationEvent,
        now: Date = Date()
    ) -> Result<PublicationState, TransitionError> {

        func fail(_ reason: TransitionError.Reason) -> Result<PublicationState, TransitionError> {
            .failure(TransitionError(from: state, event: event.label, reason: reason))
        }

        // A terminal state absorbs nothing. Checked before anything else so that
        // a duplicate webhook or a replayed job cannot disturb a published row.
        if state.isTerminal {
            return fail(.stateIsTerminal)
        }

        switch (state, event) {

        // ---- Generation ----
        case (.idea, .drafted):
            return .success(.draft)
        case (.draft, .submittedForReview), (.needsRevision, .revised):
            return .success(.review)

        // ---- Approval ----
        case (.review, .approved):
            return .success(.approved)
        case (.review, .rejected):
            return .success(.rejected)
        case (.review, .revisionRequested), (.draft, .revisionRequested):
            return .success(.needsRevision)

        // ---- Scheduling ----
        // Backdating is explicitly not required (§9), so a past time is a bug,
        // not a feature: refuse it rather than publishing immediately.
        case (.approved, .scheduled(let at)), (.scheduled, .rescheduled(let at)):
            guard at > now else { return fail(.scheduledTimeNotInFuture(at)) }
            return .success(.scheduled)
        case (.scheduled, .unscheduled):
            return .success(.approved)

        // ---- Publishing ----
        // Only a scheduled row may begin publishing. Reaching `publishing` from
        // `approved` directly would bypass the scheduler's duplicate guards.
        case (.scheduled, .publishStarted):
            return .success(.publishing)
        case (.publishing, .publishSucceeded):
            return .success(.published)
        case (.publishing, .publishFailed):
            return .success(.failed)
        case (.publishing, .publishOutcomeUnknown):
            return .success(.awaitingReconciliation)

        // ---- Reconciliation ----
        case (.awaitingReconciliation, .reconciledAsPublished):
            return .success(.published)
        case (.awaitingReconciliation, .reconciledAsFailed):
            return .success(.failed)

        // ---- Retry ----
        // Back to `scheduled` rather than `publishing`: the scheduler re-claims
        // the row, which keeps claiming logic in exactly one place.
        case (.failed, .retryRequested(let failure)):
            // A failure that retrying cannot fix is refused here rather than
            // left to each caller to remember. nil means a person asked, and a
            // person may retry whatever they like.
            if let failure, !failure.isRetryable {
                return fail(.failureNotRetryable(failure.kind))
            }
            return .success(.scheduled)

        // ---- Cancellation ----
        // Permitted only while we are sure nothing is live. Cancelling a row
        // that may already have posted would strand a real post with no record,
        // so those states must reconcile first.
        case (_, .cancelled):
            if state.mayHaveRemoteSideEffects {
                return fail(.wouldRiskDuplicatePublication)
            }
            return .success(.cancelled)

        default:
            return fail(.illegalTransition)
        }
    }

    /// Whether a worker may issue a platform publish call for this state.
    ///
    /// The only safe answer is `scheduled`. Every other state either has not
    /// been approved, or may already have produced a post.
    public static func mayIssuePublishCall(from state: PublicationState) -> Bool {
        state == .scheduled
    }
}

extension PublicationEvent {
    /// A stable name for logs and errors. Kept separate from the enum case so
    /// that adding associated values never changes a log line's shape.
    public var label: String {
        switch self {
        case .drafted: return "drafted"
        case .submittedForReview: return "submittedForReview"
        case .approved: return "approved"
        case .rejected: return "rejected"
        case .revisionRequested: return "revisionRequested"
        case .revised: return "revised"
        case .scheduled: return "scheduled"
        case .rescheduled: return "rescheduled"
        case .unscheduled: return "unscheduled"
        case .publishStarted: return "publishStarted"
        case .publishSucceeded: return "publishSucceeded"
        case .publishFailed: return "publishFailed"
        case .publishOutcomeUnknown: return "publishOutcomeUnknown"
        case .reconciledAsPublished: return "reconciledAsPublished"
        case .reconciledAsFailed: return "reconciledAsFailed"
        case .retryRequested: return "retryRequested"
        case .cancelled: return "cancelled"
        }
    }
}
