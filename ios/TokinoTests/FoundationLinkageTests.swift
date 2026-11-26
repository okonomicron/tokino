import XCTest
import TokinoKit

/// Confirms the iOS app target genuinely links TokinoKit and that the shared
/// logic behaves the same when compiled by Xcode for iOS as it does under the
/// Linux toolchain.
///
/// TokinoKit's own behaviour is covered far more thoroughly by its Swift
/// Testing suites, which run on Linux for free. These XCTest cases exist to
/// catch the things only an iOS build can: linkage, availability, and any
/// platform-conditional divergence.
final class FoundationLinkageTests: XCTestCase {

    func testTokinoKitTypesAreAvailableToTheAppTarget() {
        XCTAssertEqual(Platform.allCases.count, 2)
        XCTAssertEqual(Platform.instagram.displayName, "Instagram")
    }

    /// The verified Instagram limits must survive compilation for iOS, not just
    /// for Linux.
    func testPlatformConstraintsMatchVerifiedValues() {
        let instagram = Platform.instagram.constraints
        XCTAssertEqual(instagram.maxCarouselItems, 20)
        XCTAssertEqual(instagram.maxCaptionLength, 2200)
        XCTAssertEqual(instagram.maxHashtags, 30)
        XCTAssertTrue(instagram.requiresPubliclyHostedMedia)
        XCTAssertEqual(instagram.acceptedImageFormats, ["jpeg", "jpg"])
    }

    func testStateMachineBehavesIdenticallyOnIOS() throws {
        let future = Date().addingTimeInterval(3600)
        var state = PublicationState.approved

        state = try PublicationStateMachine.transition(from: state, on: .scheduled(at: future)).get()
        XCTAssertEqual(state, .scheduled)

        state = try PublicationStateMachine.transition(
            from: state, on: .publishStarted(idempotencyKey: "k")
        ).get()
        XCTAssertEqual(state, .publishing)

        // The duplicate-post guard must hold here too.
        XCTAssertFalse(PublicationStateMachine.mayIssuePublishCall(from: state))
    }

    func testScanPlannerDoesNoWorkForAnUnchangedLibrary() {
        let now = Date()
        let library = (1...10).map {
            LibraryAssetSnapshot(localIdentifier: "a\($0)", modificationDate: now)
        }
        let indexed = (1...10).map {
            IndexedAssetRecord(
                localIdentifier: "a\($0)",
                indexedAt: now,
                sourceModificationDate: now,
                modelIdentifier: "mobileclip-s2-v1"
            )
        }

        let plan = ScanPlanner.plan(library: library, indexed: indexed, policy: ScanPolicy())
        XCTAssertEqual(plan.totalWorkItems, 0)
        XCTAssertEqual(plan.unchangedCount, 10)
    }

    /// Guards the privacy default: a mock must never be selected once a real
    /// credential exists, on any platform.
    func testMockProvidersAreRefusedWhenACredentialExists() {
        let result = ProviderSelector.resolve(
            capability: .languageModel,
            candidates: [MockLanguageModelProvider.identity],
            hasCredential: true
        )
        switch result {
        case .success:
            XCTFail("a mock was selected despite a credential being present")
        case .failure(let error):
            XCTAssertTrue(error.description.contains("Refusing to use mock provider"))
        }
    }
}
