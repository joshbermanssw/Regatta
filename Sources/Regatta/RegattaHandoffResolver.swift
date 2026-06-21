import Foundation
import RegattaFleet
import RegattaGitHub

/// Resolves which pull request the "Hand PR to Regatta" action should hand off,
/// falling back to `gh` branch→PR lookup when cmux's own PR detection
/// (`workspace.pullRequest`) is `nil`.
///
/// ## Root-cause fix (handoff was silent)
/// The handoff context's `pullRequest` is cmux's own detection, which is often
/// `nil`, so the old action returned silently. This resolver always yields a
/// definite ``RegattaHandoffResolution`` — including ``RegattaHandoffResolution/noPullRequest(branch:)``
/// and ``RegattaHandoffResolution/authFailure`` — so the caller can always show
/// feedback, and adds the `gh pr view` fallback so a real open PR is found even
/// when cmux missed it.
///
/// ## Testability
/// The `gh` invocation goes through the injected ``RegattaWorkspaceCommandRunning``
/// seam, so tests assert every decision branch (context PR present, `gh` resolves,
/// `gh` not-found, `gh` not-authed) with a stub and no process spawn.
struct RegattaHandoffResolver: Sendable {

    /// The cwd-aware `gh` runner used for the branch→PR fallback.
    private let runner: any RegattaWorkspaceCommandRunning

    /// Creates a resolver.
    ///
    /// - Parameter runner: The `gh` runner (defaults to the production
    ///   ``RegattaWorkspaceCommandRunner``).
    init(runner: any RegattaWorkspaceCommandRunning = RegattaWorkspaceCommandRunner()) {
        self.runner = runner
    }

    /// Resolves the PR to hand off from a workspace context.
    ///
    /// - When `context` is `nil` → ``RegattaHandoffResolution/noContext``.
    /// - When `context.pullRequest` parses → ``RegattaHandoffResolution/resolved(_:)``.
    /// - Otherwise runs `gh pr view` in the workspace directory to resolve the open
    ///   PR for the current branch, mapping `gh` outcomes to the matching cases.
    ///
    /// - Parameter context: The active workspace's context snapshot.
    /// - Returns: A definite resolution; never silently nothing.
    func resolve(context: AttachedTabContext?) async -> RegattaHandoffResolution {
        guard let context else { return .noContext }

        // Fast path: cmux already detected a PR.
        if let pr = context.pullRequest,
           let ref = PullRequestRef.parse(label: pr.label, number: pr.number) {
            return .resolved(ref)
        }

        // Fallback: ask `gh` for the open PR on the workspace's current branch.
        let directory = context.currentDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !directory.isEmpty else { return .noContext }
        return await resolveViaGitHub(directory: directory, branch: context.gitBranch)
    }

    // MARK: - gh fallback

    /// Runs `gh pr view --json number,headRepository,headRepositoryOwner` in the
    /// workspace and parses the open PR for its current branch.
    private func resolveViaGitHub(directory: String, branch: String?) async -> RegattaHandoffResolution {
        let args = ["pr", "view", "--json", "number,headRepository,headRepositoryOwner"]
        do {
            let output = try await runner.run(args, in: directory)
            guard let ref = Self.parsePullRequestRef(from: output) else {
                return .noPullRequest(branch: branch)
            }
            return .resolved(ref)
        } catch let error as GitHubCommandError {
            if error.isAuthFailure { return .authFailure }
            // `gh pr view` exits non-zero with "no pull requests found" when the
            // branch has no PR — that's a no-PR, not a hard failure.
            if case .nonZeroExit(_, let stderr) = error,
               Self.isNoPullRequest(stderr: stderr) {
                return .noPullRequest(branch: branch)
            }
            return .failure(Self.message(for: error))
        } catch {
            return .failure(String(describing: error))
        }
    }

    /// Parses a ``PullRequestRef`` from `gh pr view --json` output.
    static func parsePullRequestRef(from json: String) -> PullRequestRef? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let number = object["number"] as? Int,
              let repo = object["headRepository"] as? [String: Any],
              let repoName = repo["name"] as? String,
              let owner = object["headRepositoryOwner"] as? [String: Any],
              let ownerLogin = owner["login"] as? String,
              !repoName.isEmpty, !ownerLogin.isEmpty
        else { return nil }
        return PullRequestRef(owner: ownerLogin, repo: repoName, number: number)
    }

    /// Whether `gh`'s stderr indicates the branch simply has no PR (vs. a real
    /// error). `gh pr view` prints "no pull requests found for branch …".
    static func isNoPullRequest(stderr: String?) -> Bool {
        guard let stderr else { return false }
        let lowered = stderr.lowercased()
        return lowered.contains("no pull requests found")
            || lowered.contains("no pull request found")
            || lowered.contains("no open pull requests")
    }

    /// A compact human-readable message for a `gh` error.
    static func message(for error: GitHubCommandError) -> String {
        switch error {
        case .timedOut:
            return String(localized: "fleet.handoff.error.timeout", defaultValue: "GitHub CLI timed out")
        case .launchFailed:
            return String(localized: "fleet.handoff.error.launch", defaultValue: "Could not run the GitHub CLI")
        case .outputDecodingFailed, .jsonDecodingFailed:
            return String(localized: "fleet.handoff.error.parse", defaultValue: "Could not read the GitHub CLI response")
        case .nonZeroExit(_, let stderr):
            let trimmed = stderr?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let trimmed, !trimmed.isEmpty { return trimmed }
            return String(localized: "fleet.handoff.error.generic", defaultValue: "GitHub CLI returned an error")
        }
    }
}
