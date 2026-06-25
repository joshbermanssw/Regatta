import Testing
import Foundation
import RegattaGitHub
@testable import RegattaFleet

@Suite("ShepherdWorkerRegistry — shepherd→worker ownership for dismiss cascade")
struct ShepherdWorkerRegistryTests {
    private let pr = PullRequestRef(owner: "manaflow-ai", repo: "cmux", number: 30)
    private let other = PullRequestRef(owner: "manaflow-ai", repo: "cmux", number: 31)

    @Test("records and returns the workers a shepherd owns")
    func recordsOwnership() async {
        let registry = ShepherdWorkerRegistry()
        let a = UUID()
        let b = UUID()
        await registry.record(a, for: pr)
        await registry.record(b, for: pr)

        let ids = Set(await registry.workerIDs(for: pr))
        #expect(ids == [a, b])
    }

    @Test("ownership is isolated per PR")
    func isolatedPerPR() async {
        let registry = ShepherdWorkerRegistry()
        let a = UUID()
        let b = UUID()
        await registry.record(a, for: pr)
        await registry.record(b, for: other)

        #expect(await registry.workerIDs(for: pr) == [a])
        #expect(await registry.workerIDs(for: other) == [b])
    }

    @Test("clearing a terminated worker drops it from the owned set")
    func clearDropsWorker() async {
        let registry = ShepherdWorkerRegistry()
        let a = UUID()
        await registry.record(a, for: pr)
        await registry.clear(a, for: pr)

        #expect(await registry.workerIDs(for: pr).isEmpty)
    }

    @Test("removeAll drops every owned worker for a PR (after dismiss)")
    func removeAllClearsPR() async {
        let registry = ShepherdWorkerRegistry()
        await registry.record(UUID(), for: pr)
        await registry.record(UUID(), for: pr)
        await registry.removeAll(for: pr)

        #expect(await registry.workerIDs(for: pr).isEmpty)
    }

    // MARK: - Reverse lookup (worker → PR), for the Fleet ✕ cancel path (I1)

    @Test("maps a worker id back to the PR that owns it")
    func reverseLookupFindsOwner() async {
        let registry = ShepherdWorkerRegistry()
        let a = UUID()
        let b = UUID()
        await registry.record(a, for: pr)
        await registry.record(b, for: other)

        #expect(await registry.pullRequest(for: a) == pr)
        #expect(await registry.pullRequest(for: b) == other)
    }

    @Test("reverse lookup returns nil for an unknown worker")
    func reverseLookupUnknownIsNil() async {
        let registry = ShepherdWorkerRegistry()
        #expect(await registry.pullRequest(for: UUID()) == nil)
    }

    @Test("reverse lookup stops resolving a worker once it is cleared")
    func reverseLookupAfterClear() async {
        let registry = ShepherdWorkerRegistry()
        let a = UUID()
        await registry.record(a, for: pr)
        await registry.clear(a, for: pr)
        #expect(await registry.pullRequest(for: a) == nil)
    }
}
