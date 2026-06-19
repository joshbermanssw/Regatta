import Foundation
import Testing

@testable import RegattaMemory

// MARK: - Helpers

private func makeTempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("RegattaArchivistTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func removeTempDir(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
}

private func makeProvenance(
    workerID: String? = nil,
    description: String = "archivist-test"
) -> MemoryProvenance {
    MemoryProvenance(
        workerID: workerID,
        sourceDescription: description,
        recordedAt: Date(timeIntervalSince1970: 1_000_000)
    )
}

// MARK: - Fake classifier for deterministic testing

/// A ``MemoryFactClassifying`` implementation that always returns a fixed type.
private struct FixedClassifier: MemoryFactClassifying {
    let type: MemoryFactType
    func classify(text: String, context: String?) -> MemoryFactType { type }
}

// MARK: - DefaultMemoryFactClassifier tests

@Suite struct DefaultClassifierTests {

    private let classifier = DefaultMemoryFactClassifier()

    @Test func classifiesURLAsReference() {
        #expect(classifier.classify(text: "https://example.com/docs", context: nil) == .reference)
        #expect(classifier.classify(text: "http://localhost:8080/api", context: nil) == .reference)
        #expect(classifier.classify(text: "ftp://files.example.com/report.pdf", context: nil) == .reference)
    }

    @Test func classifiesAbsolutePathAsReference() {
        #expect(classifier.classify(text: "/usr/local/bin/swift", context: nil) == .reference)
        #expect(classifier.classify(text: "/etc/hosts contains our overrides", context: nil) == .reference)
    }

    @Test func classifiesTildePathAsReference() {
        #expect(classifier.classify(text: "Config lives at ~/Library/Application Support", context: nil) == .reference)
    }

    @Test func classifiesPreferenceKeywords() {
        #expect(classifier.classify(text: "Prefer async/await over completion handlers", context: nil) == .preference)
        #expect(classifier.classify(text: "Avoid force-unwrapping optionals", context: nil) == .preference)
        #expect(classifier.classify(text: "Use SwiftUI for new views", context: nil) == .preference)
        #expect(classifier.classify(text: "Don't commit secrets to the repo", context: nil) == .preference)
        #expect(classifier.classify(text: "Do not push to main directly", context: nil) == .preference)
        #expect(classifier.classify(text: "Tests should pass before merging", context: nil) == .preference)
    }

    @Test func classifiesHeuristicKeywords() {
        #expect(classifier.classify(text: "Always run lint before pushing", context: nil) == .heuristic)
        #expect(classifier.classify(text: "Never merge without a review", context: nil) == .heuristic)
        #expect(classifier.classify(text: "Every time a migration is added, update the schema", context: nil) == .heuristic)
        #expect(classifier.classify(text: "Each time CI fails, check the logs first", context: nil) == .heuristic)
        #expect(classifier.classify(text: "When tests fail, check environment variables", context: nil) == .heuristic)
    }

    @Test func classifiesGenericTextAsFact() {
        #expect(classifier.classify(text: "The staging DB is on port 5432", context: nil) == .fact)
        #expect(classifier.classify(text: "Release branch is named release/v2", context: nil) == .fact)
        #expect(classifier.classify(text: "Team has 4 engineers", context: nil) == .fact)
    }

    @Test func referenceWinsOverOtherMarkersWhenFirstLineStartsWithURL() {
        // The classifier matches URLs only when the first line STARTS with a URL scheme.
        // This test verifies the priority ordering (reference > preference > heuristic > fact):
        // a line that begins with a URL is classified as .reference even if it also contains
        // a preference-marker word like "should".
        let text = "https://status.example.com should be checked before deploying"
        #expect(classifier.classify(text: text, context: nil) == .reference)
    }

    @Test func midSentenceURLDoesNotTriggerReference() {
        // A URL embedded mid-sentence does not trigger the reference heuristic;
        // the classifier checks for a URL-prefix at the START of the first line only.
        // "always" (heuristic marker) is the winning rule here.
        let text = "Always check https://status.example.com before deploying"
        #expect(classifier.classify(text: text, context: nil) == .heuristic)
    }

    @Test func multilineTextUsesOnlyFirstLine() {
        // First line is a bare fact; second line has preference marker.
        let text = "Database host is db.acme.internal\nPrefer read replicas for analytics queries"
        #expect(classifier.classify(text: text, context: nil) == .fact)
    }

    @Test func contextParameterIsAccepted() {
        // DefaultMemoryFactClassifier ignores context but the protocol must accept it.
        let result = classifier.classify(text: "Team size is 6", context: "acme/webapp")
        #expect(result == .fact)
    }
}

// MARK: - MemoryArchivist tests

@Suite struct MemoryArchivistTests {

    // MARK: Basic record

    @Test func recordStoresClassifiedFact() async throws {
        let dir = try makeTempDir()
        defer { removeTempDir(dir) }

        let store = try MemoryStore(baseDirectory: dir)
        let archivist = MemoryArchivist(store: store)

        let provenance = makeProvenance()
        let recorded = try await archivist.record(
            text: "Always run swift test before merging",
            scopePath: "acme/webapp",
            provenance: provenance
        )

        // Classification: "always" → heuristic.
        #expect(recorded.type == .heuristic)
        #expect(recorded.text == "Always run swift test before merging")
        #expect(recorded.scopePath == "acme/webapp")

        // The fact is present in the store.
        let stored = await store.fact(id: recorded.id)
        #expect(stored != nil)
        #expect(stored?.type == .heuristic)
    }

    @Test func recordUsesInjectedClassifier() async throws {
        let dir = try makeTempDir()
        defer { removeTempDir(dir) }

        let store = try MemoryStore(baseDirectory: dir)
        // Force all text to be classified as .reference, regardless of content.
        let archivist = MemoryArchivist(store: store, classifier: FixedClassifier(type: .reference))

        let recorded = try await archivist.record(
            text: "Some ambiguous text",
            scopePath: "acme",
            provenance: makeProvenance()
        )

        #expect(recorded.type == .reference)
    }

    // MARK: Auto-supersede

    @Test func recordAutoSupersedesConflictingFactAtSameScope() async throws {
        let dir = try makeTempDir()
        defer { removeTempDir(dir) }

        let store = try MemoryStore(baseDirectory: dir)
        let archivist = MemoryArchivist(store: store, classifier: FixedClassifier(type: .preference))

        let provenance = makeProvenance()

        // Record the original fact.
        let original = try await archivist.record(
            text: "Prefer async/await over callbacks",
            scopePath: "acme/webapp",
            provenance: provenance
        )

        // Record a conflicting fact: same type (.preference from FixedClassifier),
        // same normalised first-line subject.
        let replacement = try await archivist.record(
            text: "Prefer async/await over callbacks",  // identical subject
            scopePath: "acme/webapp",
            provenance: provenance
        )

        // The new fact lists the old one in supersedes.
        #expect(replacement.supersedes.contains(original.id),
                "New fact must reference the superseded ID")

        // resolvedFacts for the scope must not contain the old fact.
        let resolved = await store.resolvedFacts(forScope: "acme/webapp")
        let ids = Set(resolved.map(\.id))
        #expect(!ids.contains(original.id), "Superseded fact must not appear in resolved set")
        #expect(ids.contains(replacement.id), "Replacement fact must appear in resolved set")
    }

    @Test func recordDoesNotSupersedeNonConflictingFactAtSameScope() async throws {
        let dir = try makeTempDir()
        defer { removeTempDir(dir) }

        let store = try MemoryStore(baseDirectory: dir)
        let archivist = MemoryArchivist(store: store, classifier: FixedClassifier(type: .preference))

        let provenance = makeProvenance()

        let factA = try await archivist.record(
            text: "Prefer async/await",
            scopePath: "acme/webapp",
            provenance: provenance
        )

        // Different subject → no conflict.
        let factB = try await archivist.record(
            text: "Prefer small commits",
            scopePath: "acme/webapp",
            provenance: provenance
        )

        // factB must NOT supersede factA.
        #expect(factB.supersedes.isEmpty, "Non-conflicting fact must not supersede anything")

        // Both facts live in the store.
        let all = await store.allFacts()
        let ids = Set(all.map(\.id))
        #expect(ids.contains(factA.id))
        #expect(ids.contains(factB.id))
    }

    @Test func recordDoesNotSupersedeFactAtDifferentScope() async throws {
        let dir = try makeTempDir()
        defer { removeTempDir(dir) }

        let store = try MemoryStore(baseDirectory: dir)
        let archivist = MemoryArchivist(store: store, classifier: FixedClassifier(type: .preference))

        let provenance = makeProvenance()

        // Same text, same type, but different scope.
        let rootFact = try await archivist.record(
            text: "Prefer async/await",
            scopePath: "acme",
            provenance: provenance
        )

        let childFact = try await archivist.record(
            text: "Prefer async/await",
            scopePath: "acme/webapp",  // different scope
            provenance: provenance
        )

        // Cross-scope override is a read-time concern; archivist must not touch rootFact.
        #expect(childFact.supersedes.isEmpty,
                "Fact at a different scope must not be auto-superseded by archivist")

        let storedRoot = await store.fact(id: rootFact.id)
        #expect(storedRoot != nil, "Root-scope fact must still exist unchanged")
    }

    @Test func recordMultipleConflictsAllSuperseded() async throws {
        let dir = try makeTempDir()
        defer { removeTempDir(dir) }

        // Manually add two conflicting facts to the store (bypassing the archivist)
        // so we can test the many-conflict path.
        let store = try MemoryStore(baseDirectory: dir)

        let t = Date(timeIntervalSince1970: 1_000_000)
        let prov = makeProvenance()
        let f1 = MemoryFact(
            id: "dup-1",
            text: "Always lint before commit",
            type: .heuristic,
            scopePath: "acme",
            provenance: prov,
            createdAt: t,
            updatedAt: t
        )
        let f2 = MemoryFact(
            id: "dup-2",
            text: "Always lint before commit",
            type: .heuristic,
            scopePath: "acme",
            provenance: prov,
            createdAt: t.addingTimeInterval(1),
            updatedAt: t.addingTimeInterval(1)
        )
        try await store.add(f1)
        try await store.add(f2)

        // Now record a third conflicting fact via the archivist.
        let archivist = MemoryArchivist(store: store, classifier: FixedClassifier(type: .heuristic))
        let winner = try await archivist.record(
            text: "Always lint before commit",
            scopePath: "acme",
            provenance: prov
        )

        // The winner must list both old facts as superseded.
        #expect(winner.supersedes.contains("dup-1"))
        #expect(winner.supersedes.contains("dup-2"))

        // resolvedFacts must contain only the winner.
        let resolved = await store.resolvedFacts(forScope: "acme")
        let resolvedIDs = Set(resolved.map(\.id))
        #expect(!resolvedIDs.contains("dup-1"))
        #expect(!resolvedIDs.contains("dup-2"))
        #expect(resolvedIDs.contains(winner.id))
    }

    @Test func recordPreBuiltFactStoresWithoutClassifying() async throws {
        let dir = try makeTempDir()
        defer { removeTempDir(dir) }

        let store = try MemoryStore(baseDirectory: dir)
        // Even with a classifier that forces .fact, a pre-built fact with .reference wins.
        let archivist = MemoryArchivist(store: store, classifier: FixedClassifier(type: .fact))

        let t = Date(timeIntervalSince1970: 2_000_000)
        let prov = makeProvenance()
        let preBuilt = MemoryFact(
            id: "pre-built-1",
            text: "https://docs.example.com/api",
            type: .reference,  // explicitly set
            scopePath: "acme",
            provenance: prov,
            createdAt: t,
            updatedAt: t
        )

        let stored = try await archivist.record(preBuilt)

        #expect(stored.type == .reference, "Pre-built fact type must be preserved")
        let retrieved = await store.fact(id: "pre-built-1")
        #expect(retrieved?.type == .reference)
    }

    // MARK: allFacts reflects supersession

    @Test func allFactsContainsBothLiveAndSupersededFacts() async throws {
        let dir = try makeTempDir()
        defer { removeTempDir(dir) }

        let store = try MemoryStore(baseDirectory: dir)
        let archivist = MemoryArchivist(store: store, classifier: FixedClassifier(type: .fact))

        let prov = makeProvenance()

        let original = try await archivist.record(
            text: "Database host is db.internal",
            scopePath: "acme",
            provenance: prov
        )

        let replacement = try await archivist.record(
            text: "Database host is db.internal",
            scopePath: "acme",
            provenance: prov
        )

        // allFacts contains both (history is preserved).
        let all = await store.allFacts()
        let ids = Set(all.map(\.id))
        #expect(ids.contains(original.id), "Superseded fact must still be in allFacts (history)")
        #expect(ids.contains(replacement.id))
        #expect(all.count == 2)
    }
}
