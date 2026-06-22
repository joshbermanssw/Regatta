import Testing
import Foundation
@testable import RegattaCore

/// Tests for ``RegattaGitDiffProbe``'s new-commit detection.
///
/// The Fleet reactors prompt workers to **commit locally, not push** (so the
/// autonomy gate owns the push). A worker that commits leaves its worktree
/// *clean*, so probing only `git status` would wrongly report "no fix" and make
/// the ci-fix loop respawn forever. ``RegattaGitDiffProbe/hasNewCommits(at:)``
/// and the ``RegattaDiffProbing/hasProducedWork(at:)`` default catch the
/// committed-but-clean case. These run against a **real temp git repo + worktree**
/// through the real probe (headless, no stub).
@Suite(.serialized)
struct RegattaGitDiffProbeNewCommitsTests {

    // MARK: - Fixture

    /// Creates a temp git repo with an initial commit and returns its root URL.
    private func makeRepo() throws -> URL {
        let temp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("regatta-commits-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        try runGit(["-C", temp.path, "init"])
        try runGit(["-C", temp.path, "config", "user.email", "regatta-test@example.com"])
        try runGit(["-C", temp.path, "config", "user.name", "Regatta Test"])
        try "# fixture\n".write(
            to: temp.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try runGit(["-C", temp.path, "add", "."])
        try runGit(["-C", temp.path, "commit", "-m", "init"])
        return temp
    }

    /// Adds a worktree on a new branch and returns its path.
    private func addWorktree(in repo: URL, branch: String) throws -> URL {
        let path = repo.appendingPathComponent("wt-\(branch)", isDirectory: true)
        try runGit(["-C", repo.path, "worktree", "add", "-b", branch, path.path])
        // Each worktree shares the repo config, but set identity to be safe.
        try runGit(["-C", path.path, "config", "user.email", "regatta-test@example.com"])
        try runGit(["-C", path.path, "config", "user.name", "Regatta Test"])
        return path
    }

    private func runGit(_ args: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "RegattaGitDiffProbeNewCommitsTests", code: Int(process.terminationStatus))
        }
    }

    // MARK: - Tests

    @Test("a committed (clean) worktree is detected as new commits + produced work")
    func committedWorktreeIsProducedWork() async throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let wt = try addWorktree(in: repo, branch: "ci-fix-1")
        let probe = RegattaGitDiffProbe()

        // The agent commits its fix → clean worktree, but a new commit on the branch.
        try "fix\n".write(to: wt.appendingPathComponent("fix.txt"), atomically: true, encoding: .utf8)
        try runGit(["-C", wt.path, "add", "."])
        try runGit(["-C", wt.path, "commit", "-m", "the fix"])

        let uncommitted = try await probe.hasUncommittedChanges(at: wt)
        let newCommits = try await probe.hasNewCommits(at: wt)
        let produced = try await probe.hasProducedWork(at: wt)

        // Committed → working tree is clean…
        #expect(uncommitted == false)
        // …but the branch carries a new commit reachable from no other branch…
        #expect(newCommits == true)
        // …so the worker is correctly treated as having produced work to push.
        #expect(produced == true)
    }

    @Test("a fresh worktree with no commits and no edits has produced no work")
    func freshWorktreeHasNoWork() async throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let wt = try addWorktree(in: repo, branch: "ci-fix-2")
        let probe = RegattaGitDiffProbe()

        let uncommitted = try await probe.hasUncommittedChanges(at: wt)
        let newCommits = try await probe.hasNewCommits(at: wt)
        let produced = try await probe.hasProducedWork(at: wt)

        #expect(uncommitted == false)
        #expect(newCommits == false)
        #expect(produced == false)
    }

    @Test("an uncommitted edit is produced work even without a commit")
    func uncommittedEditIsProducedWork() async throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let wt = try addWorktree(in: repo, branch: "ci-fix-3")
        let probe = RegattaGitDiffProbe()

        try "wip\n".write(to: wt.appendingPathComponent("wip.txt"), atomically: true, encoding: .utf8)

        let produced = try await probe.hasProducedWork(at: wt)
        #expect(produced == true)
    }
}
