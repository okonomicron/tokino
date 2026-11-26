import Foundation

/// A type-safe wrapper around a UUID primary key.
///
/// Using a phantom type parameter means `Identifier<PhotoAsset>` cannot be passed where
/// `Identifier<ContentDraft>` is expected, which the compiler enforces at no runtime cost.
/// This matters because the publishing pipeline threads a dozen different IDs
/// through the same functions.
public struct Identifier<Subject>: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: UUID

    public init(_ rawValue: UUID) {
        self.rawValue = rawValue
    }

    public init() {
        self.rawValue = UUID()
    }

    /// Fails rather than substituting a random UUID, so a malformed server
    /// payload surfaces as a decoding error instead of silently orphaning a row.
    public init?(uuidString: String) {
        guard let uuid = UUID(uuidString: uuidString) else { return nil }
        self.rawValue = uuid
    }

    public var description: String { rawValue.uuidString }

    // Encoded as a bare string, matching Postgres `uuid` columns over JSON.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        guard let uuid = UUID(uuidString: string) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected a UUID string, found \(string.isEmpty ? "<empty>" : string)"
            )
        }
        self.rawValue = uuid
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue.uuidString)
    }
}

extension Identifier {
    /// Derives a stable identifier from a string.
    ///
    /// Needed wherever an identifier must be reproducible rather than random:
    /// deterministic mock fixtures, and idempotency keys that a retry has to
    /// recompute identically after a process restart.
    ///
    /// This is a plain hash, not a cryptographic one — it is for stability, not
    /// secrecy, and must not be used where unpredictability matters.
    public static func deterministic(from seed: String) -> Identifier<Subject> {
        var bytes = [UInt8]()
        // Two FNV-1a passes with different offset bases give the 16 bytes a
        // UUID needs. Collisions are possible in principle; for fixture and
        // idempotency use the seeds are distinct by construction.
        for basis in [UInt64(0xcbf2_9ce4_8422_2325), UInt64(0x9e37_79b9_7f4a_7c15)] {
            var hash = basis
            for byte in seed.utf8 {
                hash ^= UInt64(byte)
                hash = hash.multipliedReportingOverflow(by: 0x100_0000_01b3).partialValue
            }
            withUnsafeBytes(of: hash.bigEndian) { bytes.append(contentsOf: $0) }
        }

        // Stamp version 5 and the RFC 4122 variant so the result is a
        // well-formed UUID that Postgres will accept.
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80

        let uuid = UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
        return Identifier(uuid)
    }
}
