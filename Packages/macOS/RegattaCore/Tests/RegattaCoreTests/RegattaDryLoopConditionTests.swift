import Testing
import Foundation
@testable import RegattaCore

/// Tests for issue #21's `dry` stop condition: stop the loop when an iteration
/// produces no new changes.
///
/// The dry detection runs against a **real temp git repo** through the real
/// ``RegattaGitDiffProbe`` (headless, no stub): one iteration commits a change
/// (dirty → continue), the next is a no-op (clean → stop). This proves the
/// diff-detection plumbing end-to-end. A separate test pins the condition's
/// decision logic directly. The engine's safety caps still apply throughout.
@Suite(.serialized)
struct RegattaDryLoopConditionTests {

    // MARK: - Fixture: real temp git repo

    /// Creates a temp git repo with an initial commit and returns its root URL.
    private func makeRepo() throws -> URL {
        let temp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("regatta-dry-test-\(UUID().uuidString)", isDirectory: true)
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

    /// Runs a git command, throwing on non-zero exit (output silenced).
    private func runGit(_ args: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "RegattaDryLoopConditionTests", code: Int(process.terminationStatus))
        }
    }

    // MARK: - End-to-end: real git, dirty then clean stops the loop

    /// A worker that writes-and-commits a new file on the first iteration (leaves
    /// the worktree clean), then does nothing on later iterations — also clean.
    /// With the dry worker + real git probe, the FIRST iteration is already "no
    /// new changes" (the worker committed everything), so the loop stops at
    /// iteration 0 with `goalReached` and records a dry result.
    @Test func cleanWorktreeStopsLoopAndRecordsDryResult() async throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }

        let journal = RegattaLoopJournal()
        // Worker commits its change so the worktree is left clean (dry).
        let inner = RegattaClosureLoopWorker { index, _ in
            let file = repo.appendingPathComponent("work-\(index).txt")
            try "change \(index)\n".write(to: file, atomically: true, encoding: .utf8)
            try self.runGit(["-C", repo.path, "add", "."])
            try self.runGit(["-C", repo.path, "commit", "-m", "iter \(index)"])
            return RegattaLoopOutcome(kind: .progressed, summary: "committed iter \(index)")
        }
        let dryWorker = RegattaDryWorker(
            wrapping: inner,
            worktreePath: repo,
            diffProbe: RegattaGitDiffProbe(),
            journal: journal
        )
        let engine = RegattaLoopEngine(
            configuration: RegattaLoopConfiguration(
                goal: "stop when no new changes",
                stopCondition: .manual,
                safetyCaps: RegattaLoopSafetyCaps(maxIterations: 10)
            ),
            worker: dryWorker,
            condition: RegattaDryLoopCondition()
        )

        let final = await engine.run()

        #expect(final.status == .stopped(.goalReached), "got \(final.status)")
        #expect(final.completedIterations == 1, "committed-clean iteration is dry; got \(final.completedIterations)")
        let dry = await journal.dryRecord(forIteration: 0)
        #expect(dry?.hadNewChanges == false)
        #expect(dry?.detail.contains("no new changes") == true)
    }

    /// A worker that leaves UNcommitted changes keeps the loop going (dirty),
    /// and only stops once an iteration leaves the worktree clean. Proves the
    /// probe distinguishes dirty from clean across iterations with real git.
    @Test func dirtyIterationsContinueUntilCleanStops() async throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }

        let journal = RegattaLoopJournal()
        let inner = RegattaClosureLoopWorker { index, _ in
            if index < 2 {
                // Leave an uncommitted change → worktree dirty → continue.
                let file = repo.appendingPathComponent("dirty-\(index).txt")
                try "uncommitted \(index)\n".write(to: file, atomically: true, encoding: .utf8)
            } else {
                // Commit everything → worktree clean → dry stop.
                try self.runGit(["-C", repo.path, "add", "."])
                try self.runGit(["-C", repo.path, "commit", "-m", "settle \(index)"])
            }
            return RegattaLoopOutcome(kind: .progressed, summary: "iter \(index)")
        }
        let engine = RegattaLoopEngine(
            configuration: RegattaLoopConfiguration(
                goal: "settle the worktree",
                stopCondition: .manual,
                safetyCaps: RegattaLoopSafetyCaps(maxIterations: 10)
            ),
            worker: RegattaDryWorker(
                wrapping: inner, worktreePath: repo,
                diffProbe: RegattaGitDiffProbe(), journal: journal
            ),
            condition: RegattaDryLoopCondition()
        )

        let final = await engine.run()

        #expect(final.status == .stopped(.goalReached), "got \(final.status)")
        #expect(final.completedIterations == 3, "two dirty + one clean; got \(final.completedIterations)")
        let records = await journal.allDryRecords()
        #expect(records.map(\.hadNewChanges) == [true, true, false])
    }

    // MARK: - Safety cap still wins

    /// A worktree that never settles (every iteration leaves an uncommitted
    /// change) is force-stopped by the max-iterations safety cap — the dry
    /// condition never bypasses the engine's caps.
    @Test func neverDryIsStoppedByMaxIterationsCap() async throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }

        let journal = RegattaLoopJournal()
        let inner = RegattaClosureLoopWorker { index, _ in
            let file = repo.appendingPathComponent("forever-\(index).txt")
            try "uncommitted \(index)\n".write(to: file, atomically: true, encoding: .utf8)
            return RegattaLoopOutcome(kind: .progressed, summary: "iter \(index)")
        }
        let engine = RegattaLoopEngine(
            configuration: RegattaLoopConfiguration(
                goal: "never settles",
                stopCondition: .manual,
                safetyCaps: RegattaLoopSafetyCaps(maxIterations: 4)
            ),
            worker: RegattaDryWorker(
                wrapping: inner, worktreePath: repo,
                diffProbe: RegattaGitDiffProbe(), journal: journal
            ),
            condition: RegattaDryLoopCondition()
        )

        let final = await engine.run()

        #expect(final.status == .stopped(.maxIterationsCap), "got \(final.status)")
        #expect(final.completedIterations == 4, "cap clamps to 4; got \(final.completedIterations)")
    }

    // MARK: - Condition decision logic (unit)

    /// The condition itself: `succeeded` → stop(goalReached), `failed` → fail,
    /// `progressed` → continue.
    @Test func conditionMapsOutcomeKindToDecision() {
        let condition = RegattaDryLoopCondition()
        let config = RegattaLoopConfiguration(goal: "g", stopCondition: .manual)

        func decision(for kind: RegattaLoopOutcome.Kind) -> RegattaLoopDecision {
            let outcome = RegattaLoopOutcome(kind: kind, summary: "s")
            let record = RegattaIterationRecord(index: 0, outcome: outcome, duration: 0)
            return condition.evaluate(
                RegattaLoopConditionContext(
                    configuration: config, lastIteration: record, history: [record]))
        }

        #expect(decision(for: .succeeded) == .stop(.goalReached))
        #expect(decision(for: .failed) == .fail(summary: "s"))
        #expect(decision(for: .progressed) == .continue)
    }
}
