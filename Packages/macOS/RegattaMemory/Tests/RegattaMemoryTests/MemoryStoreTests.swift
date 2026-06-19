import Foundation
import Testing

@testable import RegattaMemory

// MARK: - Helpers

/// Returns a unique temporary directory for each test, automatically cleaned
/// up when the `defer` block in the calling test runs. Tests that need it
/// explicitly can keep the URL, but the pattern avoids shared-state between
/// parallel test runs.
private func makeTempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("RegattaMemoryTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func removeTempDir(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
}

/// A frozen clock that returns a fixed sequence of dates.
private final class Clock: @unchecked Sendable {
    private var dates: [Date]
    private var index = 0

    init(dates: [Date]) {
        self.dates = dates
    }

    func next() -> Date {
        let d = dates[min(index, dates.count - 1)]
        index += 1
        return d
    }

    var now: @Sendable () -> Date {
        { [weak self] in self?.next() ?? Date() }
    }
}

private func makeFact(
    id: String = UUID().uuidString,
    text: String = "sample fact",
    type: MemoryFactType = .fact,
    scopePath: String = "project/module",
    workerID: String? = nil,
    sourcePR: String? = nil,
    sourceDescription: String = "test",
    at date: Date = Date(timeIntervalSince1970: 1_000_000)
) -> MemoryFact {
    let provenance = MemoryProvenance(
        workerID: workerID,
        sourcePR: sourcePR,
        sourceDescription: sourceDescription,
        recordedAt: date
    )
    return MemoryFact(
        id: id,
        text: text,
        type: type,
        scopePath: scopePath,
        provenance: provenance,
        createdAt: date,
        updatedAt: date
    )
}

// MARK: - Persistence round-trip

@Suite struct PersistenceTests {
    @Test func persistenceRoundTrip() async throws {
        let dir = try makeTempDir()
        defer { removeTempDir(dir) }

        let date1 = Date(timeIntervalSince1970: 1_000_000)
        let date2 = Date(timeIntervalSince1970: 1_000_100)

        let fact1 = makeFact(
            id: "fact-1",
            text: "Always run tests before pushing",
            type: .heuristic,
            scopePath: "acme/webapp",
            workerID: "worker-42",
            sourcePR: "acme/webapp#7",
            sourceDescription: "loop iteration 2",
            at: date1
        )
        let fact2 = makeFact(
            id: "fact-2",
            text: "Prefer async/await over completion handlers",
            type: .preference,
            scopePath: "acme/webapp/billing",
            workerID: nil,
            sourcePR: nil,
            sourceDescription: "manual entry",
            at: date2
        )

        // Write via first store instance.
        let store1 = try MemoryStore(baseDirectory: dir)
        try await store1.add(fact1)
        try await store1.add(fact2)

        // Load via a brand-new store instance on the same directory.
        let store2 = try MemoryStore(baseDirectory: dir)
        let all = await store2.allFacts()

        #expect(all.count == 2)

        let loaded1 = try #require(await store2.fact(id: "fact-1"))
        #expect(loaded1.text == fact1.text)
        #expect(loaded1.type == .heuristic)
        #expect(loaded1.scopePath == "acme/webapp")
        #expect(loaded1.provenance.workerID == "worker-42")
        #expect(loaded1.provenance.sourcePR == "acme/webapp#7")
        #expect(loaded1.provenance.sourceDescription == "loop iteration 2")
        // Timestamps must survive a JSON encode/decode round-trip.
        // ISO 8601 encoding truncates to second precision, so compare with
        // a 1-second tolerance.
        #expect(abs(loaded1.createdAt.timeIntervalSince(date1)) < 1.0)
        #expect(abs(loaded1.updatedAt.timeIntervalSince(date1)) < 1.0)
        #expect(loaded1.supersedes.isEmpty)

        let loaded2 = try #require(await store2.fact(id: "fact-2"))
        #expect(loaded2.text == fact2.text)
        #expect(loaded2.type == .preference)
        #expect(loaded2.scopePath == "acme/webapp/billing")
        #expect(loaded2.provenance.workerID == nil)
        #expect(loaded2.provenance.sourcePR == nil)
        #expect(loaded2.provenance.sourceDescription == "manual entry")
        #expect(abs(loaded2.createdAt.timeIntervalSince(date2)) < 1.0)
    }
}

// MARK: - Scope queries

@Suite struct ScopeQueryTests {
    @Test func factsInScopeReturnsOnlyMatchingScope() async throws {
        let dir = try makeTempDir()
        defer { removeTempDir(dir) }

        let store = try MemoryStore(baseDirectory: dir)

        let root = makeFact(id: "r1", text: "root fact", scopePath: "")
        let top = makeFact(id: "a1", text: "top", scopePath: "acme")
        let webapp = makeFact(id: "w1", text: "webapp", scopePath: "acme/webapp")
        let billing = makeFact(id: "b1", text: "billing", scopePath: "acme/webapp/billing")
        let sibling = makeFact(id: "s1", text: "webapps sibling", scopePath: "acme/webapps")
        let other = makeFact(id: "o1", text: "other project", scopePath: "other/project")

        for f in [root, top, webapp, billing, sibling, other] {
            try await store.add(f)
        }

        // Exact match + descendant; sibling "acme/webapps" must NOT be included.
        let webappFacts = await store.facts(inScope: "acme/webapp")
        let ids = Set(webappFacts.map(\.id))
        #expect(ids == ["w1", "b1"])

        // Root scope returns everything.
        let allFromRoot = await store.facts(inScope: "")
        #expect(allFromRoot.count == 6)

        // A narrow scope returns only itself (no children).
        let billingFacts = await store.facts(inScope: "acme/webapp/billing")
        #expect(billingFacts.map(\.id) == ["b1"])

        // A scope with no match returns empty.
        let empty = await store.facts(inScope: "nonexistent")
        #expect(empty.isEmpty)
    }
}

// MARK: - Search

@Suite struct SearchTests {
    @Test func searchFindsBySubstringCaseInsensitive() async throws {
        let dir = try makeTempDir()
        defer { removeTempDir(dir) }

        let store = try MemoryStore(baseDirectory: dir)

        let f1 = makeFact(id: "s1", text: "Always run Tests before pushing", scopePath: "repo")
        let f2 = makeFact(id: "s2", text: "Prefer async/await over callbacks", scopePath: "repo")
        let f3 = makeFact(id: "s3", text: "Staging DB URL is postgres://...", scopePath: "repo/infra")

        for f in [f1, f2, f3] {
            try await store.add(f)
        }

        // Case-insensitive substring on "tests"
        let results = await store.search("tests")
        #expect(results.count == 1)
        #expect(results[0].id == "s1")

        // Case-insensitive match with mixed case in query
        let results2 = await store.search("ASYNC")
        #expect(results2.count == 1)
        #expect(results2[0].id == "s2")

        // No match
        let results3 = await store.search("GraphQL")
        #expect(results3.isEmpty)

        // Matches multiple facts
        let results4 = await store.search("postgres")
        #expect(results4.map(\.id) == ["s3"])
    }
}

// MARK: - Supersede

@Suite struct SupersedeTests {
    @Test func supersedeRecordsHistoryAndBothFactsAreRetrievable() async throws {
        let dir = try makeTempDir()
        defer { removeTempDir(dir) }

        let store = try MemoryStore(baseDirectory: dir)

        let original = makeFact(id: "old-1", text: "Use completion handlers", type: .preference)
        try await store.add(original)

        // Create a new fact that supersedes the original.
        var replacement = makeFact(id: "new-1", text: "Prefer async/await over completion handlers", type: .preference)
        replacement.supersedes = []  // will be set by supersede()
        try await store.supersede(oldID: "old-1", with: replacement)

        // Both facts remain retrievable.
        let oldFact = try #require(await store.fact(id: "old-1"))
        #expect(oldFact.text == "Use completion handlers")

        let newFact = try #require(await store.fact(id: "new-1"))
        #expect(newFact.text == "Prefer async/await over completion handlers")

        // The new fact records the supersedes history.
        #expect(newFact.supersedes.contains("old-1"))

        // All facts returns both.
        let all = await store.allFacts()
        #expect(all.count == 2)
    }

    @Test func supersedeFailsWhenOldIDDoesNotExist() async throws {
        let dir = try makeTempDir()
        defer { removeTempDir(dir) }

        let store = try MemoryStore(baseDirectory: dir)
        let newFact = makeFact(id: "new-1", text: "replacement")

        do {
            try await store.supersede(oldID: "nonexistent", with: newFact)
            Issue.record("Expected supersede to throw but it did not")
        } catch is MemoryStoreError {
            // expected
        }
    }

    @Test func supersedeChainPreservesFullHistory() async throws {
        let dir = try makeTempDir()
        defer { removeTempDir(dir) }

        let store = try MemoryStore(baseDirectory: dir)

        let v1 = makeFact(id: "v1", text: "version one")
        let v2 = makeFact(id: "v2", text: "version two")
        let v3 = makeFact(id: "v3", text: "version three")

        try await store.add(v1)
        try await store.supersede(oldID: "v1", with: v2)
        try await store.supersede(oldID: "v2", with: v3)

        // All three are retrievable.
        #expect(await store.fact(id: "v1") != nil)
        #expect(await store.fact(id: "v2") != nil)
        #expect(await store.fact(id: "v3") != nil)

        let final3 = try #require(await store.fact(id: "v3"))
        #expect(final3.supersedes.contains("v2"))
    }
}

// MARK: - On-disk format

@Suite struct OnDiskFormatTests {
    @Test func onDiskFileIsVersionedPrettyJSON() async throws {
        let dir = try makeTempDir()
        defer { removeTempDir(dir) }

        let store = try MemoryStore(baseDirectory: dir)
        let fact = makeFact(id: "format-test", text: "check disk format")
        try await store.add(fact)

        // Read the raw file and parse it independently.
        let fileURL = dir.appendingPathComponent("memory-facts.json")
        let data = try Data(contentsOf: fileURL)

        // Must be valid JSON parseable as a top-level object.
        let json = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        // version must be 1.
        let version = try #require(json["version"] as? Int)
        #expect(version == 1)

        // facts array must be present and non-empty.
        let factsArray = try #require(json["facts"] as? [[String: Any]])
        #expect(factsArray.count == 1)
        #expect(factsArray[0]["id"] as? String == "format-test")

        // The file must be pretty-printed (contains newlines).
        let rawString = String(decoding: data, as: UTF8.self)
        #expect(rawString.contains("\n"))
    }
}

// MARK: - Update

@Suite struct UpdateTests {
    @Test func updateReplacesExistingFact() async throws {
        let dir = try makeTempDir()
        defer { removeTempDir(dir) }

        let store = try MemoryStore(baseDirectory: dir)
        var fact = makeFact(id: "upd-1", text: "original text")
        try await store.add(fact)

        fact.text = "updated text"
        try await store.update(fact)

        let loaded = try #require(await store.fact(id: "upd-1"))
        #expect(loaded.text == "updated text")
    }

    @Test func updateFailsWhenIDDoesNotExist() async throws {
        let dir = try makeTempDir()
        defer { removeTempDir(dir) }

        let store = try MemoryStore(baseDirectory: dir)
        let fact = makeFact(id: "missing-id", text: "nope")

        do {
            try await store.update(fact)
            Issue.record("Expected update to throw but it did not")
        } catch is MemoryStoreError {
            // expected
        }
    }
}

// MARK: - Duplicate ID guard

@Suite struct DuplicateIDTests {
    @Test func addFailsOnDuplicateID() async throws {
        let dir = try makeTempDir()
        defer { removeTempDir(dir) }

        let store = try MemoryStore(baseDirectory: dir)
        let fact = makeFact(id: "dup-1", text: "first")
        try await store.add(fact)

        let dupe = makeFact(id: "dup-1", text: "second (duplicate)")
        do {
            try await store.add(dupe)
            Issue.record("Expected add to throw on duplicate ID but it did not")
        } catch is MemoryStoreError {
            // expected
        }
    }
}
