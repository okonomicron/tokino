import Foundation
import Testing
@testable import TokinoKit

/// The brief (§15) allows mocks but forbids silently substituting them for real
/// integrations. These tests are that rule, enforced.
@Suite("Provider selection and mocks")
struct ProviderTests {

    static let liveLLM = ProviderIdentity(name: "live-llm", capability: .languageModel, isMock: false)
    static let mockLLM = MockLanguageModelProvider.identity

    // MARK: - The no-silent-substitution rule

    /// The rule that matters: a configured credential means the user expects
    /// real output, so serving mock output instead must be an error.
    @Test("a mock is refused when a real credential is configured")
    func mockRefusedWithCredential() {
        let result = ProviderSelector.resolve(
            capability: .languageModel,
            candidates: [Self.mockLLM],
            hasCredential: true
        )

        guard case .failure(let error) = result else {
            Issue.record("a mock was selected despite a real credential being present")
            return
        }
        #expect(error == .mockRefusedWhileCredentialPresent(
            capability: .languageModel,
            mockName: "mock-language-model"
        ))
        // The message has to be actionable, since this fires in a deploy.
        #expect(error.description.contains("Refusing to use mock provider"))
    }

    @Test("a mock is allowed when no credential is configured")
    func mockAllowedWithoutCredential() throws {
        let chosen = try ProviderSelector.resolve(
            capability: .languageModel,
            candidates: [Self.mockLLM],
            hasCredential: false
        ).get()
        #expect(chosen.isMock)
        #expect(chosen == Self.mockLLM)
    }

    @Test("a live provider wins over a mock whenever one is registered")
    func liveProviderPreferred() throws {
        for hasCredential in [true, false] {
            let chosen = try ProviderSelector.resolve(
                capability: .languageModel,
                candidates: [Self.mockLLM, Self.liveLLM],
                hasCredential: hasCredential
            ).get()
            #expect(!chosen.isMock, "a live provider should win regardless of credential state")
        }
    }

    @Test("an unregistered capability is an error, not a silent no-op")
    func unregisteredCapabilityFails() {
        let result = ProviderSelector.resolve(
            capability: .places,
            candidates: [Self.mockLLM],
            hasCredential: false
        )
        guard case .failure(let error) = result else {
            Issue.record("resolving an unregistered capability should fail")
            return
        }
        #expect(error == .noProviderRegistered(capability: .places))
    }

    @Test("resolution never returns a provider for the wrong capability")
    func capabilityIsRespected() throws {
        let mockPlaces = MockPlaceProvider.identity
        let chosen = try ProviderSelector.resolve(
            capability: .places,
            candidates: [Self.mockLLM, mockPlaces],
            hasCredential: false
        ).get()
        #expect(chosen.capability == .places)
    }

    // MARK: - Mocks identify themselves

    @Test("every mock identity is flagged and labelled")
    func mocksAreLabelled() {
        let identities = [
            MockLanguageModelProvider.identity,
            MockPlaceProvider.identity,
            MockPublishingAdapter.identity
        ]
        for identity in identities {
            #expect(identity.isMock, "\(identity.name) must declare itself a mock")
            #expect(
                identity.displayLabel.contains("MOCK"),
                "\(identity.name) must be visibly labelled, got '\(identity.displayLabel)'"
            )
            #expect(identity.displayLabel.contains("not a real integration"))
        }
    }

    @Test("a live identity is not labelled as a mock")
    func liveIdentityIsNotLabelled() {
        #expect(Self.liveLLM.displayLabel == "live-llm")
        #expect(!Self.liveLLM.isMock)
    }

    /// Mock captions must be obviously fake, so one cannot be posted by mistake.
    @Test("mock captions announce themselves and are traceable")
    func mockCaptionsAreObvious() async throws {
        let provider = MockLanguageModelProvider()
        let voice = VoiceProfile(
            userID: Identifier(),
            name: "test",
            instruction: "be plain",
            hashtagStyle: .minimal
        )
        let result = try await provider.writeCaption(
            request: CaptionRequest(
                platform: .instagram,
                language: "en",
                voice: voice,
                groundingFacts: ["Visited in 2024"],
                format: .carousel,
                imageCount: 3
            )
        )

        #expect(result.caption.contains("MOCK CAPTION"))
        #expect(result.caption.contains("not for publishing"))
        #expect(result.producedBy.isMock, "output must carry its provenance")
        #expect(result.hashtags.count == 3)
    }

    /// Even a mock must respect platform limits, or it would hide bugs in the
    /// validation path that a live provider would expose.
    @Test("mock output respects platform caption and hashtag limits")
    func mockRespectsPlatformLimits() async throws {
        let provider = MockLanguageModelProvider()
        let voice = VoiceProfile(
            userID: Identifier(),
            name: "test",
            instruction: "",
            hashtagStyle: .extensive
        )

        for platform in Platform.allCases {
            let result = try await provider.writeCaption(
                request: CaptionRequest(
                    platform: platform,
                    language: voice.language(for: platform),
                    voice: voice,
                    groundingFacts: Array(repeating: "a long grounding fact", count: 200),
                    format: .singleImage,
                    imageCount: 1
                )
            )
            #expect(result.caption.count <= platform.constraints.maxCaptionLength)
            #expect(result.hashtags.count <= platform.constraints.maxHashtags)
        }
    }

    @Test("the mock language model derives pillars from the library, not a hardcoded topic")
    func mockDerivesPillarsFromLibrary() async throws {
        let provider = MockLanguageModelProvider()
        // A deliberately non-food library, to catch any kaisendon-shaped
        // hardcoding (§17.3, §17.4).
        let summary = LibrarySummary(
            totalAssets: 1200,
            commonPlaceNames: ["Snowdonia"],
            recurringThemes: ["mountains", "trail running", "camping"]
        )
        let interpretation = try await provider.interpretStrategy(
            prompt: "hiking content twice a week",
            librarySummary: summary
        )

        let names = interpretation.pillars.map(\.name)
        #expect(names == ["Mountains", "Trail running", "Camping"])
        #expect(interpretation.selectionCriteria.naturalLanguageQuery == "mountains")
    }

    @Test("the mock language model is deterministic")
    func mockIsDeterministic() async throws {
        let provider = MockLanguageModelProvider()
        let summary = LibrarySummary(totalAssets: 10, recurringThemes: ["a", "b"])
        let first = try await provider.interpretStrategy(prompt: "p", librarySummary: summary)
        let second = try await provider.interpretStrategy(prompt: "p", librarySummary: summary)
        #expect(first == second)
    }

    @Test("the mock place provider is stable per coordinate and differs between them")
    func mockPlacesAreStablePerCoordinate() async throws {
        let provider = MockPlaceProvider()
        let tokyo = Coordinate(latitude: 35.6655, longitude: 139.7707)
        let osaka = Coordinate(latitude: 34.6687, longitude: 135.5020)

        let a = try await provider.findPlaces(near: tokyo, radiusMetres: 100, capturedAt: nil)
        let b = try await provider.findPlaces(near: tokyo, radiusMetres: 100, capturedAt: nil)
        let c = try await provider.findPlaces(near: osaka, radiusMetres: 100, capturedAt: nil)

        #expect(a == b)
        #expect(a.first?.providerPlaceID != c.first?.providerPlaceID)
        #expect(a.first?.name.contains("MOCK") == true)
    }
}

/// Drives the publishing pipeline against the mock adapter. This is the dry-run
/// publishing the user asked for: the full state machine exercised end to end
/// with nothing leaving the machine.
@Suite("Publishing pipeline against the mock adapter")
struct PublishingPipelineTests {

    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static func draft() -> ContentDraft {
        ContentDraft(
            ideaID: Identifier(),
            strategyID: Identifier(),
            platform: .instagram,
            format: .carousel,
            caption: "caption",
            createdAt: now,
            updatedAt: now
        )
    }

    @Test("a successful publish reaches published with one platform call")
    func successfulPublish() async throws {
        let adapter = MockPublishingAdapter(behaviour: .succeed)
        var state = PublicationState.scheduled

        state = try PublicationStateMachine.transition(
            from: state, on: .publishStarted(idempotencyKey: "k1"), now: Self.now
        ).get()

        let outcome = try await adapter.publish(draft: Self.draft(), media: [], idempotencyKey: "k1")
        guard case .published(let remoteID) = outcome else {
            Issue.record("expected a published outcome, got \(outcome)")
            return
        }

        state = try PublicationStateMachine.transition(
            from: state, on: .publishSucceeded(remoteID: remoteID), now: Self.now
        ).get()

        #expect(state == .published)
        #expect(await adapter.callCount() == 1)
    }

    /// The §14 scenario: the platform accepted the post but we never saw the
    /// response. The row must reconcile and settle on the existing post, and the
    /// adapter must not be asked to publish a second time.
    @Test("a lost response reconciles to the existing post without republishing")
    func lostResponseDoesNotDoublePost() async throws {
        let adapter = MockPublishingAdapter(behaviour: .loseTheResponse)
        var state = try PublicationStateMachine.transition(
            from: .scheduled, on: .publishStarted(idempotencyKey: "k9"), now: Self.now
        ).get()

        let outcome = try await adapter.publish(draft: Self.draft(), media: [], idempotencyKey: "k9")
        guard case .outcomeUnknown = outcome else {
            Issue.record("expected an unknown outcome, got \(outcome)")
            return
        }

        state = try PublicationStateMachine.transition(
            from: state, on: .publishOutcomeUnknown(idempotencyKey: "k9"), now: Self.now
        ).get()
        #expect(state == .awaitingReconciliation)

        // Reconcile instead of retrying.
        let reconciliation = try await adapter.reconcile(idempotencyKey: "k9")
        guard case .foundPublished(let remoteID) = reconciliation else {
            Issue.record("expected reconciliation to find the post, got \(reconciliation)")
            return
        }

        state = try PublicationStateMachine.transition(
            from: state, on: .reconciledAsPublished(remoteID: remoteID), now: Self.now
        ).get()

        #expect(state == .published)
        #expect(
            await adapter.callCount() == 1,
            "the platform must be called exactly once; a second call would be a duplicate post"
        )
    }

    /// Belt and braces: even if a buggy caller re-issued the same key, a
    /// platform with idempotency returns the original post rather than a new one.
    @Test("re-publishing with the same idempotency key returns the original post")
    func sameKeyReturnsOriginalPost() async throws {
        let adapter = MockPublishingAdapter(behaviour: .succeed)
        let first = try await adapter.publish(draft: Self.draft(), media: [], idempotencyKey: "same")
        let second = try await adapter.publish(draft: Self.draft(), media: [], idempotencyKey: "same")
        #expect(first == second)
    }

    @Test("a transient failure is retryable and an auth failure is not")
    func retryabilityByFailureKind() async throws {
        let transient = PublishFailure(kind: .transient, message: "reset")
        #expect(transient.isRetryable)

        let auth = PublishFailure(kind: .authenticationExpired, message: "token expired")
        #expect(!auth.isRetryable, "retrying an expired token burns attempts and risks the account")

        let adapter = MockPublishingAdapter(behaviour: .fail(transient))
        let outcome = try await adapter.publish(draft: Self.draft(), media: [], idempotencyKey: "k")
        guard case .failed(let failure) = outcome else {
            Issue.record("expected failure, got \(outcome)")
            return
        }
        #expect(failure.isRetryable)

        let state = try PublicationStateMachine.transition(
            from: .publishing, on: .publishFailed(error: failure), now: Self.now
        ).get()
        #expect(state == .failed)
        #expect(!state.mayHaveRemoteSideEffects, "a confirmed failure means nothing is live")
    }

    /// Fully automatic publishing may not be claimed on a platform that needs
    /// the user to act (§9).
    @Test("fully automatic publishing is refused on assisted-handoff platforms")
    func automationRespectsPublishingMode() {
        #expect(AutomationLevel.fullyAutomatic.isPermitted(on: .instagram))
        #expect(!AutomationLevel.fullyAutomatic.isPermitted(on: .xiaohongshu))
        for level in [AutomationLevel.manual, .semiAutomatic] {
            for platform in Platform.allCases {
                #expect(level.isPermitted(on: platform))
            }
        }
        #expect(AutomationLevel.manual.requiresPerPostApproval)
        #expect(AutomationLevel.semiAutomatic.requiresPerPostApproval)
        #expect(!AutomationLevel.fullyAutomatic.requiresPerPostApproval)
    }
}
