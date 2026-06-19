import Testing
import Foundation
@testable import RegattaCore

// MARK: - Fixture helpers

/// Creates a throwaway git repo in a unique temp directory and returns its URL.
///
/// The repo has an initial commit so `git worktree add` works (requires HEAD).
/// The caller is responsible for removing the directory when done.
private func makeFixtureRepo() throws -> URL {
    let temp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("regatta-worktree-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)

    try runShell("git", ["-C", temp.path, "init"])
    try runShell("git", ["-C", temp.path, "config", "user.email", "regatta-test@example.com"])
    try runShell("git", ["-C", temp.path, "config", "user.name", "Regatta Test"])
    let readme = temp.appendingPathComponent("README.md")
    try "# fixture repo\n".write(to: readme, atomically: true, encoding: .utf8)
    try runShell("git", ["-C", temp.path, "add", "."])
    try runShell("git", ["-C", temp.path, "commit", "-m", "init"])

    return temp
}

/// Runs a command, throwing if it exits non-zero.
private func runShell(_ executable: String, _ args: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [executable] + args
    // Silence output in tests
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw NSError(
            domain: "RegattaWorktreeManagerTests",
            code: Int(process.terminationStatus),
            userInfo: [NSLocalizedDescriptionKey: "\(executable) \(args.joined(separator: " ")) exited \(process.terminationStatus)"]
        )
    }
}

/// Returns a unique temp directory URL (does not create it on disk).
private func makeTempDir(label: String = "base") -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("regatta-wt-base-\(label)-\(UUID().uuidString)", isDirectory: true)
}

// MARK: - Test suite

@Suite("RegattaWorktreeManager")
struct RegattaWorktreeManagerTests {

    // MARK: createWorktree

    @Test("createWorktree provisions a real worktree directory on the requested branch")
    func createWorktreeProvisionsDiskDirectory() async throws {
        let repo = try makeFixtureRepo()
        let base = makeTempDir(label: "create")
        defer {
            try? FileManager.default.removeItem(at: repo)
            try? FileManager.default.removeItem(at: base)
        }

        let manager = RegattaWorktreeManager(baseDirectory: base)
        let worktree = try await manager.createWorktree(
            forWorker: "worker-a",
            repoURL: repo,
            branch: "regatta-worker-a"
        )

        // Directory must exist on disk.
        #expect(FileManager.default.fileExists(atPath: worktree.path.path))
        // Branch and workerID must round-trip correctly.
        #expect(worktree.branch == "regatta-worker-a")
        #expect(worktree.workerID == "worker-a")
        // lookup must return the same value.
        let looked = await manager.worktree(forWorker: "worker-a")
        #expect(looked == worktree)
    }

    // MARK: allWorktrees / multiple workers

    @Test("allWorktrees returns one entry per provisioned worker")
    func allWorktreesTracksMultipleWorkers() async throws {
        let repo = try makeFixtureRepo()
        let base = makeTempDir(label: "multi")
        defer {
            try? FileManager.default.removeItem(at: repo)
            try? FileManager.default.removeItem(at: base)
        }

        let manager = RegattaWorktreeManager(baseDirectory: base)

        let wt1 = try await manager.createWorktree(
            forWorker: "worker-1",
            repoURL: repo,
            branch: "regatta-w1"
        )
        let wt2 = try await manager.createWorktree(
            forWorker: "worker-2",
            repoURL: repo,
            branch: "regatta-w2"
        )

        let all = await manager.allWorktrees()
        #expect(all.count == 2)
        #expect(all.contains(wt1))
        #expect(all.contains(wt2))
        // Paths must be different.
        #expect(wt1.path != wt2.path)
    }

    // MARK: cleanup (clean)

    @Test("cleanup on a clean worktree removes the directory and untracks the worker")
    func cleanupOnCleanWorktreeRemovesDirectory() async throws {
        let repo = try makeFixtureRepo()
        let base = makeTempDir(label: "cleanup-clean")
        defer {
            try? FileManager.default.removeItem(at: repo)
            try? FileManager.default.removeItem(at: base)
        }

        let manager = RegattaWorktreeManager(baseDirectory: base)
        let worktree = try await manager.createWorktree(
            forWorker: "worker-clean",
            repoURL: repo,
            branch: "regatta-clean"
        )
        let path = worktree.path

        try await manager.cleanup(forWorker: "worker-clean")

        // Directory must be gone.
        #expect(!FileManager.default.fileExists(atPath: path.path))
        // Mapping must be dropped.
        let looked = await manager.worktree(forWorker: "worker-clean")
        #expect(looked == nil)
    }

    // MARK: dirty guard

    @Test("cleanup with force:false throws worktreeDirty when the worktree has uncommitted files")
    func cleanupThrowsDirtyWhenUncommittedChangesExist() async throws {
        let repo = try makeFixtureRepo()
        let base = makeTempDir(label: "dirty")
        defer {
            try? FileManager.default.removeItem(at: repo)
            try? FileManager.default.removeItem(at: base)
        }

        let manager = RegattaWorktreeManager(baseDirectory: base)
        let worktree = try await manager.createWorktree(
            forWorker: "worker-dirty",
            repoURL: repo,
            branch: "regatta-dirty"
        )

        // Write an uncommitted file into the worktree.
        let dirtyFile = worktree.path.appendingPathComponent("dirty.txt")
        try "uncommitted change\n".write(to: dirtyFile, atomically: true, encoding: .utf8)

        // force:false must throw .worktreeDirty specifically.
        await #expect {
            try await manager.cleanup(forWorker: "worker-dirty", force: false)
        } throws: { error in
            guard case .worktreeDirty = error as? WorktreeError else { return false }
            return true
        }

        // Directory must still exist (guard fired; nothing was deleted).
        #expect(FileManager.default.fileExists(atPath: worktree.path.path))

        // force:true must succeed and remove the directory.
        try await manager.cleanup(forWorker: "worker-dirty", force: true)
        #expect(!FileManager.default.fileExists(atPath: worktree.path.path))
    }

    // MARK: no-git guard

    @Test("createWorktree against a non-git directory throws notAGitRepository")
    func createWorktreeThrowsForNonGitDirectory() async throws {
        let notARepo = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("regatta-not-a-repo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: notARepo, withIntermediateDirectories: true)
        let base = makeTempDir(label: "no-git")
        defer {
            try? FileManager.default.removeItem(at: notARepo)
            try? FileManager.default.removeItem(at: base)
        }

        let manager = RegattaWorktreeManager(baseDirectory: base)

        await #expect {
            try await manager.createWorktree(
                forWorker: "worker-nogit",
                repoURL: notARepo,
                branch: "regatta-nogit"
            )
        } throws: { error in
            guard case .notAGitRepository = error as? WorktreeError else { return false }
            return true
        }
    }

    // MARK: noWorktreeForWorker

    @Test("cleanup throws noWorktreeForWorker when the worker ID is unknown")
    func cleanupThrowsForUnknownWorker() async throws {
        let base = makeTempDir(label: "unknown")
        defer { try? FileManager.default.removeItem(at: base) }

        let manager = RegattaWorktreeManager(baseDirectory: base)

        await #expect {
            try await manager.cleanup(forWorker: "nobody")
        } throws: { error in
            guard case .noWorktreeForWorker = error as? WorktreeError else { return false }
            return true
        }
    }

    // MARK: duplicate workerID guard

    @Test("createWorktree throws worktreeAlreadyExists when the worker ID is already tracked")
    func createWorktreeThrowsForDuplicateWorkerID() async throws {
        let repo = try makeFixtureRepo()
        let base = makeTempDir(label: "duplicate")
        defer {
            try? FileManager.default.removeItem(at: repo)
            try? FileManager.default.removeItem(at: base)
        }

        let manager = RegattaWorktreeManager(baseDirectory: base)
        _ = try await manager.createWorktree(
            forWorker: "worker-dup",
            repoURL: repo,
            branch: "regatta-dup-1"
        )

        // A second createWorktree for the same workerID must throw .worktreeAlreadyExists.
        await #expect {
            try await manager.createWorktree(
                forWorker: "worker-dup",
                repoURL: repo,
                branch: "regatta-dup-2"
            )
        } throws: { error in
            guard case .worktreeAlreadyExists(let id) = error as? WorktreeError else { return false }
            return id == "worker-dup"
        }
    }
}
