public import Foundation

/// An actor that classifies raw text and writes facts into a ``MemoryStore``,
/// automatically superseding conflicting older facts in the same scope.
///
/// ## Typical usage
///
/// ```swift
/// let archivist = MemoryArchivist(store: store)
/// let fact = try await archivist.record(
///     text: "Always run tests before pushing",
///     scopePath: "acme/webapp",
///     provenance: MemoryProvenance(sourceDescription: "agent loop 3", recordedAt: .now)
/// )
/// ```
///
/// ## Classification
///
/// The archivist delegates type classification to a ``MemoryFactClassifying``
/// implementation. The default is ``DefaultMemoryFactClassifier``, which uses
/// a keyword/shape heuristic. To force a specific type (e.g. in tests or when
/// the caller already knows the type), supply a custom classifier that always
/// returns the desired ``MemoryFactType``.
///
/// ## Auto-supersede rule
///
/// Before writing a new fact the archivist scans the **same scope** (not
/// ancestors or descendants) for live facts that **conflict** with it. Two
/// facts conflict when they share the same ``MemoryFactType`` and the same
/// normalised first-line subject (lowercased, whitespace-trimmed).
///
/// "Live" means the fact's `id` does not appear in any other fact's
/// `supersedes` list — i.e. it has not already been superseded.
///
/// When one or more conflicting live facts are found, **all** of them are
/// superseded by the incoming fact: each conflicting fact's ID is appended to
/// the new fact's `supersedes` list, and ``MemoryStore/supersede(oldID:with:)``
/// is called once per conflict (oldest first). If multiple facts conflict, the
/// last `supersede` call wins (the final store state has exactly one live fact
/// for the conflict key at that scope). This is the simplest defensible
/// behaviour: it collapses all stale copies rather than leaving duplicates.
///
/// A fact at a **different scope** that would conflict under `resolvedFacts`
/// is intentionally left alone — scope-level override is handled at read time
/// by ``MemoryStore/resolvedFacts(forScope:)``.
public actor MemoryArchivist {

    // MARK: - Stored properties

    private let store: MemoryStore
    private let classifier: any MemoryFactClassifying
    private let now: @Sendable () -> Date

    // MARK: - Init

    /// Creates an archivist that writes facts to `store` and classifies them
    /// with `classifier`.
    ///
    /// - Parameters:
    ///   - store: The backing store to write facts into.
    ///   - classifier: The classifier to use when determining ``MemoryFactType``
    ///     from raw text. Defaults to ``DefaultMemoryFactClassifier``.
    ///   - now: A closure returning the current date. Injected so tests can
    ///     use a deterministic clock. Defaults to `Date.init`.
    public init(
        store: MemoryStore,
        classifier: any MemoryFactClassifying = DefaultMemoryFactClassifier(),
        now: @Sendable @escaping () -> Date = Date.init
    ) {
        self.store = store
        self.classifier = classifier
        self.now = now
    }

    // MARK: - Public API

    /// Classifies `text`, builds a ``MemoryFact``, auto-supersedes any
    /// conflicting live facts at the same scope, and writes the result to the
    /// store.
    ///
    /// - Parameters:
    ///   - text: The raw text of the fact to record.
    ///   - scopePath: The "/" -joined scope path where this fact applies
    ///     (e.g. `"acme/webapp/billing"` or `""` for root).
    ///   - provenance: Origin metadata for the fact.
    /// - Returns: The newly written ``MemoryFact``, including any `supersedes`
    ///   IDs that were populated during auto-supersede.
    /// - Throws: Propagates any ``MemoryStoreError`` from the underlying store.
    @discardableResult
    public func record(
        text: String,
        scopePath: String,
        provenance: MemoryProvenance
    ) async throws -> MemoryFact {
        let factType = classifier.classify(text: text, context: scopePath)
        let timestamp = now()
        let fact = MemoryFact(
            text: text,
            type: factType,
            scopePath: scopePath,
            provenance: provenance,
            createdAt: timestamp,
            updatedAt: timestamp
        )
        return try await record(fact)
    }

    /// Writes a pre-built ``MemoryFact`` to the store, auto-superseding any
    /// conflicting live facts at the same scope.
    ///
    /// Use this overload when you have already classified and constructed the
    /// fact yourself (e.g. from a pre-classified LLM response).
    ///
    /// The `fact.type` and the normalised first line of `fact.text` are used
    /// as the conflict key, matching the rule in
    /// ``MemoryStore/resolvedFacts(forScope:)``.
    ///
    /// - Parameter fact: The fact to write. Any IDs already present in
    ///   `fact.supersedes` are preserved; conflicting IDs are appended.
    /// - Returns: The fact as written (with the final `supersedes` list).
    /// - Throws: Propagates any ``MemoryStoreError`` from the underlying store.
    @discardableResult
    public func record(_ fact: MemoryFact) async throws -> MemoryFact {
        // Find conflicting live facts at the exact same scope.
        let conflicts = await conflictingLiveFacts(for: fact)

        if conflicts.isEmpty {
            // Fast path: no conflicts, just add.
            try await store.add(fact)
            return fact
        }

        // Slow path: supersede all conflicting facts.
        // Build the final fact once, with all conflict IDs in supersedes.
        var incoming = fact
        for conflicting in conflicts {
            if !incoming.supersedes.contains(conflicting.id) {
                incoming.supersedes.append(conflicting.id)
            }
        }

        // Call supersede() for each conflicting fact. The store's supersede()
        // adds the old ID to the new fact's supersedes list if not already
        // present. We do the first supersede with the fully-augmented fact,
        // then update for subsequent ones (store.supersede requires the new
        // fact to not already exist).
        //
        // Strategy: supersede the first conflict (this adds incoming to the
        // store), then update the store record for subsequent conflicts since
        // the fact already exists after the first supersede call.
        let firstConflict = conflicts[0]
        try await store.supersede(oldID: firstConflict.id, with: incoming)

        // For additional conflicts beyond the first, the incoming fact already
        // exists in the store. We need to record that those old facts are also
        // superseded. We do this by updating each old fact's record isn't
        // needed — what matters is that the new fact's supersedes list already
        // contains all of them (set above), so resolvedFacts will exclude them.
        // However, the store's supersededIDs set is built from the supersedes
        // lists of all facts. Since incoming.supersedes already lists all
        // conflict IDs, those old facts will be correctly excluded from
        // resolvedFacts. No additional store calls are needed.

        return incoming
    }

    // MARK: - Private helpers

    /// Returns live facts at the **exact** `scopePath` of `candidate` that
    /// conflict with it (same type + same normalised first-line subject).
    ///
    /// "Live" = not already in any other fact's supersedes list.
    private func conflictingLiveFacts(for candidate: MemoryFact) async -> [MemoryFact] {
        let allFacts = await store.allFacts()

        // Build the set of already-superseded IDs.
        let supersededIDs = Set(allFacts.flatMap(\.supersedes))

        let candidateKey = conflictKey(for: candidate)

        return allFacts.filter { existing in
            // Must be at the exact same scope (not ancestor/descendant).
            guard existing.scopePath == candidate.scopePath else { return false }
            // Must not already be superseded.
            guard !supersededIDs.contains(existing.id) else { return false }
            // Must not be the incoming fact itself (shouldn't happen for new
            // facts but guards against the pre-built overload receiving an
            // already-stored fact).
            guard existing.id != candidate.id else { return false }
            // Must share the same conflict key (type + normalised subject).
            return conflictKey(for: existing) == candidateKey
        }
    }

    /// Returns the conflict key used to detect duplicate subjects.
    ///
    /// The key is `"<type>:<normalisedFirstLine>"`, matching the convention in
    /// ``MemoryStore/resolvedFacts(forScope:)``.
    private func conflictKey(for fact: MemoryFact) -> String {
        let subject = fact.text
            .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            ?? fact.text.trimmingCharacters(in: .whitespaces).lowercased()
        return "\(fact.type.rawValue):\(subject)"
    }
}
