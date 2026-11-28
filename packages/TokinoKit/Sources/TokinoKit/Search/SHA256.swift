import Foundation

/// SHA-256, implemented here rather than taken from a library.
///
/// Needed to verify a downloaded embedding model against the checksum in
/// `EmbeddingModelDescriptor`. A model file is executable content as far as the
/// Neural Engine is concerned and it arrives over the network, so verifying it
/// is not optional.
///
/// Written from the specification for two reasons. CryptoKit is unavailable on
/// Linux, so using it would move verification into the iOS layer where it could
/// not be tested for free; and Swift Crypto would be the project's first
/// dependency, for one well-specified function. SHA-256 also has official test
/// vectors, so a from-scratch implementation can be held to a standard that
/// leaves no room for doubt — see `SHA256Tests`.
///
/// This is a checksum for integrity, not a password hash. Do not use it for
/// anything where an attacker chooses the input.
public struct SHA256 {

    /// FIPS 180-4 section 4.2.2: the first 32 bits of the fractional parts of
    /// the cube roots of the first 64 primes.
    private static let roundConstants: [UInt32] = [
        0x428a_2f98, 0x7137_4491, 0xb5c0_fbcf, 0xe9b5_dba5,
        0x3956_c25b, 0x59f1_11f1, 0x923f_82a4, 0xab1c_5ed5,
        0xd807_aa98, 0x1283_5b01, 0x2431_85be, 0x550c_7dc3,
        0x72be_5d74, 0x80de_b1fe, 0x9bdc_06a7, 0xc19b_f174,
        0xe49b_69c1, 0xefbe_4786, 0x0fc1_9dc6, 0x240c_a1cc,
        0x2de9_2c6f, 0x4a74_84aa, 0x5cb0_a9dc, 0x76f9_88da,
        0x983e_5152, 0xa831_c66d, 0xb003_27c8, 0xbf59_7fc7,
        0xc6e0_0bf3, 0xd5a7_9147, 0x06ca_6351, 0x1429_2967,
        0x27b7_0a85, 0x2e1b_2138, 0x4d2c_6dfc, 0x5338_0d13,
        0x650a_7354, 0x766a_0abb, 0x81c2_c92e, 0x9272_2c85,
        0xa2bf_e8a1, 0xa81a_664b, 0xc24b_8b70, 0xc76c_51a3,
        0xd192_e819, 0xd699_0624, 0xf40e_3585, 0x106a_a070,
        0x19a4_c116, 0x1e37_6c08, 0x2748_774c, 0x34b0_bcb5,
        0x391c_0cb3, 0x4ed8_aa4a, 0x5b9c_ca4f, 0x682e_6ff3,
        0x748f_82ee, 0x78a5_636f, 0x84c8_7814, 0x8cc7_0208,
        0x90be_fffa, 0xa450_6ceb, 0xbef9_a3f7, 0xc671_78f2,
    ]

    /// FIPS 180-4 section 5.3.3: the first 32 bits of the fractional parts of
    /// the square roots of the first eight primes.
    private static let initialState: [UInt32] = [
        0x6a09_e667, 0xbb67_ae85, 0x3c6e_f372, 0xa54f_f53a,
        0x510e_527f, 0x9b05_688c, 0x1f83_d9ab, 0x5be0_cd19,
    ]

    private var state = SHA256.initialState
    /// Bytes not yet forming a complete 64-byte block.
    private var pending = [UInt8]()
    /// Total message length, needed for the length suffix in the padding.
    private var byteCount: UInt64 = 0

    public init() {}

    /// Feeds more data. Call repeatedly to hash a file without loading it all
    /// into memory — a 79 MB model should not need 79 MB of RAM to verify.
    public mutating func update(_ data: some Sequence<UInt8>) {
        for byte in data {
            pending.append(byte)
            byteCount += 1
            if pending.count == 64 {
                compress(pending)
                pending.removeAll(keepingCapacity: true)
            }
        }
    }

    /// Finishes and returns the 32-byte digest.
    public mutating func finalize() -> [UInt8] {
        // FIPS 180-4 section 5.1.1: append 0x80, then zeros until the length is
        // 56 mod 64, then the message length in bits as a big-endian UInt64.
        let bitCount = byteCount * 8
        pending.append(0x80)
        while pending.count % 64 != 56 {
            pending.append(0)
        }
        withUnsafeBytes(of: bitCount.bigEndian) { pending.append(contentsOf: $0) }

        for offset in stride(from: 0, to: pending.count, by: 64) {
            compress(Array(pending[offset..<(offset + 64)]))
        }
        pending.removeAll()

        var digest = [UInt8]()
        digest.reserveCapacity(32)
        for word in state {
            withUnsafeBytes(of: word.bigEndian) { digest.append(contentsOf: $0) }
        }
        return digest
    }

    /// Processes one 64-byte block. FIPS 180-4 section 6.2.2.
    private mutating func compress(_ block: [UInt8]) {
        var schedule = [UInt32](repeating: 0, count: 64)

        for index in 0..<16 {
            let offset = index * 4
            schedule[index] =
                (UInt32(block[offset]) << 24)
                | (UInt32(block[offset + 1]) << 16)
                | (UInt32(block[offset + 2]) << 8)
                | UInt32(block[offset + 3])
        }
        for index in 16..<64 {
            let s0 = rotateRight(schedule[index - 15], 7)
                ^ rotateRight(schedule[index - 15], 18)
                ^ (schedule[index - 15] >> 3)
            let s1 = rotateRight(schedule[index - 2], 17)
                ^ rotateRight(schedule[index - 2], 19)
                ^ (schedule[index - 2] >> 10)
            // Wrapping arithmetic throughout: SHA-256 is defined modulo 2^32,
            // so an overflow trap here would be a bug, not a safety net.
            schedule[index] = schedule[index - 16]
                &+ s0
                &+ schedule[index - 7]
                &+ s1
        }

        var a = state[0], b = state[1], c = state[2], d = state[3]
        var e = state[4], f = state[5], g = state[6], h = state[7]

        for index in 0..<64 {
            let sigma1 = rotateRight(e, 6) ^ rotateRight(e, 11) ^ rotateRight(e, 25)
            let choose = (e & f) ^ (~e & g)
            let temp1 = h &+ sigma1 &+ choose &+ Self.roundConstants[index] &+ schedule[index]
            let sigma0 = rotateRight(a, 2) ^ rotateRight(a, 13) ^ rotateRight(a, 22)
            let majority = (a & b) ^ (a & c) ^ (b & c)
            let temp2 = sigma0 &+ majority

            h = g
            g = f
            f = e
            e = d &+ temp1
            d = c
            c = b
            b = a
            a = temp1 &+ temp2
        }

        state[0] &+= a
        state[1] &+= b
        state[2] &+= c
        state[3] &+= d
        state[4] &+= e
        state[5] &+= f
        state[6] &+= g
        state[7] &+= h
    }

    private func rotateRight(_ value: UInt32, _ amount: UInt32) -> UInt32 {
        (value >> amount) | (value << (32 - amount))
    }

    // MARK: - Convenience

    /// Digest of `data`, as lowercase hex — the form checksums are written in.
    public static func hexDigest(of data: some Sequence<UInt8>) -> String {
        var hasher = SHA256()
        hasher.update(data)
        return hex(hasher.finalize())
    }

    /// Digest of a file, read in chunks so memory use stays flat regardless of
    /// size. Returns nil when the file cannot be read.
    public static func hexDigestOfFile(
        at url: URL,
        chunkSize: Int = 1 << 20
    ) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            guard let chunk = try? handle.read(upToCount: chunkSize), !chunk.isEmpty else {
                break
            }
            hasher.update(chunk)
        }
        return hex(hasher.finalize())
    }

    public static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}
