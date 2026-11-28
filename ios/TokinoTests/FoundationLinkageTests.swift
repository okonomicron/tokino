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

    /// SwiftPM resource bundles resolve differently on iOS than on Linux, so
    /// "the tokenizer loads" has to be proven here as well as in TokinoKit's
    /// own suite. Without the vocabulary and merges, every search would fail.
    func testTokenizerLoadsItsBundledResourcesOnIOS() throws {
        let tokenizer = try CLIPTokenizer()

        XCTAssertEqual(tokenizer.startOfTextID, 49406)
        XCTAssertEqual(tokenizer.endOfTextID, 49407)

        let tokens = tokenizer.encode("a photo of a dog")
        XCTAssertFalse(tokens.isEmpty)

        // The same model-ready shape the text tower expects.
        let sequence = tokenizer.tokenize("a photo of a dog")
        XCTAssertEqual(sequence.count, CLIPTokenizer.contextLength)
        XCTAssertEqual(sequence.first, tokenizer.startOfTextID)
    }

    /// The curly apostrophe an iOS keyboard produces must tokenize like a
    /// straight one. Worth asserting on iOS specifically, since this is where
    /// that input actually comes from.
    func testCurlyApostropheNormalisesOnIOS() throws {
        let tokenizer = try CLIPTokenizer()
        XCTAssertEqual(
            tokenizer.encode("don\u{2019}t"),
            tokenizer.encode("don't")
        )
    }

    /// The descriptor's dimensions must match what the schema and the store
    /// expect, or embeddings would be rejected at write time.
    func testEmbeddingModelDescriptorMatchesSchema() {
        let model = EmbeddingModelDescriptor.openCLIPViTB32
        XCTAssertEqual(model.dimensions, PhotoEmbedding.dimensions)
        XCTAssertEqual(model.dimensions, 512)
        XCTAssertEqual(model.inputPixelSize, 224)
        XCTAssertEqual(model.contextLength, CLIPTokenizer.contextLength)
        XCTAssertEqual(model.weightsLicense, "MIT")
        XCTAssertEqual(model.pixelMean.count, 3)
        XCTAssertEqual(model.pixelStandardDeviation.count, 3)
    }

    /// Photo access states must map to distinct UI affordances; collapsing
    /// `limited` into a failure is a common and insulting bug.
    func testPhotoLibraryAccessSemantics() {
        XCTAssertTrue(PhotoLibraryAccess.full.canReadLibrary)
        XCTAssertTrue(PhotoLibraryAccess.limited.canReadLibrary)
        XCTAssertFalse(PhotoLibraryAccess.denied.canReadLibrary)
        XCTAssertFalse(PhotoLibraryAccess.notDetermined.canReadLibrary)
        XCTAssertFalse(PhotoLibraryAccess.restricted.canReadLibrary)

        // Sending a user to Settings for a restriction they cannot change
        // would be misleading.
        XCTAssertFalse(PhotoLibraryAccess.restricted.isResolvableInSettings)
        XCTAssertTrue(PhotoLibraryAccess.denied.isResolvableInSettings)
        XCTAssertTrue(PhotoLibraryAccess.limited.isResolvableInSettings)
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
