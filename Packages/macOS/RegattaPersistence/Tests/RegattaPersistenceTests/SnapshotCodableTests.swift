import Foundation
import Testing
@testable import RegattaPersistence
import RegattaCore
import RegattaGitHub
import RegattaFleet

/// Round-trip (encode → decode → equality) tests for every persisted entity.
///
/// These prove the on-disk Codable form is lossless for each snapshot type and
/// for the tolerant Codable conformances added to the upstream value types.
@Suite struct SnapshotCodableTests {

    private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: data)
    }

    // MARK: - Worker

    @Test func workerSnapshotRoundTrips() throws {
        let id = UUID()
        let snap = WorkerSnapshot(
            id: id,
            name: "Fix login",
            prompt: "Investigate the 500 on /login",
            status: .failed("boom"),
            providerID: .codex
        )
        #expect(try roundTrip(snap) == snap)
    }

    @Test(arguments: [
        WorkerStatus.queued,
        .running,
        .done,
        .failed("reason"),
        .cancelled,
        .interrupted,
    ])
    func workerStatusRoundTrips(_ status: WorkerStatus) throws {
        #expect(try roundTrip(status) == status)
    }

    // MARK: - Loop

    @Test func loopSnapshotRoundTripsWithHistory() throws {
        let config = RegattaLoopConfiguration(
            goal: "Make CI green",
            stopCondition: .iterations(5),
            safetyCaps: RegattaLoopSafetyCaps(maxIterations: 10, tokenBudget: 100_000)
        )
        let history = [
            RegattaIterationRecord(
                index: 0,
                outcome: RegattaLoopOutcome(kind: .progressed, summary: "tweaked", tokensUsed: 42),
                duration: 1.5
            ),
            RegattaIterationRecord(
                index: 1,
                outcome: RegattaLoopOutcome(kind: .succeeded, summary: "done", tokensUsed: 7),
                duration: 0.25
            ),
        ]
        let state = RegattaLoopState(
            configuration: config,
            status: .stopped(.goalReached),
            history: history
        )
        let snap = LoopSnapshot(workerID: "worker-1", state: state)
        let decoded = try roundTrip(snap)
        #expect(decoded == snap)
        // Derived total recomputed correctly on decode.
        #expect(decoded.state.totalTokensUsed == 49)
        #expect(decoded.state.completedIterations == 2)
    }

    @Test(arguments: [
        RegattaLoopStatus.idle,
        .running,
        .stopped(.goalReached),
        .stopped(.maxIterationsCap),
        .failed(summary: "kaboom"),
    ])
    func loopStatusRoundTrips(_ status: RegattaLoopStatus) throws {
        #expect(try roundTrip(status) == status)
    }

    @Test(arguments: [
        RegattaLoopStopCondition.manual,
        .iterations(0),
        .iterations(99),
    ])
    func stopConditionRoundTrips(_ condition: RegattaLoopStopCondition) throws {
        #expect(try roundTrip(condition) == condition)
    }

    // MARK: - Worktree

    @Test func worktreeSnapshotRoundTrips() throws {
        let snap = WorktreeSnapshot(
            workerID: "worker-7",
            path: URL(fileURLWithPath: "/tmp/regatta/worker-7"),
            branch: "regatta/worker-7",
            repoURL: URL(fileURLWithPath: "/repo")
        )
        #expect(try roundTrip(snap) == snap)
    }

    // MARK: - Shepherd

    @Test func shepherdStateRoundTrips() throws {
        let pr = PullRequestRef(owner: "joshbermanssw", repo: "regatta", number: 34)
        let checks = PRCheckSummary(checks: [
            PRCheck(name: "build", status: "COMPLETED", conclusion: "SUCCESS", detailsURL: nil),
        ])
        let thread = ReviewThread(
            id: "T1",
            isResolved: false,
            isOutdated: false,
            path: "Sources/Foo.swift",
            comments: [ReviewComment(id: "C1", body: "nit", author: "alice", url: "https://x")]
        )
        let state = ShepherdState(
            pullRequest: pr,
            phase: .watching,
            checks: checks,
            reviewThreads: [thread],
            autonomyMode: .auto
        )
        #expect(try roundTrip(state) == state)
    }

    // MARK: - Top-level snapshot

    @Test func fullStateSnapshotRoundTrips() throws {
        let pr = PullRequestRef(owner: "o", repo: "r", number: 1)
        let snap = RegattaStateSnapshot(
            workers: [
                WorkerSnapshot(id: UUID(), name: "w", prompt: "p", status: .running, providerID: .claudeCode),
            ],
            loops: [
                LoopSnapshot(
                    workerID: "w",
                    state: RegattaLoopState(
                        configuration: RegattaLoopConfiguration(goal: "g"),
                        status: .running,
                        history: []
                    )
                ),
            ],
            shepherds: [ShepherdState(pullRequest: pr, phase: .starting)],
            autonomyModes: [pr.id: .auto],
            worktrees: [
                WorktreeSnapshot(
                    workerID: "w",
                    path: URL(fileURLWithPath: "/tmp/w"),
                    branch: "b",
                    repoURL: URL(fileURLWithPath: "/repo")
                ),
            ]
        )
        #expect(try roundTrip(snap) == snap)
    }
}
