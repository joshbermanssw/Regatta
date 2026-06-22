import Foundation
import Testing
import RegattaCore

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Tests for ``RegattaSpawnFormViewModel``: the app-side adapter behind the Fleet
/// spawn form. Verifies the default repo comes from the active-tab context, the
/// required-prompt gating, the git-repo validation decision (and its inline error),
/// and the ``WorkerSpec`` built from the inputs — all headless via an injected
/// probe and spawn closure (no real orchestrator).
@MainActor
@Suite("RegattaSpawnFormViewModel")
struct RegattaSpawnFormViewModelTests {

    // MARK: - Fakes

    private struct StubProbe: RegattaGitRepositoryProbe {
        let gitPaths: Set<String>
        func isGitRepository(at url: URL) -> Bool { gitPaths.contains(url.path) }
    }

    /// A toast center with auto-dismiss disabled so the queue is asserted synchronously.
    private func makeToasts() -> RegattaToastCenter {
        RegattaToastCenter(autoDismissEnabled: false)
    }

    // MARK: - Default repo from context

    @Test("defaults the repo to the active tab's directory")
    func defaultsRepoFromContext() {
        let vm = RegattaSpawnFormViewModel(
            contextDirectory: "/Users/dev/project",
            probe: StubProbe(gitPaths: []),
            toasts: makeToasts(),
            spawn: { _ in }
        )
        #expect(vm.form.repoPath == "/Users/dev/project")
        #expect(vm.form.prompt.isEmpty)
        #expect(vm.form.providerID == .claudeCode)
    }

    @Test("falls back to a sensible path (not /) when no context")
    func defaultsRepoWithoutContext() {
        let vm = RegattaSpawnFormViewModel(
            contextDirectory: nil,
            probe: StubProbe(gitPaths: []),
            toasts: makeToasts(),
            spawn: { _ in }
        )
        #expect(vm.form.repoPath != "/")
        #expect(!vm.form.repoPath.isEmpty)
    }

    // MARK: - Gating

    @Test("canSpawn tracks the prompt")
    func gatingTracksPrompt() {
        let vm = RegattaSpawnFormViewModel(
            contextDirectory: "/repo",
            probe: StubProbe(gitPaths: ["/repo"]),
            toasts: makeToasts(),
            spawn: { _ in }
        )
        #expect(vm.canSpawn == false)
        vm.form.prompt = "Fix the bug"
        #expect(vm.canSpawn == true)
    }

    // MARK: - Validation + spawn

    @Test("spawnWorker builds a spec and spawns for a valid git repo")
    func spawnSucceedsForGitRepo() {
        var spawned: [WorkerSpec] = []
        let toasts = makeToasts()
        let vm = RegattaSpawnFormViewModel(
            contextDirectory: "/repo",
            probe: StubProbe(gitPaths: ["/repo"]),
            toasts: toasts,
            spawn: { spawned.append($0) }
        )
        vm.form.prompt = "Investigate the 500"
        vm.form.providerID = .codex

        let didSpawn = vm.spawnWorker()

        #expect(didSpawn == true)
        #expect(spawned.count == 1)
        #expect(spawned.first?.prompt == "Investigate the 500")
        #expect(spawned.first?.repoURL.path == "/repo")
        #expect(spawned.first?.providerID == .codex)
        #expect(vm.validationError == nil)
        // A success toast is emitted naming the worker.
        #expect(toasts.toasts.contains { $0.kind == .success })
    }

    @Test("spawnWorker rejects a non-git path with an inline error and no spawn")
    func spawnFailsForNonRepo() {
        var spawned: [WorkerSpec] = []
        let toasts = makeToasts()
        let vm = RegattaSpawnFormViewModel(
            contextDirectory: "/not-a-repo",
            probe: StubProbe(gitPaths: []),
            toasts: toasts,
            spawn: { spawned.append($0) }
        )
        vm.form.prompt = "Do a thing"

        let didSpawn = vm.spawnWorker()

        #expect(didSpawn == false)
        #expect(spawned.isEmpty, "no worker should spawn for an invalid repo")
        #expect(vm.validationError != nil, "an inline validation error should be set")
        #expect(toasts.toasts.contains { $0.kind == .error })
    }

    @Test("editing the repo path clears a stale validation error")
    func editingClearsValidationError() {
        let vm = RegattaSpawnFormViewModel(
            contextDirectory: "/not-a-repo",
            probe: StubProbe(gitPaths: []),
            toasts: makeToasts(),
            spawn: { _ in }
        )
        vm.form.prompt = "Task"
        _ = vm.spawnWorker()
        #expect(vm.validationError != nil)

        vm.clearValidationError()
        #expect(vm.validationError == nil)
    }

    @Test("offers all three providers in the picker")
    func offersAllProviders() {
        let vm = RegattaSpawnFormViewModel(
            contextDirectory: "/repo",
            probe: StubProbe(gitPaths: ["/repo"]),
            toasts: makeToasts(),
            spawn: { _ in }
        )
        #expect(vm.providers == [.claudeCode, .codex, .gemini])
    }
}
