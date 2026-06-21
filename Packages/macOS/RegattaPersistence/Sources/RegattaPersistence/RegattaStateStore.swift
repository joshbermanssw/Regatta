public import Foundation

/// The versioned JSON envelope written to disk by ``RegattaStateStore``.
///
/// The `version` field enables forward-compatible migration, mirroring the
/// `RegattaMemory.MemoryStore` on-disk format.
private struct StateEnvelope: Codable {
    var version: Int
    var state: RegattaStateSnapshot
}

/// An actor that persists Regatta's restorable state to a versioned JSON file
/// and loads it back on launch (issue #34, state persistence + session restore).
///
/// ## On-disk format
///
/// The snapshot is stored as pretty-printed JSON under
/// `baseDirectory/regatta-state.json`:
/// ```json
/// {
///   "version": 1,
///   "state": { "workers": [ … ], "loops": [ … ], "shepherds": [ … ], … }
/// }
/// ```
///
/// This matches how `RegattaMemory.MemoryStore` persists its facts (versioned
/// envelope, ISO-8601 dates, atomic writes), so both Regatta state files live
/// side by side under the same `~/Library/Application Support/Regatta/` tree and
/// behave consistently.
///
/// Memory facts are **not** stored here — `MemoryStore` already persists them
/// independently, and duplicating them would create two sources of truth.
///
/// ## Concurrency & testability
///
/// All access is actor-isolated and `async`. The base directory is injected so
/// tests use a temp directory with no global state.
public actor RegattaStateStore {

    // MARK: - Configuration

    /// The directory under which `regatta-state.json` is stored.
    private let baseDirectory: URL

    /// The current in-memory snapshot, kept consistent with disk.
    private var snapshot: RegattaStateSnapshot

    /// The on-disk schema version this store writes.
    private static let currentVersion = 1

    /// The file name of the state document within ``baseDirectory``.
    private static let fileName = "regatta-state.json"

    // MARK: - Init

    /// Creates a store that persists state under `baseDirectory`.
    ///
    /// The store loads any existing snapshot from disk synchronously during
    /// `init` so it is immediately consistent. A missing file is treated as an
    /// empty snapshot; a corrupt file is also treated as empty so a bad write
    /// can never wedge launch.
    ///
    /// - Parameter baseDirectory: The directory in which the state file lives.
    ///   It is created if it does not already exist.
    /// - Throws: A file-system error if `baseDirectory` cannot be created.
    public init(baseDirectory: URL) throws {
        self.baseDirectory = baseDirectory
        try FileManager.default.createDirectory(
            at: baseDirectory,
            withIntermediateDirectories: true
        )
        self.snapshot = (try? Self.load(from: baseDirectory)) ?? .empty
    }

    /// Returns the default base directory under Application Support.
    ///
    /// The directory is `~/Library/Application Support/Regatta`, matching the
    /// root used by `RegattaMemory` and `RegattaWorktreeManager`. The state file
    /// lives directly under it as `regatta-state.json`.
    public static func defaultBaseDirectory() -> URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Regatta", isDirectory: true)
    }

    // MARK: - Read

    /// The current persisted snapshot held in memory.
    public func currentSnapshot() -> RegattaStateSnapshot {
        snapshot
    }

    // MARK: - Write

    /// Replaces the entire snapshot and persists it atomically.
    ///
    /// - Parameter snapshot: The new state to persist.
    /// - Throws: ``RegattaStateStoreError/writeFailed(_:)`` on encode/write error.
    public func save(_ snapshot: RegattaStateSnapshot) throws {
        self.snapshot = snapshot
        try persist()
    }

    /// Applies a mutation to the current snapshot and persists the result.
    ///
    /// This is the convenient single-mutation-path entry point: callers describe
    /// the change, the store applies it to its authoritative copy and writes once.
    ///
    /// - Parameter mutate: A closure that edits the snapshot in place.
    /// - Throws: ``RegattaStateStoreError/writeFailed(_:)`` on encode/write error.
    public func update(_ mutate: (inout RegattaStateSnapshot) -> Void) throws {
        var copy = snapshot
        mutate(&copy)
        snapshot = copy
        try persist()
    }

    // MARK: - Private helpers

    private var storeURL: URL {
        baseDirectory.appendingPathComponent(Self.fileName)
    }

    private static func load(from directory: URL) throws -> RegattaStateSnapshot {
        let url = directory.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .empty
        }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let envelope = try decoder.decode(StateEnvelope.self, from: data)
            return envelope.state
        } catch {
            throw RegattaStateStoreError.readFailed(error)
        }
    }

    private func persist() throws {
        let envelope = StateEnvelope(version: Self.currentVersion, state: snapshot)
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(envelope)
            try data.write(to: storeURL, options: .atomic)
        } catch {
            throw RegattaStateStoreError.writeFailed(error)
        }
    }
}
