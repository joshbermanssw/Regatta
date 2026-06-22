public import Foundation

/// The pure, value-typed model behind the Fleet "Spawn worker" form.
///
/// It captures the three user-editable inputs — the working directory (a git
/// repository), the task/prompt, and the chosen ``AgentProviderID`` — and turns
/// them into a real ``WorkerSpec`` for the orchestrator. All of its decisions are
/// pure functions of its fields, so the app-side `@Observable` view-model is a thin
/// adapter and every rule (default repo, required-prompt gating, git-repo
/// validation, the built spec) is unit-tested here with no UI.
///
/// ## Why this lives in RegattaCore
/// The spawn tile previously spawned a placeholder spec rooted at the launched
/// app's current directory (`/`), so worktree creation failed immediately. The
/// real fix is letting the user pick a repository and enter a task; keeping the
/// decision logic here (rather than in a SwiftUI view-model) makes those rules
/// directly testable and reusable across every spawn entrypoint.
public struct RegattaSpawnForm: Equatable, Sendable {

    /// The working-directory path the worker operates on. Must be a git
    /// repository for ``WorkerSpec`` creation to succeed downstream.
    public var repoPath: String

    /// The task/prompt handed to the agent. Required: spawning is gated on this
    /// being non-empty after trimming whitespace.
    public var prompt: String

    /// The chosen CLI agent provider. Defaults to Claude Code.
    public var providerID: AgentProviderID

    /// Creates a spawn form.
    ///
    /// - Parameters:
    ///   - repoPath: The working-directory path. Defaults to empty.
    ///   - prompt: The task/prompt. Defaults to empty.
    ///   - providerID: The agent provider. Defaults to ``AgentProviderID/default``.
    public init(
        repoPath: String = "",
        prompt: String = "",
        providerID: AgentProviderID = .default
    ) {
        self.repoPath = repoPath
        self.prompt = prompt
        self.providerID = providerID
    }

    // MARK: - Defaults

    /// Builds the initial form for a spawn, defaulting the repository to the active
    /// tab's working directory when available, otherwise to a sensible fallback
    /// (the user's home directory).
    ///
    /// The launched app's current directory is `/`, so the active tab's directory
    /// is the only signal that points at the repository the user is actually
    /// working in. When no context is available we fall back to `fallbackPath`
    /// rather than `/`, so the picker opens somewhere useful.
    ///
    /// - Parameters:
    ///   - contextDirectory: The active tab's current working directory, if any.
    ///   - fallbackPath: The path to use when `contextDirectory` is nil or blank.
    ///     Defaults to the user's home directory.
    ///   - providerID: The provider to preselect. Defaults to Claude Code.
    /// - Returns: A form preseeded with the default repository and an empty prompt.
    public static func makeDefault(
        contextDirectory: String?,
        fallbackPath: String = NSHomeDirectory(),
        providerID: AgentProviderID = .default
    ) -> RegattaSpawnForm {
        let trimmedContext = contextDirectory?.trimmingCharacters(in: .whitespacesAndNewlines)
        let repoPath = (trimmedContext?.isEmpty == false) ? trimmedContext! : fallbackPath
        return RegattaSpawnForm(repoPath: repoPath, prompt: "", providerID: providerID)
    }

    // MARK: - Derived state

    /// The prompt with leading/trailing whitespace removed.
    public var trimmedPrompt: String {
        prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The repo path with leading/trailing whitespace removed.
    public var trimmedRepoPath: String {
        repoPath.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether the Spawn action should be enabled: a non-empty trimmed prompt and a
    /// non-empty trimmed repo path. (Git-repo validity is checked separately at
    /// spawn time via ``validatedRepoURL(using:)`` so the button isn't disabled by
    /// filesystem probing on every keystroke.)
    public var canSpawn: Bool {
        !trimmedPrompt.isEmpty && !trimmedRepoPath.isEmpty
    }

    /// The repository URL for the trimmed repo path.
    public var repoURL: URL {
        URL(fileURLWithPath: trimmedRepoPath, isDirectory: true)
    }

    // MARK: - Validation

    /// Validates that the form's repo path points at a git repository, returning
    /// the resolved URL on success or a ``RegattaSpawnFormError`` describing what to
    /// fix on failure.
    ///
    /// - Parameter probe: The git-repository probe used to decide validity.
    /// - Returns: The validated repository URL.
    /// - Throws: ``RegattaSpawnFormError`` when the prompt is empty, the path is
    ///   blank, or the path is not a git repository.
    public func validatedRepoURL(
        using probe: some RegattaGitRepositoryProbe
    ) throws -> URL {
        guard !trimmedPrompt.isEmpty else { throw RegattaSpawnFormError.emptyPrompt }
        guard !trimmedRepoPath.isEmpty else { throw RegattaSpawnFormError.emptyRepoPath }
        let url = repoURL
        guard probe.isGitRepository(at: url) else {
            throw RegattaSpawnFormError.notAGitRepository(path: trimmedRepoPath)
        }
        return url
    }

    // MARK: - Spec building

    /// Builds the ``WorkerSpec`` described by this form for a validated repo URL.
    ///
    /// The worker name defaults to a short slug of the prompt so the Fleet list is
    /// readable; callers may override it. The provider is resolved through
    /// ``AgentProviderRegistry`` so the chosen CLI rides the same spawn path.
    ///
    /// - Parameters:
    ///   - repoURL: The validated repository URL (from ``validatedRepoURL(using:)``).
    ///   - name: An optional explicit worker name. When nil, a slug of the prompt
    ///     is used.
    /// - Returns: A ``WorkerSpec`` ready for `orchestrator.spawnWorker`.
    public func makeSpec(repoURL: URL, name: String? = nil) -> WorkerSpec {
        let provider = AgentProviderRegistry.provider(for: providerID)
        return WorkerSpec(
            name: name ?? Self.workerName(from: trimmedPrompt),
            prompt: trimmedPrompt,
            repoURL: repoURL,
            provider: provider
        )
    }

    /// Derives a short, single-line worker name from a prompt: the first line,
    /// clipped to a readable length. Falls back to a generic name for an empty
    /// prompt (which `canSpawn`/validation already prevents from spawning).
    public static func workerName(from prompt: String, maxLength: Int = 48) -> String {
        let firstLine = prompt
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        guard !firstLine.isEmpty else { return "New worker" }
        guard firstLine.count > maxLength else { return firstLine }
        let clipped = firstLine.prefix(maxLength).trimmingCharacters(in: .whitespaces)
        return clipped + "…"
    }
}

// MARK: - RegattaSpawnFormError

/// A reason the spawn form could not produce a worker.
public enum RegattaSpawnFormError: Error, Equatable, Sendable {
    /// The task/prompt was empty.
    case emptyPrompt
    /// The repository path was blank.
    case emptyRepoPath
    /// The chosen path is not a git repository.
    case notAGitRepository(path: String)
}

// MARK: - RegattaGitRepositoryProbe

/// Decides whether a filesystem path is a git repository.
///
/// Injected into ``RegattaSpawnForm/validatedRepoURL(using:)`` so the validation
/// decision is unit-tested with an in-memory fake and the production check reads
/// the filesystem.
public protocol RegattaGitRepositoryProbe: Sendable {
    /// Returns `true` when `url` is (or is inside) a git repository.
    func isGitRepository(at url: URL) -> Bool
}

/// The production git-repository probe: a path is a git repository when it
/// contains a `.git` entry (directory or file, the latter for worktrees and
/// submodules).
///
/// This is a cheap, synchronous filesystem check suitable for spawn-time
/// validation. It intentionally does not shell out to `git`; the worktree manager
/// performs the authoritative `rev-parse` check when it provisions the worktree,
/// and surfaces a toast on failure.
public struct FileSystemGitRepositoryProbe: RegattaGitRepositoryProbe {
    public init() {}

    public func isGitRepository(at url: URL) -> Bool {
        let gitEntry = url.appendingPathComponent(".git")
        return FileManager.default.fileExists(atPath: gitEntry.path)
    }
}
