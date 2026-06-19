import Foundation
import Testing

@testable import RegattaMemory

// MARK: - Helpers (local to this file)

private func makeTempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("RegattaHierarchyTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func removeTempDir(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
}

/// Builds a ``MemoryFact`` with the given required fields; all other fields get
/// safe defaults so each call site only specifies what matters for the test.
private func makeFact(
    id: String,
    text: String,
    type: MemoryFactType = .fact,
    scopePath: String,
    at offset: TimeInterval = 0
) -> MemoryFact {
    let date = Date(timeIntervalSince1970: 1_000_000 + offset)
    return MemoryFact(
        id: id,
        text: text,
        type: type,
        scopePath: scopePath,
        provenance: MemoryProvenance(
            sourceDescription: "hierarchy-test",
            recordedAt: date
        ),
        createdAt: date,
        updatedAt: date
    )
}

// MARK: - MemoryScope unit tests

@Suite struct MemoryScopeTests {

    // MARK: Ancestors

    @Test func rootScopeAncestorsReturnsSelf() {
        let root = MemoryScope(path: "")
        let chain = root.ancestors()
        #expect(chain.count == 1)
        #expect(chain[0].path == "")
    }

    @Test func singleSegmentAncestors() {
        let scope = MemoryScope(path: "acme")
        let chain = scope.ancestors()
        // Should be: ["", "acme"]
        #expect(chain.count == 2)
        #expect(chain[0].path == "")
        #expect(chain[1].path == "acme")
    }

    @Test func deepScopeAncestorChain() {
        let scope = MemoryScope(path: "acme/webapp/billing")
        let chain = scope.ancestors()
        // Should be: ["", "acme", "acme/webapp", "acme/webapp/billing"]
        #expect(chain.count == 4)
        #expect(chain[0].path == "")
        #expect(chain[1].path == "acme")
        #expect(chain[2].path == "acme/webapp")
        #expect(chain[3].path == "acme/webapp/billing")
    }

    @Test func ancestorChainIsRootToSelf() {
        // Verify the general contract: first element is root, last is self.
        let paths = ["a/b/c/d", "x", "x/y"]
        for rawPath in paths {
            let scope = MemoryScope(path: rawPath)
            let chain = scope.ancestors()
            #expect(chain.first?.path == "")
            #expect(chain.last?.path == scope.path)
        }
    }

    // MARK: depth

    @Test func depthIsCorrect() {
        #expect(MemoryScope(path: "").depth == 0)
        #expect(MemoryScope(path: "acme").depth == 0)
        #expect(MemoryScope(path: "acme/webapp").depth == 1)
        #expect(MemoryScope(path: "acme/webapp/billing").depth == 2)
        #expect(MemoryScope(path: "a/b/c/d").depth == 3)
    }

    // MARK: isAncestor(of:)

    @Test func rootIsAncestorOfEveryNonRootScope() {
        let root = MemoryScope(path: "")
        let other = MemoryScope(path: "acme/webapp")
        #expect(root.isAncestor(of: other))
    }

    @Test func rootIsNotAncestorOfItself() {
        let root = MemoryScope(path: "")
        #expect(!root.isAncestor(of: root))
    }

    @Test func scopeIsNotAncestorOfItself() {
        let scope = MemoryScope(path: "acme/webapp")
        #expect(!scope.isAncestor(of: scope))
    }

    @Test func parentIsAncestorOfChild() {
        let parent = MemoryScope(path: "acme")
        let child = MemoryScope(path: "acme/webapp")
        #expect(parent.isAncestor(of: child))
    }

    @Test func siblingIsNotAncestorOfSibling() {
        // "acme/webapps" must NOT be an ancestor of "acme/webapp"
        let sibling = MemoryScope(path: "acme/webapps")
        let other = MemoryScope(path: "acme/webapp")
        #expect(!sibling.isAncestor(of: other))
        #expect(!other.isAncestor(of: sibling))
    }

    @Test func childIsNotAncestorOfParent() {
        let parent = MemoryScope(path: "acme")
        let child = MemoryScope(path: "acme/webapp")
        #expect(!child.isAncestor(of: parent))
    }

    // MARK: Normalisation

    @Test func pathNormalisationStripsEmptySegments() {
        // Leading/trailing slashes and doubled slashes collapse.
        let scope = MemoryScope(path: "/acme//webapp/")
        #expect(scope.path == "acme/webapp")
    }

    @Test func emptyPathIsRoot() {
        #expect(MemoryScope(path: "").path == "")
        #expect(MemoryScope(path: "/").path == "")
    }
}

// MARK: - resolvedFacts integration tests

@Suite struct ResolvedFactsTests {

    /// Root-scope facts appear in resolved results for ALL scopes.
    @Test func rootFactsApplyEverywhere() async throws {
        let dir = try makeTempDir()
        defer { removeTempDir(dir) }

        let store = try MemoryStore(baseDirectory: dir)

        let rootFact = makeFact(id: "root-1", text: "global rule", scopePath: "")
        let deepFact = makeFact(id: "deep-1", text: "billing rule", scopePath: "acme/webapp/billing")

        try await store.add(rootFact)
        try await store.add(deepFact)

        // A deep scope inherits the root fact.
        let resolved = await store.resolvedFacts(forScope: "acme/webapp/billing")
        let ids = Set(resolved.map(\.id))
        #expect(ids.contains("root-1"), "Root fact must apply at a deep scope")
        #expect(ids.contains("deep-1"), "Own fact must be present")
    }

    /// An intermediate ancestor's facts also appear in the resolved set.
    @Test func ancestorFactsAreInherited() async throws {
        let dir = try makeTempDir()
        defer { removeTempDir(dir) }

        let store = try MemoryStore(baseDirectory: dir)

        let rootFact   = makeFact(id: "r1", text: "root rule",    scopePath: "",                    at: 0)
        let acmeFact   = makeFact(id: "a1", text: "acme rule",    scopePath: "acme",                at: 1)
        let webFact    = makeFact(id: "w1", text: "webapp rule",  scopePath: "acme/webapp",         at: 2)
        let billFact   = makeFact(id: "b1", text: "billing rule", scopePath: "acme/webapp/billing", at: 3)

        for f in [rootFact, acmeFact, webFact, billFact] {
            try await store.add(f)
        }

        let resolved = await store.resolvedFacts(forScope: "acme/webapp/billing")
        let ids = Set(resolved.map(\.id))
        #expect(ids == ["r1", "a1", "w1", "b1"], "All ancestor facts plus own fact must be present")
    }

    /// A sibling scope's facts must NOT be included.
    @Test func siblingFactsAreExcluded() async throws {
        let dir = try makeTempDir()
        defer { removeTempDir(dir) }

        let store = try MemoryStore(baseDirectory: dir)

        let target  = makeFact(id: "t1", text: "target",       scopePath: "acme/webapp",    at: 0)
        let sibling = makeFact(id: "s1", text: "sibling",      scopePath: "acme/webapps",   at: 1)
        let cousin  = makeFact(id: "c1", text: "other branch", scopePath: "other/project",  at: 2)

        for f in [target, sibling, cousin] {
            try await store.add(f)
        }

        let resolved = await store.resolvedFacts(forScope: "acme/webapp")
        let ids = Set(resolved.map(\.id))
        #expect(ids == ["t1"], "Only the target scope's own facts should appear (no siblings)")
        #expect(!ids.contains("s1"), "Sibling 'acme/webapps' must not appear for 'acme/webapp'")
        #expect(!ids.contains("c1"), "Unrelated scope must not appear")
    }

    /// Facts at a deeper scope should NOT appear when resolving a shallower scope.
    @Test func descendantFactsAreNotInherited() async throws {
        let dir = try makeTempDir()
        defer { removeTempDir(dir) }

        let store = try MemoryStore(baseDirectory: dir)

        let parent = makeFact(id: "p1", text: "parent fact", scopePath: "acme/webapp",         at: 0)
        let child  = makeFact(id: "c1", text: "child fact",  scopePath: "acme/webapp/billing", at: 1)

        try await store.add(parent)
        try await store.add(child)

        // Resolving the parent scope should NOT include the child.
        let resolved = await store.resolvedFacts(forScope: "acme/webapp")
        let ids = Set(resolved.map(\.id))
        #expect(ids == ["p1"])
        #expect(!ids.contains("c1"), "Descendant facts must not appear when resolving a parent scope")
    }

    // MARK: - Override / conflict rule

    /// A nearer-scope fact overrides an ancestor fact with the same type + subject.
    @Test func nearerScopeFactOverridesAncestor() async throws {
        let dir = try makeTempDir()
        defer { removeTempDir(dir) }

        let store = try MemoryStore(baseDirectory: dir)

        // Same type and same first-line subject → conflict.
        let ancestor = makeFact(
            id: "anc-1",
            text: "prefer async/await",
            type: .preference,
            scopePath: "acme",
            at: 0
        )
        let nearer = makeFact(
            id: "near-1",
            text: "prefer async/await",   // identical subject — intentional override
            type: .preference,
            scopePath: "acme/webapp/billing",
            at: 1
        )

        try await store.add(ancestor)
        try await store.add(nearer)

        let resolved = await store.resolvedFacts(forScope: "acme/webapp/billing")
        let ids = Set(resolved.map(\.id))

        // The nearer fact wins; the ancestor fact is excluded.
        #expect(ids.contains("near-1"), "Nearer-scope fact must be in resolved set")
        #expect(!ids.contains("anc-1"), "Ancestor fact must be overridden (excluded) when nearer scope has same type+subject")
    }

    /// Facts of different types with the same text do NOT conflict.
    @Test func differentTypesDontConflict() async throws {
        let dir = try makeTempDir()
        defer { removeTempDir(dir) }

        let store = try MemoryStore(baseDirectory: dir)

        // Same first-line text but different types → NOT a conflict; both survive.
        let heuristic = makeFact(
            id: "h1",
            text: "run tests before pushing",
            type: .heuristic,
            scopePath: "acme",
            at: 0
        )
        let fact = makeFact(
            id: "f1",
            text: "run tests before pushing",
            type: .fact,
            scopePath: "acme/webapp",
            at: 1
        )

        try await store.add(heuristic)
        try await store.add(fact)

        let resolved = await store.resolvedFacts(forScope: "acme/webapp")
        let ids = Set(resolved.map(\.id))
        #expect(ids.contains("h1"), "Heuristic and fact with same text but different types must both appear")
        #expect(ids.contains("f1"))
    }

    /// Superseded facts are excluded from the resolved set.
    @Test func supersededFactsAreExcluded() async throws {
        let dir = try makeTempDir()
        defer { removeTempDir(dir) }

        let store = try MemoryStore(baseDirectory: dir)

        let original = makeFact(id: "old-1", text: "old rule", type: .preference, scopePath: "acme", at: 0)
        let replacement = makeFact(id: "new-1", text: "new rule", type: .preference, scopePath: "acme", at: 1)

        try await store.add(original)
        try await store.supersede(oldID: "old-1", with: replacement)

        let resolved = await store.resolvedFacts(forScope: "acme/webapp")
        let ids = Set(resolved.map(\.id))
        #expect(!ids.contains("old-1"), "Superseded fact must not appear in resolved set")
        #expect(ids.contains("new-1"), "Replacement fact must appear in resolved set")
    }

    // MARK: - Ordering

    /// Results are ordered ancestor→nearest, oldest-first within a scope level.
    @Test func resolvedOrderIsAncestorToNearest() async throws {
        let dir = try makeTempDir()
        defer { removeTempDir(dir) }

        let store = try MemoryStore(baseDirectory: dir)

        let rootFact = makeFact(id: "r1", text: "root",    scopePath: "",                    at: 0)
        let acmeFact = makeFact(id: "a1", text: "acme",    scopePath: "acme",                at: 1)
        let webFact  = makeFact(id: "w1", text: "webapp",  scopePath: "acme/webapp",         at: 2)

        // Insert in reverse order to verify sort is not insertion-order.
        for f in [webFact, acmeFact, rootFact] {
            try await store.add(f)
        }

        let resolved = await store.resolvedFacts(forScope: "acme/webapp")
        let ids = resolved.map(\.id)

        // Root comes before acme, acme before webapp.
        let rootIdx = try #require(ids.firstIndex(of: "r1"))
        let acmeIdx = try #require(ids.firstIndex(of: "a1"))
        let webIdx  = try #require(ids.firstIndex(of: "w1"))
        #expect(rootIdx < acmeIdx, "Root fact must precede acme fact")
        #expect(acmeIdx < webIdx, "Acme fact must precede webapp fact")
    }

    // MARK: - Root-scope resolution

    /// Resolving the root scope returns ONLY root-scope facts (no descendants).
    @Test func resolvingRootReturnsOnlyRootFacts() async throws {
        let dir = try makeTempDir()
        defer { removeTempDir(dir) }

        let store = try MemoryStore(baseDirectory: dir)

        let rootFact  = makeFact(id: "r1", text: "root fact",  scopePath: "")
        let childFact = makeFact(id: "c1", text: "child fact", scopePath: "acme")

        try await store.add(rootFact)
        try await store.add(childFact)

        let resolved = await store.resolvedFacts(forScope: "")
        let ids = Set(resolved.map(\.id))
        #expect(ids == ["r1"])
        #expect(!ids.contains("c1"), "Child-scope fact must not appear when resolving root")
    }

    // MARK: - Empty store

    @Test func emptyStoreReturnsEmptyResolved() async throws {
        let dir = try makeTempDir()
        defer { removeTempDir(dir) }

        let store = try MemoryStore(baseDirectory: dir)
        let resolved = await store.resolvedFacts(forScope: "acme/webapp/billing")
        #expect(resolved.isEmpty)
    }
}
