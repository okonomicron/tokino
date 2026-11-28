import Foundation
import SQLite3
import TokinoKit

/// The on-device photo index: embeddings plus the metadata search filters need.
///
/// SQLite via the C API rather than a wrapper library, because it is already on
/// the system and TokinoKit's no-dependencies rule is worth extending to the
/// app where it costs little.
///
/// Search loads every vector into one contiguous buffer and scans it. At one
/// user's scale — tens of thousands of 512-float vectors, about 40 MB — that is
/// exact and takes tens of milliseconds, where an approximate index would add
/// recall error and a build step to solve a problem we do not have.
///
/// An actor because the scan writes while the UI reads, and `sqlite3` handles
/// are not thread-safe in the default serialized-but-not-concurrent mode.
public actor LocalVectorStore: EmbeddingStore {

    public enum StoreError: Error, CustomStringConvertible {
        case cannotOpen(String)
        case sqlite(String)

        public var description: String {
            switch self {
            case .cannotOpen(let path): return "Could not open the index at \(path)."
            case .sqlite(let message): return "SQLite error: \(message)"
            }
        }
    }

    /// Owns the raw `sqlite3` pointer and closes it.
    ///
    /// A separate class because an actor's `deinit` is nonisolated and so
    /// cannot touch the actor's own non-Sendable state — Swift 6 rejects
    /// reading an `OpaquePointer?` there. Giving the pointer its own owner means
    /// the close happens in *that* type's deinit, which has no isolation to
    /// cross. The actor keeps it alive and serialises every use.
    private final class Connection {
        let pointer: OpaquePointer

        init(pointer: OpaquePointer) {
            self.pointer = pointer
        }

        deinit {
            sqlite3_close_v2(pointer)
        }
    }

    private let connection: Connection
    private let path: String

    /// The raw pointer, for the query helpers below.
    private var handle: OpaquePointer { connection.pointer }

    /// Opens, or creates, the index at `url`.
    public init(url: URL) throws {
        self.path = url.path

        var pointer: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &pointer, flags, nil) == SQLITE_OK, let pointer else {
            throw StoreError.cannotOpen(path)
        }
        self.connection = Connection(pointer: pointer)

        try Self.configure(pointer)
        try Self.migrate(pointer)
    }

    private static func configure(_ handle: OpaquePointer) throws {
        // WAL so a long scan's writes do not block the UI's reads.
        try execute(handle, "PRAGMA journal_mode = WAL;")
        // NORMAL rather than FULL: an index entry lost to a sudden power cut is
        // re-derived by the next scan, so paying for a full fsync per batch
        // buys nothing.
        try execute(handle, "PRAGMA synchronous = NORMAL;")
        try execute(handle, "PRAGMA foreign_keys = ON;")
    }

    private static func migrate(_ handle: OpaquePointer) throws {
        try execute(
            handle,
            """
            CREATE TABLE IF NOT EXISTS embedding (
                local_identifier   TEXT PRIMARY KEY NOT NULL,
                vector             BLOB NOT NULL,
                dimensions         INTEGER NOT NULL,
                model_identifier   TEXT NOT NULL,
                source_modified_at REAL,
                embedded_at        REAL NOT NULL
            );
            """
        )
        // Lets a model upgrade find stale rows without reading every vector.
        try execute(
            handle,
            "CREATE INDEX IF NOT EXISTS embedding_model_idx ON embedding(model_identifier);"
        )
        try execute(
            handle,
            """
            CREATE TABLE IF NOT EXISTS asset_metadata (
                local_identifier TEXT PRIMARY KEY NOT NULL,
                created_at       REAL,
                latitude         REAL,
                longitude        REAL,
                pixel_width      INTEGER NOT NULL DEFAULT 0,
                pixel_height     INTEGER NOT NULL DEFAULT 0,
                duration         REAL,
                album_names      TEXT NOT NULL DEFAULT '',
                media_kind       TEXT NOT NULL DEFAULT 'image',
                quality          REAL NOT NULL DEFAULT 1.0,
                is_excluded      INTEGER NOT NULL DEFAULT 0
            );
            """
        )
        // The scan checkpoint lives here too, as a single JSON row: it is
        // written once per batch and read once per launch, so a table of its
        // own would be more machinery than the job needs.
        try execute(
            handle,
            """
            CREATE TABLE IF NOT EXISTS scan_state (
                id         INTEGER PRIMARY KEY CHECK (id = 1),
                checkpoint BLOB NOT NULL
            );
            """
        )
    }

    // MARK: - EmbeddingStore

    public func indexedRecords() async throws -> [IndexedAssetRecord] {
        let sql = """
            SELECT local_identifier, embedded_at, source_modified_at, model_identifier
            FROM embedding;
            """
        var records: [IndexedAssetRecord] = []
        try query(sql) { statement in
            guard let identifier = Self.text(statement, 0) else { return }
            records.append(
                IndexedAssetRecord(
                    localIdentifier: identifier,
                    indexedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                    sourceModificationDate: Self.optionalDate(statement, 2),
                    modelIdentifier: Self.text(statement, 3) ?? ""
                )
            )
        }
        return records
    }

    public func store(_ embeddings: [StoredEmbedding]) async throws {
        guard !embeddings.isEmpty else { return }

        // One transaction per batch, so an interrupted scan leaves the store
        // consistent rather than half-written. ScanEngine writes here before
        // advancing its checkpoint, so a crash between the two re-does a batch
        // instead of skipping it.
        try Self.execute(handle, "BEGIN IMMEDIATE;")
        do {
            let sql = """
                INSERT INTO embedding
                    (local_identifier, vector, dimensions, model_identifier,
                     source_modified_at, embedded_at)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(local_identifier) DO UPDATE SET
                    vector = excluded.vector,
                    dimensions = excluded.dimensions,
                    model_identifier = excluded.model_identifier,
                    source_modified_at = excluded.source_modified_at,
                    embedded_at = excluded.embedded_at;
                """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
                  let statement
            else { throw StoreError.sqlite(lastErrorMessage()) }
            defer { sqlite3_finalize(statement) }

            for embedding in embeddings {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)

                sqlite3_bind_text(statement, 1, embedding.localIdentifier, -1, nil)
                let blob = Self.blob(from: embedding.vector)
                _ = blob.withUnsafeBytes { bytes in
                    sqlite3_bind_blob(statement, 2, bytes.baseAddress, Int32(bytes.count), nil)
                }
                sqlite3_bind_int(statement, 3, Int32(embedding.vector.count))
                sqlite3_bind_text(statement, 4, embedding.modelIdentifier, -1, nil)
                if let modified = embedding.sourceModificationDate {
                    sqlite3_bind_double(statement, 5, modified.timeIntervalSince1970)
                } else {
                    sqlite3_bind_null(statement, 5)
                }
                sqlite3_bind_double(statement, 6, embedding.embeddedAt.timeIntervalSince1970)

                guard sqlite3_step(statement) == SQLITE_DONE else {
                    throw StoreError.sqlite(lastErrorMessage())
                }
            }
            try Self.execute(handle, "COMMIT;")
        } catch {
            try? Self.execute(handle, "ROLLBACK;")
            throw error
        }
    }

    public func remove(localIdentifiers: [String]) async throws {
        guard !localIdentifiers.isEmpty else { return }

        try Self.execute(handle, "BEGIN IMMEDIATE;")
        do {
            for table in ["embedding", "asset_metadata"] {
                let sql = "DELETE FROM \(table) WHERE local_identifier = ?;"
                var statement: OpaquePointer?
                guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
                      let statement
                else { throw StoreError.sqlite(lastErrorMessage()) }
                defer { sqlite3_finalize(statement) }

                for identifier in localIdentifiers {
                    sqlite3_reset(statement)
                    sqlite3_clear_bindings(statement)
                    sqlite3_bind_text(statement, 1, identifier, -1, nil)
                    guard sqlite3_step(statement) == SQLITE_DONE else {
                        throw StoreError.sqlite(lastErrorMessage())
                    }
                }
            }
            try Self.execute(handle, "COMMIT;")
        } catch {
            try? Self.execute(handle, "ROLLBACK;")
            throw error
        }
    }

    // MARK: - Metadata

    /// Upserts the metadata search filters read.
    ///
    /// Separate from `store` because metadata comes from PhotoKit while vectors
    /// come from Core ML, and the two are gathered at different points.
    public func storeMetadata(_ metadata: [String: PhotoAssetMetadata]) throws {
        guard !metadata.isEmpty else { return }

        try Self.execute(handle, "BEGIN IMMEDIATE;")
        do {
            let sql = """
                INSERT INTO asset_metadata
                    (local_identifier, created_at, latitude, longitude, pixel_width,
                     pixel_height, duration, album_names, media_kind, quality, is_excluded)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0)
                ON CONFLICT(local_identifier) DO UPDATE SET
                    created_at = excluded.created_at,
                    latitude = excluded.latitude,
                    longitude = excluded.longitude,
                    pixel_width = excluded.pixel_width,
                    pixel_height = excluded.pixel_height,
                    duration = excluded.duration,
                    album_names = excluded.album_names,
                    media_kind = excluded.media_kind,
                    quality = excluded.quality;
                """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
                  let statement
            else { throw StoreError.sqlite(lastErrorMessage()) }
            defer { sqlite3_finalize(statement) }

            for (identifier, value) in metadata {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)

                sqlite3_bind_text(statement, 1, identifier, -1, nil)
                if let createdAt = value.createdAt {
                    sqlite3_bind_double(statement, 2, createdAt.timeIntervalSince1970)
                } else {
                    sqlite3_bind_null(statement, 2)
                }
                if let coordinate = value.coordinate {
                    sqlite3_bind_double(statement, 3, coordinate.latitude)
                    sqlite3_bind_double(statement, 4, coordinate.longitude)
                } else {
                    sqlite3_bind_null(statement, 3)
                    sqlite3_bind_null(statement, 4)
                }
                sqlite3_bind_int(statement, 5, Int32(value.pixelWidth))
                sqlite3_bind_int(statement, 6, Int32(value.pixelHeight))
                if let duration = value.duration {
                    sqlite3_bind_double(statement, 7, duration)
                } else {
                    sqlite3_bind_null(statement, 7)
                }
                // Tab-separated: album names cannot contain a tab, and this
                // avoids a join table for a field only ever read whole.
                sqlite3_bind_text(statement, 8, value.albumNames.joined(separator: "\t"), -1, nil)
                sqlite3_bind_text(statement, 9, value.mediaKind.rawValue, -1, nil)
                sqlite3_bind_double(statement, 10, 1.0)

                guard sqlite3_step(statement) == SQLITE_DONE else {
                    throw StoreError.sqlite(lastErrorMessage())
                }
            }
            try Self.execute(handle, "COMMIT;")
        } catch {
            try? Self.execute(handle, "ROLLBACK;")
            throw error
        }
    }

    /// Marks assets the user has excluded from all strategies.
    public func setExcluded(_ excluded: Bool, for localIdentifiers: [String]) throws {
        guard !localIdentifiers.isEmpty else { return }
        let sql = "UPDATE asset_metadata SET is_excluded = ? WHERE local_identifier = ?;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement
        else { throw StoreError.sqlite(lastErrorMessage()) }
        defer { sqlite3_finalize(statement) }

        for identifier in localIdentifiers {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            sqlite3_bind_int(statement, 1, excluded ? 1 : 0)
            sqlite3_bind_text(statement, 2, identifier, -1, nil)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw StoreError.sqlite(lastErrorMessage())
            }
        }
    }

    // MARK: - Search

    /// Every candidate for the given model, ready for `SimilaritySearch`.
    ///
    /// Filtered by model identifier in SQL rather than in Swift: vectors from a
    /// superseded model are not comparable, and there is no point reading them
    /// off disk to discard them.
    public func searchCandidates(modelIdentifier: String) throws -> [SearchCandidate] {
        let sql = """
            SELECT e.local_identifier, e.vector, m.created_at, m.latitude, m.longitude,
                   m.album_names, m.media_kind, m.quality, m.is_excluded
            FROM embedding e
            LEFT JOIN asset_metadata m ON m.local_identifier = e.local_identifier
            WHERE e.model_identifier = ?;
            """
        var candidates: [SearchCandidate] = []

        try query(sql, bind: { statement in
            sqlite3_bind_text(statement, 1, modelIdentifier, -1, nil)
        }) { statement in
            guard let identifier = Self.text(statement, 0),
                  let vector = Self.floats(statement, 1)
            else { return }

            let coordinate: Coordinate?
            if sqlite3_column_type(statement, 3) != SQLITE_NULL,
               sqlite3_column_type(statement, 4) != SQLITE_NULL {
                coordinate = Coordinate(
                    latitude: sqlite3_column_double(statement, 3),
                    longitude: sqlite3_column_double(statement, 4)
                )
            } else {
                coordinate = nil
            }

            let albums = (Self.text(statement, 5) ?? "")
                .split(separator: "\t")
                .map(String.init)
            let kind = MediaKind(rawValue: Self.text(statement, 6) ?? "image") ?? .image

            candidates.append(
                SearchCandidate(
                    // The identifier here is PhotoKit's, which is a string, so
                    // a stable UUID is derived from it for the shared type.
                    assetID: .deterministic(from: identifier),
                    vector: vector,
                    createdAt: Self.optionalDate(statement, 2),
                    coordinate: coordinate,
                    albumNames: albums,
                    mediaKind: kind,
                    quality: sqlite3_column_double(statement, 7),
                    isExcluded: sqlite3_column_int(statement, 8) == 1
                )
            )
        }
        return candidates
    }

    /// Maps the derived asset identifiers in search results back to PhotoKit's.
    public func localIdentifiers(for assetIDs: [Identifier<PhotoAsset>]) throws -> [
        Identifier<PhotoAsset>: String
    ] {
        var mapping: [Identifier<PhotoAsset>: String] = [:]
        let wanted = Set(assetIDs)
        try query("SELECT local_identifier FROM embedding;") { statement in
            guard let identifier = Self.text(statement, 0) else { return }
            let derived = Identifier<PhotoAsset>.deterministic(from: identifier)
            if wanted.contains(derived) { mapping[derived] = identifier }
        }
        return mapping
    }

    // MARK: - Checkpoint

    public func loadCheckpointData() throws -> Data? {
        var result: Data?
        try query("SELECT checkpoint FROM scan_state WHERE id = 1;") { statement in
            result = Self.data(statement, 0)
        }
        return result
    }

    public func saveCheckpointData(_ data: Data) throws {
        let sql = """
            INSERT INTO scan_state (id, checkpoint) VALUES (1, ?)
            ON CONFLICT(id) DO UPDATE SET checkpoint = excluded.checkpoint;
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement
        else { throw StoreError.sqlite(lastErrorMessage()) }
        defer { sqlite3_finalize(statement) }

        _ = data.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, 1, bytes.baseAddress, Int32(bytes.count), nil)
        }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw StoreError.sqlite(lastErrorMessage())
        }
    }

    public func clearCheckpoint() throws {
        try Self.execute(handle, "DELETE FROM scan_state WHERE id = 1;")
    }

    // MARK: - Plumbing

    private func query(
        _ sql: String,
        bind: ((OpaquePointer) -> Void)? = nil,
        row: (OpaquePointer) -> Void
    ) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement
        else { throw StoreError.sqlite(lastErrorMessage()) }
        defer { sqlite3_finalize(statement) }

        bind?(statement)
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_ROW {
                row(statement)
            } else if step == SQLITE_DONE {
                break
            } else {
                throw StoreError.sqlite(lastErrorMessage())
            }
        }
    }

    private func lastErrorMessage() -> String {
        guard let message = sqlite3_errmsg(handle) else { return "unknown" }
        return String(cString: message)
    }

    private static func execute(_ handle: OpaquePointer, _ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(error)
            throw StoreError.sqlite(message)
        }
    }

    /// Vectors are stored as little-endian float32, which is the native layout
    /// on every device this runs on, so reading them back is a memcpy.
    private static func blob(from vector: [Float]) -> Data {
        var data = Data(capacity: vector.count * 4)
        for value in vector {
            var littleEndian = value.bitPattern.littleEndian
            withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    private static func floats(_ statement: OpaquePointer, _ column: Int32) -> [Float]? {
        guard let pointer = sqlite3_column_blob(statement, column) else { return nil }
        let byteCount = Int(sqlite3_column_bytes(statement, column))
        guard byteCount > 0, byteCount % 4 == 0 else { return nil }

        let bytes = UnsafeRawBufferPointer(start: pointer, count: byteCount)
        var result = [Float](repeating: 0, count: byteCount / 4)
        for index in 0..<result.count {
            let raw = bytes.loadUnaligned(fromByteOffset: index * 4, as: UInt32.self)
            result[index] = Float(bitPattern: UInt32(littleEndian: raw))
        }
        return result
    }

    private static func text(_ statement: OpaquePointer, _ column: Int32) -> String? {
        guard let pointer = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: pointer)
    }

    private static func data(_ statement: OpaquePointer, _ column: Int32) -> Data? {
        guard let pointer = sqlite3_column_blob(statement, column) else { return nil }
        let count = Int(sqlite3_column_bytes(statement, column))
        guard count > 0 else { return nil }
        return Data(bytes: pointer, count: count)
    }

    private static func optionalDate(_ statement: OpaquePointer, _ column: Int32) -> Date? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        return Date(timeIntervalSince1970: sqlite3_column_double(statement, column))
    }
}
