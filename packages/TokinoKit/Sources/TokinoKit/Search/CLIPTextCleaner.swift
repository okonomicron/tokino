import Foundation

/// Normalises query text the way `open_clip` does before tokenizing.
///
/// This matters more than it looks. CLIP was trained on text passed through a
/// specific cleaning pipeline, and a query cleaned differently lands in a
/// different part of the embedding space. The failure mode is not a crash — it
/// is search that is quietly a bit worse, which is almost impossible to notice.
///
/// `open_clip`'s pipeline (its `_clean_lower`) is:
///
/// 1. `ftfy.fix_text` — Unicode repair and normalisation.
/// 2. `html.unescape` applied **twice**.
/// 3. Whitespace collapsed to single spaces, then trimmed.
/// 4. Lowercased.
///
/// Steps 2 to 4 port directly. Step 1 cannot: `ftfy` is a large library whose
/// main job is repairing *mojibake* — text decoded with the wrong codec, such as
/// `Ã©clair` for `éclair`. So this type replicates the parts of `ftfy` that
/// typed input can actually produce, and deliberately not the rest:
///
/// | `ftfy` behaviour | Replicated | Why |
/// |---|---|---|
/// | NFC composition | Yes | A keyboard can emit decomposed accents |
/// | Curly quotes to straight | Yes | **iOS emits a curly apostrophe by default** |
/// | Fullwidth to ASCII | Yes | Japanese and Chinese IMEs emit fullwidth forms |
/// | Halfwidth katakana to fullwidth | Yes | Same reason |
/// | Latin ligatures (fi to f + i) | Yes | Cheap, and macOS text can contain them |
/// | Mojibake repair | **No** | Impossible to produce from a keyboard |
///
/// Verified against `ftfy` on 18 probe inputs: this recipe matches on 17, the
/// single exception being mojibake. The probes live in `tools/tokenizer_cases.py`
/// and their expected token IDs are asserted in `CLIPTokenizerTests`.
///
/// The curly-apostrophe case is the one that would have bitten us: "don’t" and
/// "don't" must tokenize identically, and without the fold they do not.
public enum CLIPTextCleaner {

    /// Quote and apostrophe characters `ftfy` folds to their ASCII equivalents.
    ///
    /// Note that `ftfy` does **not** fold dashes, so an em dash is left alone.
    /// Matching that exactly is the point; being more aggressive would be just
    /// as wrong as being less.
    private static let quoteFolds: [Character: Character] = [
        "\u{2018}": "'", "\u{2019}": "'", "\u{201A}": "'", "\u{201B}": "'",
        "\u{2032}": "'",
        "\u{201C}": "\"", "\u{201D}": "\"", "\u{201E}": "\"", "\u{201F}": "\"",
        "\u{2033}": "\"",
    ]

    public static func clean(_ text: String) -> String {
        var result = text.precomposedStringWithCanonicalMapping  // NFC
        result = foldQuotes(result)
        result = foldCompatibilityForms(result)
        // Applied twice, exactly as open_clip does, so "&amp;amp;" becomes "&".
        result = unescapeHTML(unescapeHTML(result))
        result = collapseWhitespace(result)
        return result.lowercased()
    }

    private static func foldQuotes(_ text: String) -> String {
        guard text.contains(where: { quoteFolds[$0] != nil }) else { return text }
        return String(text.map { quoteFolds[$0] ?? $0 })
    }

    /// Applies compatibility normalisation to the specific ranges `ftfy` folds,
    /// rather than running NFKC over everything.
    ///
    /// Full NFKC would overshoot: it expands a vulgar fraction to "1/2" and an
    /// ellipsis to three dots, and turns a non-breaking space into a plain one.
    /// `ftfy` leaves all three alone, so NFKC is applied per-character only
    /// within the ranges below.
    private static func foldCompatibilityForms(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: needsCompatibilityFold) else { return text }

        var result = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if needsCompatibilityFold(scalar) {
                let folded = String(scalar).precomposedStringWithCompatibilityMapping
                result.append(contentsOf: folded.unicodeScalars)
            } else {
                result.append(scalar)
            }
        }
        return String(result)
    }

    private static func needsCompatibilityFold(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        // Fullwidth ASCII variants.
        if (0xFF01...0xFF5E).contains(value) { return true }
        // Halfwidth katakana.
        if (0xFF61...0xFF9F).contains(value) { return true }
        // Latin ligatures.
        if (0xFB00...0xFB06).contains(value) { return true }
        return false
    }

    /// Collapses any run of Unicode whitespace to a single space and trims.
    ///
    /// Mirrors Python's `" ".join(text.split())`, which splits on all Unicode
    /// whitespace — including the non-breaking space that `ftfy` itself
    /// preserves. So a non-breaking space still ends up a plain separator here,
    /// just at this step rather than the previous one.
    private static func collapseWhitespace(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// The named HTML entities `html.unescape` resolves.
    ///
    /// Python's table has over 2,000 entries. This covers the ones that appear
    /// in real text; all numeric escapes are handled generically, and an unknown
    /// named entity is left as-is, which is what `html.unescape` also does.
    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
        "nbsp": "\u{00A0}", "ndash": "\u{2013}", "mdash": "\u{2014}",
        "hellip": "\u{2026}", "lsquo": "\u{2018}", "rsquo": "\u{2019}",
        "ldquo": "\u{201C}", "rdquo": "\u{201D}", "eacute": "é",
        "egrave": "è", "agrave": "à", "ccedil": "ç", "uuml": "ü",
        "ouml": "ö", "auml": "ä", "szlig": "ß", "copy": "©", "reg": "®",
        "trade": "™", "deg": "°", "euro": "€", "pound": "£", "yen": "¥",
        "cent": "¢", "frac12": "½", "times": "×",
    ]

    private static func unescapeHTML(_ text: String) -> String {
        guard text.contains("&") else { return text }

        var result = ""
        var index = text.startIndex

        while let ampersand = text[index...].firstIndex(of: "&") {
            result += text[index..<ampersand]

            // An entity is at most a few characters, so bound the search. This
            // keeps a bare "&" in a long string cheap to reject.
            let searchEnd = text.index(ampersand, offsetBy: 12, limitedBy: text.endIndex)
                ?? text.endIndex
            guard let semicolon = text[ampersand..<searchEnd].firstIndex(of: ";") else {
                result.append("&")
                index = text.index(after: ampersand)
                continue
            }

            let body = String(text[text.index(after: ampersand)..<semicolon])
            if let replacement = resolveEntity(body) {
                result += replacement
                index = text.index(after: semicolon)
            } else {
                result.append("&")
                index = text.index(after: ampersand)
            }
        }

        result += text[index...]
        return result
    }

    private static func resolveEntity(_ body: String) -> String? {
        guard !body.isEmpty else { return nil }

        if body.hasPrefix("#") {
            let digits = body.dropFirst()
            let value: UInt32?
            if digits.lowercased().hasPrefix("x") {
                value = UInt32(digits.dropFirst(), radix: 16)
            } else {
                value = UInt32(digits)
            }
            guard let value, let scalar = Unicode.Scalar(value) else { return nil }
            return String(Character(scalar))
        }

        // Case-sensitive first, since "&Amp;" is not "&amp;" in HTML5, but fall
        // back to lowercase for the common entities people type in any case.
        return namedEntities[body] ?? namedEntities[body.lowercased()]
    }
}
