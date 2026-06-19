public import Foundation

// MARK: - Errors

/// Errors that can be thrown by ``MemoryStore``.
public enum MemoryStoreError: Error, Sendable {
    /// A fact with the given ID does not exist in the store.
    case factNotFound(String)
    /// A fact with the given ID already exists; use `update(_:)` to replace it.
    case duplicateID(String)
    /// The on-disk store file could not be read or decoded.
    case readFailed(any Error)
    /// The on-disk store file could not be written or encoded.
    case writeFailed(any Error)
}

// MARK: - On-disk envelope

/// The versioned JSON envelope written to disk.
///
/// Format (pretty-printed JSON):
/// ```json
/// {
///   "version": 1,
///   "facts": [ … ]
/// }
/// ```
///
/// The `version` field enables forward-compatible migration: a future reader
/// that encounters a higher version number can choose to migrate or reject the
/// file rather than silently mis-parsing it.
private struct StoreEnvelope: Codable {
    var version: Int
    var facts: [MemoryFact]
}

// MARK: - MemoryStore

/// An actor that persists memory facts to a human-readable, versioned JSON file.
///
/// ## On-disk format
///
/// Facts are stored as pretty-printed JSON under `baseDirectory/memory-facts.json`
/// with the versioned envelope:
/// ```json
/// {
///   "version": 1,
///   "facts": [ … ]
/// }
/// ```
///
/// ## Concurrency
///
/// All mutation and read methods are `async` and isolated to the actor. Callers
/// may safely call them from any Swift concurrency context.
///
/// ## Testability
///
/// Both the base directory and the clock are injected at initialisation time so
/// tests can use a temporary directory and a deterministic `now` function without
/// any global state.
public actor MemoryStore {

    // MARK: - Configuration

    /// The directory under which `memory-facts.json` is stored.
    private let baseDirectory: URL

    /// Returns the current date. Injected so tests can use a fixed clock.
    private let now: @Sendable () -> Date

    // MARK: - In-memory state

    private var facts: [String: MemoryFact] = [:]

    // MARK: - Init

    /// Creates a store that persists facts under `baseDirectory`.
    ///
    /// - Parameters:
    ///   - baseDirectory: The directory in which the store file will be written.
    ///     It will be created if it does not already exist.
    ///   - now: A closure returning the current date. Defaults to `Date.init` so
    ///     callers need not supply it in production.
    public init(
        baseDirectory: URL,
        now: @Sendable @escaping () -> Date = Date.init
    ) throws {
        self.baseDirectory = baseDirectory
        self.now = now
        try FileManager.default.createDirectory(
            at: baseDirectory,
            withIntermediateDirectories: true
        )
        self.facts = [:]
        // Load from disk synchronously during init so the store is immediately
        // consistent after construction. We silence "no facts yet" errors.
        if let loaded = try? Self.load(from: baseDirectory) {
            self.facts = Dictionary(uniqueKeysWithValues: loaded.map { ($0.id, $0) })
        }
    }

    // MARK: - Private helpers

    private var storeURL: URL {
        baseDirectory.appendingPathComponent("memory-facts.json")
    }

    private static func load(from directory: URL) throws -> [MemoryFact] {
        let url = directory.appendingPathComponent("memory-facts.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let envelope = try decoder.decode(StoreEnvelope.self, from: data)
            return envelope.facts
        } catch {
            throw MemoryStoreError.readFailed(error)
        }
    }

    private func persist() throws {
        let envelope = StoreEnvelope(
            version: 1,
            facts: facts.values.sorted { $0.createdAt < $1.createdAt }
        )
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(envelope)
            try data.write(to: storeURL, options: .atomic)
        } catch {
            throw MemoryStoreError.writeFailed(error)
        }
    }

    // MARK: - Write API

    /// Adds a new fact to the store and persists it to disk.
    ///
    /// - Throws: ``MemoryStoreError/duplicateID(_:)`` if a fact with the same
    ///   `id` already exists.
    public func add(_ fact: MemoryFact) throws {
        guard facts[fact.id] == nil else {
            throw MemoryStoreError.duplicateID(fact.id)
        }
        facts[fact.id] = fact
        try persist()
    }

    /// Replaces an existing fact with an updated version and persists it to disk.
    ///
    /// - Throws: ``MemoryStoreError/factNotFound(_:)`` if no fact with the
    ///   given `id` exists.
    public func update(_ fact: MemoryFact) throws {
        guard facts[fact.id] != nil else {
            throw MemoryStoreError.factNotFound(fact.id)
        }
        facts[fact.id] = fact
        try persist()
    }

    /// Records that `newFact` supersedes the fact identified by `oldID`.
    ///
    /// The new fact is added with its `supersedes` list extended to include
    /// `oldID`. The superseded fact remains in the store and is still
    /// retrievable by its original ID. This preserves the full history of how
    /// knowledge evolved so the Archivist can audit it later.
    ///
    /// - Throws: ``MemoryStoreError/factNotFound(_:)`` if no fact with `oldID`
    ///   exists; ``MemoryStoreError/duplicateID(_:)`` if a fact with `newFact.id`
    ///   already exists.
    public func supersede(oldID: String, with newFact: MemoryFact) throws {
        guard facts[oldID] != nil else {
            throw MemoryStoreError.factNotFound(oldID)
        }
        guard facts[newFact.id] == nil else {
            throw MemoryStoreError.duplicateID(newFact.id)
        }
        var updated = newFact
        if !updated.supersedes.contains(oldID) {
            updated.supersedes.append(oldID)
        }
        facts[updated.id] = updated
        try persist()
    }

    // MARK: - Read API

    /// Returns the fact with the given `id`, or `nil` if it does not exist.
    public func fact(id: String) -> MemoryFact? {
        facts[id]
    }

    /// Returns all facts in the store, sorted by creation date (oldest first).
    public func allFacts() -> [MemoryFact] {
        facts.values.sorted { $0.createdAt < $1.createdAt }
    }

    // MARK: - Query API

    /// Returns all facts whose `scopePath` starts with `scope`.
    ///
    /// The match is a prefix match on the full scope string: `"acme/webapp"` will
    /// match facts with `scopePath` equal to `"acme/webapp"` or any descendant
    /// such as `"acme/webapp/billing"`. Facts in sibling scopes (e.g.
    /// `"acme/webapps"`) are excluded because the prefix `"acme/webapp"` must be
    /// followed by `"/"` or be an exact match.
    ///
    /// Passing the empty string `""` returns every fact (root-scope prefix matches
    /// all paths).
    public func facts(inScope scope: String) -> [MemoryFact] {
        facts.values
            .filter { fact in
                if scope.isEmpty { return true }
                if fact.scopePath == scope { return true }
                return fact.scopePath.hasPrefix(scope + "/")
            }
            .sorted { $0.createdAt < $1.createdAt }
    }

    /// Returns all facts whose `text` contains `text` (case-insensitive
    /// substring search).
    public func search(_ text: String) -> [MemoryFact] {
        let needle = text.lowercased()
        return facts.values
            .filter { $0.text.lowercased().contains(needle) }
            .sorted { $0.createdAt < $1.createdAt }
    }

    // MARK: - Inheritance-aware recall

    /// Returns the resolved set of facts that apply at `scope`, applying
    /// inheritance and conflict-supersede rules.
    ///
    /// ## What "applies at scope" means
    ///
    /// A fact *applies* at a given scope when its `scopePath` is either:
    /// - Exactly the target scope, OR
    /// - An ancestor of the target scope (i.e. its `scopePath` is a strict
    ///   prefix component of the target scope's path).
    ///
    /// For example, if the target scope is `"acme/webapp/billing"`, then facts
    /// with `scopePath` values of `""`, `"acme"`, `"acme/webapp"`, and
    /// `"acme/webapp/billing"` all apply. Facts in a sibling scope such as
    /// `"acme/webapps"` do NOT apply.
    ///
    /// ## Override / conflict-supersede rule
    ///
    /// Two facts **conflict** when they share the same ``MemoryFactType`` and
    /// the same normalised first line of text (the "subject"). The normalised
    /// subject is `fact.text` lowercased and stripped of leading/trailing
    /// whitespace; only the first line is used, so multi-line facts that differ
    /// after the first line can still conflict.
    ///
    /// When two facts conflict, the fact at the **nearer (more specific) scope**
    /// wins: its text and metadata are used, and the ancestor's fact is excluded
    /// from the resolved set.
    ///
    /// ## Return order
    ///
    /// Facts are returned ordered from **most-distant ancestor scope first**
    /// (root) to **target scope last**, and within each scope by creation date
    /// (oldest first). This means callers who process the list in order will
    /// naturally see overriding facts later, making it easy to fold them with a
    /// "last write wins" reduction if desired.
    ///
    /// Superseded facts (i.e. facts whose `id` appears in another fact's
    /// `supersedes` list within the same store) are excluded from the resolved
    /// set, preserving history while returning only the live knowledge.
    ///
    /// - Parameter scope: The target scope path. Use `""` for root — this
    ///   returns only root-scope facts (no ancestors above root).
    /// - Returns: The resolved, deduplicated, override-applied fact list.
    public func resolvedFacts(forScope scope: String) -> [MemoryFact] {
        let targetScope = MemoryScope(path: scope)

        // Collect the full ancestry chain: root → ... → targetScope.
        let ancestorChain = targetScope.ancestors()
        // ancestorChain already includes targetScope itself as the last element.

        // Build the set of all fact IDs that have been superseded within this
        // store. A superseded fact is live history, but must not appear in the
        // resolved output.
        let supersededIDs = Set(facts.values.flatMap(\.supersedes))

        // Collect live facts for each scope level in the ancestry chain,
        // maintaining the root→nearest order.
        var buckets: [[MemoryFact]] = []
        for ancestor in ancestorChain {
            let liveFacts = facts.values
                .filter { $0.scopePath == ancestor.path && !supersededIDs.contains($0.id) }
                .sorted { $0.createdAt < $1.createdAt }
            if !liveFacts.isEmpty {
                buckets.append(liveFacts)
            }
        }

        // Flatten in ancestor→nearest order so we can apply overrides.
        let ordered: [MemoryFact] = buckets.flatMap { $0 }

        // Apply conflict-supersede: for each (type, normalisedSubject) key,
        // keep only the fact from the most-specific (nearest) scope. Because
        // `ordered` is already sorted root→nearest, we iterate and the last
        // entry for a given key wins — achieved by using a dictionary and
        // overwriting with later (nearer) values.
        //
        // We preserve insertion order so the final output respects the
        // ancestor→nearest ordering.
        typealias ConflictKey = String
        func conflictKey(for fact: MemoryFact) -> ConflictKey {
            let subject = fact.text
                .split(separator: "\n", maxSplits: 1)
                .first
                .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                ?? fact.text.trimmingCharacters(in: .whitespaces).lowercased()
            return "\(fact.type.rawValue):\(subject)"
        }

        // First pass: determine, for each key, which fact (id) is the winner
        // (the nearest-scope one). Since ordered is ancestor→nearest, the last
        // assignment wins.
        var winnerByKey: [ConflictKey: String] = [:]
        for fact in ordered {
            winnerByKey[conflictKey(for: fact)] = fact.id
        }

        // Second pass: retain only facts whose id is the winner for their key,
        // preserving the original ancestor→nearest order.
        let winnerIDs = Set(winnerByKey.values)
        return ordered.filter { winnerIDs.contains($0.id) }
    }
}
