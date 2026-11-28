import Foundation
import Testing
@testable import TokinoKit

/// Asserts the Swift tokenizer reproduces `open_clip`'s token IDs exactly.
///
/// The expectations are **not** written by hand and **not** derived from this
/// implementation. They come from `tools/ref_openclip.py`, which runs
/// `open_clip`'s own `SimpleTokenizer` — the tokenizer that trained these
/// weights. A second reference, Hugging Face's `CLIPTokenizerFast`, was
/// generated independently and the two compared; see `toolsDisagreementsAreKnown`.
///
/// This matters because a tokenizer mismatch degrades every search silently.
/// Testing against a reference is the only way to catch it.
@Suite("CLIP tokenizer")
struct CLIPTokenizerTests {

    // MARK: - Fixture loading

    struct Fixture: Decodable {
        struct Case: Decodable {
            let text: String
            let expected: [Int]
            let bothImplementationsAgree: Bool
        }
        let sotTokenID: Int
        let eotTokenID: Int
        let vocabSize: Int
        let contextLength: Int
        let cases: [Case]
    }

    static let fixture: Fixture = {
        guard let url = Bundle.module.url(
            forResource: "Fixtures/clip-tokenizer-cases",
            withExtension: "json"
        ) else {
            fatalError("tokenizer fixture missing from the test bundle")
        }
        do {
            return try JSONDecoder().decode(Fixture.self, from: try Data(contentsOf: url))
        } catch {
            fatalError("tokenizer fixture could not be decoded: \(error)")
        }
    }()

    static let tokenizer: CLIPTokenizer = {
        do {
            return try CLIPTokenizer()
        } catch {
            fatalError("tokenizer could not load its bundled resources: \(error)")
        }
    }()

    // MARK: - The reference comparison

    /// The test that matters: every case from `open_clip` reproduced exactly.
    @Test("every reference case reproduces open_clip's token IDs")
    func matchesReferenceTokenIDs() {
        var failures: [String] = []

        for testCase in Self.fixture.cases {
            let actual = Self.tokenizer.encode(testCase.text)
            if actual != testCase.expected {
                failures.append(
                    """
                    input: \(testCase.text.debugDescription)
                      expected (open_clip): \(testCase.expected)
                      actual   (TokinoKit): \(actual)
                    """
                )
            }
        }

        let report = failures.joined(separator: "\n")
        #expect(
            failures.isEmpty,
            "\(failures.count) of \(Self.fixture.cases.count) cases diverged:\n\(report)"
        )
    }

    @Test("the fixture is substantial enough to be meaningful")
    func fixtureIsNotTrivial() {
        // Guards against a truncated or half-generated fixture quietly making
        // the suite above vacuous.
        #expect(Self.fixture.cases.count >= 30)
        #expect(Self.fixture.cases.contains { !$0.expected.isEmpty })
        #expect(Self.fixture.sotTokenID == 49406)
        #expect(Self.fixture.eotTokenID == 49407)
        #expect(Self.fixture.vocabSize == 49408)
        #expect(Self.fixture.contextLength == CLIPTokenizer.contextLength)
    }

    /// Documents where the two reference implementations disagree, and that we
    /// deliberately follow `open_clip`.
    ///
    /// Hugging Face's tokenizer omits the text-cleaning step, so it mangles
    /// curly apostrophes, fullwidth characters, ligatures and HTML entities.
    /// Following it would have made search quietly worse for anyone typing on
    /// an iOS keyboard or using a Japanese or Chinese IME.
    @Test("known reference disagreements are recorded, not silently resolved")
    func toolsDisagreementsAreKnown() {
        let disagreeing = Self.fixture.cases.filter { !$0.bothImplementationsAgree }
        #expect(
            !disagreeing.isEmpty,
            "the fixture should record where open_clip and Hugging Face differ"
        )
        // Each one is still expected to match open_clip.
        for testCase in disagreeing {
            #expect(Self.tokenizer.encode(testCase.text) == testCase.expected)
        }
    }

    // MARK: - Properties the fixture pins down

    @Test("sentinel IDs match CLIP's vocabulary")
    func sentinelIDs() {
        #expect(Self.tokenizer.startOfTextID == 49406)
        #expect(Self.tokenizer.endOfTextID == 49407)
    }

    /// `open_clip` splits digits one at a time, unlike original OpenAI CLIP.
    /// Getting this wrong would quietly change every query containing a number.
    @Test("digits tokenize one at a time")
    func digitsSplitIndividually() {
        #expect(Self.tokenizer.encode("1").count == 1)
        #expect(Self.tokenizer.encode("42").count == 2)
        #expect(Self.tokenizer.encode("2024").count == 4)
    }

    /// The case that would have broken real queries from an iOS keyboard.
    @Test("a curly apostrophe tokenizes like a straight one")
    func curlyApostropheIsNormalised() {
        #expect(Self.tokenizer.encode("don\u{2019}t") == Self.tokenizer.encode("don't"))
    }

    @Test("fullwidth input tokenizes like its ASCII equivalent")
    func fullwidthIsNormalised() {
        #expect(Self.tokenizer.encode("\u{FF46}\u{FF55}\u{FF4C}\u{FF4C}") == Self.tokenizer.encode("full"))
        #expect(Self.tokenizer.encode("\u{FF11}\u{FF12}\u{FF13}") == Self.tokenizer.encode("123"))
    }

    @Test("case is folded")
    func caseIsFolded() {
        #expect(Self.tokenizer.encode("A Photo Of A DOG") == Self.tokenizer.encode("a photo of a dog"))
    }

    @Test("surrounding and repeated whitespace is irrelevant")
    func whitespaceIsCollapsed() {
        let canonical = Self.tokenizer.encode("a photo of a dog")
        #expect(Self.tokenizer.encode("  a   photo  of a    dog  ") == canonical)
        #expect(Self.tokenizer.encode("a\tphoto\nof a dog") == canonical)
    }

    @Test("empty and whitespace-only input yields no tokens")
    func emptyInput() {
        #expect(Self.tokenizer.encode("").isEmpty)
        #expect(Self.tokenizer.encode("   ").isEmpty)
        #expect(Self.tokenizer.encode("\n\t ").isEmpty)
    }

    // MARK: - Model-ready sequences

    @Test("a tokenized sequence is sentinel-wrapped and padded to the context length")
    func tokenizePadsAndWraps() {
        let tokens = Self.tokenizer.tokenize("a photo of a dog")

        #expect(tokens.count == CLIPTokenizer.contextLength)
        #expect(tokens.first == Self.tokenizer.startOfTextID)

        let content = Self.tokenizer.encode("a photo of a dog")
        #expect(Array(tokens[1...content.count]) == content)
        #expect(tokens[content.count + 1] == Self.tokenizer.endOfTextID)
        // Everything after the end sentinel is padding.
        #expect(tokens[(content.count + 2)...].allSatisfy { $0 == 0 })
    }

    /// The tower relies on the end sentinel being present, so truncation must
    /// preserve it rather than cutting it off.
    @Test("over-long input is truncated but keeps its end sentinel")
    func tokenizeTruncatesAndPreservesSentinel() {
        let long = Array(repeating: "word", count: 200).joined(separator: " ")
        let tokens = Self.tokenizer.tokenize(long)

        #expect(tokens.count == CLIPTokenizer.contextLength)
        #expect(tokens.first == Self.tokenizer.startOfTextID)
        #expect(tokens.last == Self.tokenizer.endOfTextID)
        #expect(!tokens.contains(0), "a truncated sequence has no room for padding")
    }

    @Test("empty input still produces a valid padded sequence")
    func tokenizeEmptyInput() {
        let tokens = Self.tokenizer.tokenize("")
        #expect(tokens.count == CLIPTokenizer.contextLength)
        #expect(tokens[0] == Self.tokenizer.startOfTextID)
        #expect(tokens[1] == Self.tokenizer.endOfTextID)
        #expect(tokens[2...].allSatisfy { $0 == 0 })
    }

    @Test("a custom context length is honoured")
    func customContextLength() {
        let tokens = Self.tokenizer.tokenize("a photo of a dog", contextLength: 8)
        #expect(tokens.count == 8)
        #expect(tokens.first == Self.tokenizer.startOfTextID)
    }

    // MARK: - Loading failures

    @Test("a malformed vocabulary is rejected rather than half-loaded")
    func malformedVocabularyThrows() {
        #expect(throws: CLIPTokenizer.LoadError.self) {
            try CLIPTokenizer(vocabularyJSON: Data("not json".utf8), mergesText: "a b")
        }
    }

    @Test("an empty merges file is rejected")
    func emptyMergesThrows() {
        let vocab = Data(#"{"a</w>": 1}"#.utf8)
        #expect(throws: CLIPTokenizer.LoadError.self) {
            try CLIPTokenizer(vocabularyJSON: vocab, mergesText: "#version: 0.2\n")
        }
    }
}

/// Covers the cleaner directly, so a cleaning bug is distinguishable from a BPE
/// bug when something fails.
@Suite("CLIP text cleaner")
struct CLIPTextCleanerTests {

    @Test("NFC composition is applied")
    func nfcComposition() {
        #expect(CLIPTextCleaner.clean("cafe\u{0301}") == "café")
    }

    @Test("curly quotes fold to ASCII")
    func quotesFold() {
        #expect(CLIPTextCleaner.clean("don\u{2019}t") == "don't")
        #expect(CLIPTextCleaner.clean("\u{201C}quoted\u{201D}") == "\"quoted\"")
    }

    /// `ftfy` leaves dashes alone, so we must too. Being more aggressive than
    /// the reference is as wrong as being less.
    @Test("dashes and ellipses are left alone")
    func dashesAndEllipsesSurvive() {
        #expect(CLIPTextCleaner.clean("\u{2014}dash") == "\u{2014}dash")
        #expect(CLIPTextCleaner.clean("\u{2026}ellipsis") == "\u{2026}ellipsis")
    }

    /// Full NFKC would expand this to "1/2"; `ftfy` does not.
    @Test("a vulgar fraction is not expanded")
    func fractionSurvives() {
        #expect(CLIPTextCleaner.clean("\u{00BD} cup") == "\u{00BD} cup")
    }

    @Test("fullwidth and halfwidth forms fold")
    func widthFolds() {
        #expect(CLIPTextCleaner.clean("\u{FF46}\u{FF55}\u{FF4C}\u{FF4C}") == "full")
        #expect(CLIPTextCleaner.clean("\u{FF11}\u{FF12}\u{FF13}") == "123")
        #expect(CLIPTextCleaner.clean("\u{FF8A}\u{FF9D}") == "ハン")
    }

    @Test("Latin ligatures decompose")
    func ligaturesFold() {
        #expect(CLIPTextCleaner.clean("\u{FB01}sh") == "fish")
    }

    @Test("HTML entities are unescaped twice")
    func htmlUnescapedTwice() {
        #expect(CLIPTextCleaner.clean("&amp; x") == "& x")
        // The double application is what turns this into a bare ampersand.
        #expect(CLIPTextCleaner.clean("&amp;amp; double") == "& double")
    }

    @Test("numeric entities are resolved")
    func numericEntities() {
        #expect(CLIPTextCleaner.clean("&#65;&#66;") == "ab")
        #expect(CLIPTextCleaner.clean("&#x41;") == "a")
    }

    /// An unknown entity is left intact, matching `html.unescape`.
    @Test("an unknown entity is left as written")
    func unknownEntityUntouched() {
        #expect(CLIPTextCleaner.clean("&notarealentity; x") == "&notarealentity; x")
    }

    @Test("a bare ampersand is harmless")
    func bareAmpersand() {
        #expect(CLIPTextCleaner.clean("fish & chips") == "fish & chips")
        #expect(CLIPTextCleaner.clean("a & b & c") == "a & b & c")
    }

    @Test("whitespace collapses, including non-breaking space")
    func whitespaceCollapses() {
        #expect(CLIPTextCleaner.clean("  a   b  ") == "a b")
        #expect(CLIPTextCleaner.clean("a\u{00A0}b") == "a b")
        #expect(CLIPTextCleaner.clean("a\n\tb") == "a b")
    }

    @Test("text is lowercased")
    func lowercased() {
        #expect(CLIPTextCleaner.clean("MiXeD CaSe") == "mixed case")
    }

    @Test("CJK text passes through unchanged")
    func cjkSurvives() {
        #expect(CLIPTextCleaner.clean("海鮮丼") == "海鮮丼")
    }

    /// The documented limitation. Recorded as a test so the boundary is explicit
    /// rather than discovered later.
    @Test("mojibake is deliberately not repaired")
    func mojibakeNotRepaired() {
        // ftfy would yield "éclair"; we do not attempt this, because typed
        // input cannot contain mojibake. See CLIPTextCleaner's documentation.
        #expect(CLIPTextCleaner.clean("\u{00C3}\u{00A9}clair") == "ã©clair")
    }
}
