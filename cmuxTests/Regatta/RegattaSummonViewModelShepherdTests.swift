import Foundation
import Testing
import RegattaCore
import RegattaFleet
import RegattaGitHub

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Tests for ``RegattaSummonViewModel``'s shepherd projection — the Open Fleet
/// Grid now shows handed-off PR shepherds alongside ephemeral workers, driven by
/// the *same* ``Fleet`` snapshots the rail uses.
///
/// These drive a real ``Fleet`` (with `autoStart: false`, so watchers never poll)
/// plus a no-op orchestrator, asserting that:
/// - handed-off PRs surface in ``RegattaSummonViewModel/shepherds``,
/// - ``RegattaSummonViewModel/dismissShepherd(_:)`` routes to the Fleet's shared
///   dismiss path so the shepherd disappears, and
/// - the projection is empty before any handoff (the empty-state case).
@Suite("RegattaSummonViewModel shepherd projection")
@MainActor
struct RegattaSummonViewModelShepherdTests {

    // MARK: - Fixtures

    /// A deterministic poller that never spawns a process or hits the network.
    /// Watchers built from it never poll because the Fleet uses `autoStart: false`.
    private struct NoopPoller: PullRequestPolling {
        func fetchChecks(owner: String, repo: String, prNumber: Int) async throws -> [PRCheck] { [] }
        func fetchReviewThreads(owner: String, repo: String, prNumber: Int) async throws -> [ReviewThread] { [] }
    }

    private func ref(_ number: Int = 1) -> PullRequestRef {
        PullRequestRef(owner: "joshbermanssw", repo: "regatta", number: number)
    }

    /// A Fleet whose watchers never auto-start, so tests are timing-independent.
    private func makeFleet() -> Fleet {
        let poller = NoopPoller()
        return Fleet(autoStart: false) { ref in
            ShepherdWatcher(pullRequest: ref, poller: poller)
        }
    }

    /// A real orchestrator with no live agents; only its empty `updates()` stream
    /// is observed, so the worker grid stays at just the spawn tile.
    private func makeOrchestrator() -> RegattaOrchestrator {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("regatta-shepgrid-\(UUID().uuidString)", isDirectory: true)
        return RegattaOrchestrator(
            worktreeManager: RegattaWorktreeManager(baseDirectory: base),
            paneBridge: UnavailablePaneBridge()
        )
    }

    private func makeViewModel(fleet: Fleet) -> RegattaSummonViewModel {
        RegattaSummonViewModel(
            orchestrator: makeOrchestrator(),
            fleet: fleet,
            spawnSpecProvider: { RegattaSummonViewModel.defaultSpawnSpec() },
            toasts: RegattaToastCenter()
        )
    }

    /// Spins the main runloop until `predicate` holds or a bounded number of
    /// iterations elapses, letting the VM's observation `Task`s deliver snapshots.
    private func waitUntil(_ predicate: () -> Bool) async {
        for _ in 0..<200 {
            if predicate() { return }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    // MARK: - Tests

    @Test("shepherds is empty before any handoff")
    func emptyBeforeHandoff() async {
        let fleet = makeFleet()
        let vm = makeViewModel(fleet: fleet)
        vm.startObserving()
        // Allow the initial (empty) snapshot to arrive.
        await waitUntil { vm.shepherds.isEmpty }
        #expect(vm.shepherds.isEmpty)
        vm.stopObserving()
    }

    @Test("a handed-off PR appears in the overlay's shepherds projection")
    func handoffSurfacesShepherd() async {
        let fleet = makeFleet()
        let vm = makeViewModel(fleet: fleet)
        vm.startObserving()

        await fleet.handoff(ref(42))

        await waitUntil { vm.shepherds.contains { $0.pullRequest == self.ref(42) } }
        #expect(vm.shepherds.map(\.pullRequest) == [ref(42)])
        #expect(vm.shepherds.first?.kind == .shepherd)
        vm.stopObserving()
    }

    @Test("multiple handed-off PRs all appear in the projection")
    func multipleShepherds() async {
        let fleet = makeFleet()
        let vm = makeViewModel(fleet: fleet)
        vm.startObserving()

        await fleet.handoff(ref(1))
        await fleet.handoff(ref(2))

        await waitUntil { vm.shepherds.count == 2 }
        #expect(Set(vm.shepherds.map(\.pullRequest)) == [ref(1), ref(2)])
        vm.stopObserving()
    }

    @Test("dismissShepherd routes to the Fleet and removes the shepherd")
    func dismissRoutesToFleet() async {
        let fleet = makeFleet()
        let vm = makeViewModel(fleet: fleet)
        vm.startObserving()

        await fleet.handoff(ref(7))
        await waitUntil { vm.shepherds.contains { $0.pullRequest == self.ref(7) } }
        #expect(await fleet.contains(ref(7)) == true)

        vm.dismissShepherd(ref(7))

        // The dismiss intent runs on a Task; the Fleet then emits a snapshot that
        // clears the projection. Both the actor state and the projection update.
        await waitUntil { vm.shepherds.isEmpty }
        #expect(vm.shepherds.isEmpty)
        #expect(await fleet.contains(ref(7)) == false)
        vm.stopObserving()
    }
}
