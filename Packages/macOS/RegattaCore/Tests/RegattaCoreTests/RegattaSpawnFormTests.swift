import Foundation
import Testing
@testable import RegattaCore

/// Unit tests for ``RegattaSpawnForm``: the pure decision logic behind the Fleet
/// "Spawn worker" form — default repo from the active-tab context, required-prompt
/// gating, git-repo validation, and the built ``WorkerSpec``.
@Suite("RegattaSpawnForm")
struct RegattaSpawnFormTests {

    // MARK: - Fakes

    /// A probe that answers `isGitRepository` from a fixed set of allowed paths.
    private struct StubProbe: RegattaGitRepositoryProbe {
        let gitPaths: Set<String>
        func isGitRepository(at url: URL) -> Bool {
            gitPaths.contains(url.path)
        }
    }

    // MARK: - Default repo from context

    @Test("defaults the repo to the active tab's directory when present")
    func defaultsRepoFromContext() {
        let form = RegattaSpawnForm.makeDefault(
            contextDirectory: "/Users/dev/project",
            fallbackPath: "/Users/dev"
        )
        #expect(form.repoPath == "/Users/dev/project")
        #expect(form.prompt.isEmpty)
        #expect(form.providerID == .claudeCode)
    }

    @Test("falls back to the home/fallback path when context is nil")
    func defaultsRepoFromFallbackWhenNil() {
        let form = RegattaSpawnForm.makeDefault(
            contextDirectory: nil,
            fallbackPath: "/Users/dev"
        )
        #expect(form.repoPath == "/Users/dev")
    }

    @Test("falls back when the context directory is blank")
    func defaultsRepoFromFallbackWhenBlank() {
        let form = RegattaSpawnForm.makeDefault(
            contextDirectory: "   ",
            fallbackPath: "/Users/dev"
        )
        #expect(form.repoPath == "/Users/dev")
    }

    @Test("never defaults the repo to the launched-app root")
    func defaultDoesNotUseRootPlaceholder() {
        // The old placeholder spawned in "/" (the launched app's cwd). A nil
        // context must fall back to the fallback path, not "/".
        let form = RegattaSpawnForm.makeDefault(
            contextDirectory: nil,
            fallbackPath: "/Users/dev"
        )
        #expect(form.repoPath != "/")
    }

    // MARK: - Required-prompt gating

    @Test("canSpawn is false until the prompt is non-empty")
    func gatingRequiresPrompt() {
        var form = RegattaSpawnForm(repoPath: "/repo", prompt: "", providerID: .claudeCode)
        #expect(form.canSpawn == false)

        form.prompt = "   \n  "
        #expect(form.canSpawn == false, "whitespace-only prompt should not enable spawn")

        form.prompt = "Fix the bug"
        #expect(form.canSpawn == true)
    }

    @Test("canSpawn is false when the repo path is blank")
    func gatingRequiresRepoPath() {
        let form = RegattaSpawnForm(repoPath: "  ", prompt: "Do a thing", providerID: .claudeCode)
        #expect(form.canSpawn == false)
    }

    // MARK: - Git-repo validation

    @Test("validatedRepoURL succeeds for a git repo")
    func validationSucceedsForGitRepo() throws {
        let probe = StubProbe(gitPaths: ["/repo"])
        let form = RegattaSpawnForm(repoPath: "/repo", prompt: "Task", providerID: .claudeCode)
        let url = try form.validatedRepoURL(using: probe)
        #expect(url.path == "/repo")
    }

    @Test("validatedRepoURL throws notAGitRepository for a non-repo path")
    func validationThrowsForNonRepo() {
        let probe = StubProbe(gitPaths: [])
        let form = RegattaSpawnForm(repoPath: "/not-a-repo", prompt: "Task", providerID: .claudeCode)
        #expect(throws: RegattaSpawnFormError.notAGitRepository(path: "/not-a-repo")) {
            _ = try form.validatedRepoURL(using: probe)
        }
    }

    @Test("validatedRepoURL throws emptyPrompt before probing")
    func validationThrowsForEmptyPrompt() {
        let probe = StubProbe(gitPaths: ["/repo"])
        let form = RegattaSpawnForm(repoPath: "/repo", prompt: "  ", providerID: .claudeCode)
        #expect(throws: RegattaSpawnFormError.emptyPrompt) {
            _ = try form.validatedRepoURL(using: probe)
        }
    }

    @Test("validatedRepoURL throws emptyRepoPath for a blank path")
    func validationThrowsForEmptyRepoPath() {
        let probe = StubProbe(gitPaths: ["/repo"])
        let form = RegattaSpawnForm(repoPath: "   ", prompt: "Task", providerID: .claudeCode)
        #expect(throws: RegattaSpawnFormError.emptyRepoPath) {
            _ = try form.validatedRepoURL(using: probe)
        }
    }

    @Test("the production probe accepts a directory containing .git")
    func fileSystemProbeAcceptsGitDir() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("regatta-spawnform-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: base.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: base) }

        let probe = FileSystemGitRepositoryProbe()
        #expect(probe.isGitRepository(at: base) == true)

        let notRepo = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        #expect(probe.isGitRepository(at: notRepo) == false)
    }

    // MARK: - Built WorkerSpec

    @Test("makeSpec carries the prompt, repo URL, and Claude provider")
    func builtSpecForClaude() {
        let form = RegattaSpawnForm(
            repoPath: "/repo",
            prompt: "  Fix login  ",
            providerID: .claudeCode
        )
        let spec = form.makeSpec(repoURL: URL(fileURLWithPath: "/repo"))
        #expect(spec.prompt == "Fix login", "prompt is trimmed")
        #expect(spec.repoURL.path == "/repo")
        #expect(spec.providerID == .claudeCode)
    }

    @Test("makeSpec records the chosen provider id (Codex)")
    func builtSpecForCodex() {
        let form = RegattaSpawnForm(repoPath: "/repo", prompt: "Add a test", providerID: .codex)
        let spec = form.makeSpec(repoURL: URL(fileURLWithPath: "/repo"))
        #expect(spec.providerID == .codex)
    }

    @Test("makeSpec records the chosen provider id (Gemini)")
    func builtSpecForGemini() {
        let form = RegattaSpawnForm(repoPath: "/repo", prompt: "Refactor", providerID: .gemini)
        let spec = form.makeSpec(repoURL: URL(fileURLWithPath: "/repo"))
        #expect(spec.providerID == .gemini)
    }

    @Test("makeSpec derives a worker name from the prompt's first line")
    func specNameFromPrompt() {
        let form = RegattaSpawnForm(
            repoPath: "/repo",
            prompt: "Investigate the 500\nmore detail here",
            providerID: .claudeCode
        )
        let spec = form.makeSpec(repoURL: URL(fileURLWithPath: "/repo"))
        #expect(spec.name == "Investigate the 500")
    }

    @Test("makeSpec honors an explicit name override")
    func specNameOverride() {
        let form = RegattaSpawnForm(repoPath: "/repo", prompt: "Task", providerID: .claudeCode)
        let spec = form.makeSpec(repoURL: URL(fileURLWithPath: "/repo"), name: "My worker")
        #expect(spec.name == "My worker")
    }

    @Test("workerName clips long prompts")
    func workerNameClipsLongPrompt() {
        let long = String(repeating: "a", count: 100)
        let name = RegattaSpawnForm.workerName(from: long, maxLength: 10)
        #expect(name.count <= 11) // 10 chars + ellipsis
        #expect(name.hasSuffix("…"))
    }
}
