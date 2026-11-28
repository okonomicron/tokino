import Foundation
import Testing
@testable import TokinoKit

/// Holds the from-scratch SHA-256 to the published standard.
///
/// A hand-written hash is only acceptable if it is checked against official
/// vectors rather than against itself. These come from FIPS 180-2 Appendix B,
/// NIST's CAVP examples, and the empty-string digest everyone knows — so a
/// subtle error in the message schedule or the padding cannot pass.
@Suite("SHA-256")
struct SHA256Tests {

    /// Published digests. Each is quoted from a standard or a widely-reproduced
    /// reference, never computed by this implementation.
    static let vectors: [(input: String, expected: String)] = [
        // FIPS 180-2 B.1: one-block message.
        ("abc", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"),
        // The empty string, from NIST's CAVP examples.
        ("", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),
        // FIPS 180-2 B.2: multi-block message.
        (
            "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq",
            "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
        ),
        // Single character, exercising the shortest non-empty padding.
        ("a", "ca978112ca1bbdcafac231b39a23dc4da786eff8147c4e72b9807785afee48bb"),
        // Common reference vector.
        (
            "The quick brown fox jumps over the lazy dog",
            "d7a8fbb307d7809469ca9abcb0082e4f8d5651e46d3cdb762d02d0bf37c9e592"
        ),
        // The same with a full stop: a one-byte change must change the whole
        // digest, which is the avalanche property.
        (
            "The quick brown fox jumps over the lazy dog.",
            "ef537f25c895bfa782526529a9b63d97aa631564d5d789c2b765448c8635fb6c"
        ),
    ]

    @Test("published test vectors are reproduced exactly")
    func publishedVectors() {
        for vector in Self.vectors {
            let actual = SHA256.hexDigest(of: Array(vector.input.utf8))
            #expect(
                actual == vector.expected,
                "input \(vector.input.debugDescription):\n  expected \(vector.expected)\n  actual   \(actual)"
            )
        }
    }

    /// FIPS 180-2 B.3: a million 'a' characters. Catches errors in the length
    /// suffix and in multi-block accumulation that short inputs do not.
    @Test("the million-character vector is reproduced")
    func millionCharacterVector() {
        let input = [UInt8](repeating: UInt8(ascii: "a"), count: 1_000_000)
        #expect(
            SHA256.hexDigest(of: input)
                == "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0"
        )
    }

    // MARK: - Block boundaries
    //
    // The padding rule changes behaviour around 56 and 64 bytes, which is where
    // a hand-written implementation is most likely to be wrong. Each of these
    // is compared against the single-shot result for the same bytes, and the
    // single-shot path is itself pinned by the published vectors above.

    @Test(
        "lengths around the block boundary hash consistently",
        arguments: [54, 55, 56, 57, 63, 64, 65, 119, 120, 127, 128, 129]
    )
    func blockBoundaryLengths(length: Int) {
        let input = (0..<length).map { UInt8($0 % 251) }

        let oneShot = SHA256.hexDigest(of: input)

        // Byte at a time, so the internal buffering is exercised differently.
        var incremental = SHA256()
        for byte in input { incremental.update([byte]) }
        #expect(SHA256.hex(incremental.finalize()) == oneShot)

        // And in two uneven halves.
        var split = SHA256()
        let midpoint = length / 3
        split.update(input[0..<midpoint])
        split.update(input[midpoint...])
        #expect(SHA256.hex(split.finalize()) == oneShot)
    }

    /// 55 and 56 bytes straddle the point where the length suffix no longer
    /// fits in the same block, so they must differ and both must be stable.
    @Test("the 55 and 56 byte cases are distinct")
    func paddingBoundaryIsHandled() {
        let fiftyFive = SHA256.hexDigest(of: [UInt8](repeating: 0x61, count: 55))
        let fiftySix = SHA256.hexDigest(of: [UInt8](repeating: 0x61, count: 56))
        #expect(fiftyFive != fiftySix)
        #expect(fiftyFive.count == 64)
        #expect(fiftySix.count == 64)
    }

    // MARK: - Shape

    @Test("a digest is always 64 lowercase hex characters")
    func digestShape() {
        for length in [0, 1, 31, 32, 33, 1000] {
            let digest = SHA256.hexDigest(of: [UInt8](repeating: 7, count: length))
            #expect(digest.count == 64)
            #expect(digest.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        }
    }

    /// Streaming must agree with one-shot whatever the chunk sizes, since file
    /// verification reads in 1 MB chunks.
    @Test("chunked hashing agrees with one-shot", arguments: [1, 7, 64, 100, 4096])
    func chunkedMatchesOneShot(chunkSize: Int) {
        let input = (0..<10_000).map { UInt8($0 % 256) }
        let expected = SHA256.hexDigest(of: input)

        var hasher = SHA256()
        var offset = 0
        while offset < input.count {
            let end = min(offset + chunkSize, input.count)
            hasher.update(input[offset..<end])
            offset = end
        }
        #expect(SHA256.hex(hasher.finalize()) == expected)
    }

    // MARK: - File hashing

    @Test("hashing a file matches hashing its bytes")
    func fileDigestMatchesInMemory() throws {
        let bytes = (0..<300_000).map { UInt8(($0 * 31) % 256) }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokino-sha256-\(UUID().uuidString)")
        try Data(bytes).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let fileDigest = SHA256.hexDigestOfFile(at: url)
        #expect(fileDigest == SHA256.hexDigest(of: bytes))
    }

    @Test("hashing an empty file gives the empty digest")
    func emptyFileDigest() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokino-sha256-empty-\(UUID().uuidString)")
        try Data().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(
            SHA256.hexDigestOfFile(at: url)
                == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )
    }

    /// A missing file must be distinguishable from a file that hashes to
    /// something, or a failed download would look like a corrupt one.
    @Test("a missing file yields nil rather than a digest")
    func missingFileYieldsNil() {
        let url = URL(fileURLWithPath: "/nonexistent/tokino/\(UUID().uuidString)")
        #expect(SHA256.hexDigestOfFile(at: url) == nil)
    }

    /// Flipping one bit must change the digest. Without this a stubbed
    /// implementation returning a constant would pass several tests above.
    @Test("a single changed byte changes the digest")
    func avalanche() {
        var input = [UInt8](repeating: 0, count: 128)
        let original = SHA256.hexDigest(of: input)
        input[64] = 1
        let changed = SHA256.hexDigest(of: input)

        #expect(original != changed)
        // Roughly half the hex characters should differ. A weak implementation
        // that only mixed locally would change very few.
        let differing = zip(original, changed).count { $0 != $1 }
        #expect(differing > 20, "only \(differing) of 64 hex characters changed")
    }
}
