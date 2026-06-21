import Foundation
import RegattaCore
import RegattaLoopUI

/// The production ``RegattaLoopEngineProviding`` that builds loop engines whose
/// per-iteration worker runs a real agent through the live ``RegattaOrchestrator``
/// (Seam B of the live-spawn wiring).
///
/// Each engine the provider builds wraps an ``OrchestratorLoopWorker``: every loop
/// iteration spawns one agent worker in an isolated worktree off the loop's target
/// repo, awaits it reaching a terminal status, and reports a classified
/// ``RegattaLoopOutcome``. The provider also wires the real `dry` stop condition
/// (#21) so the loop stops once an iteration produces no new changes; the engine's
/// safety caps backstop everything.
///
/// ## Concurrency
/// `Sendable` value type. The build closure captures only `Sendable` seams and
/// drives the actor-isolated orchestrator through `await`.
struct OrchestratorLoopEngineProvider: RegattaLoopEngineProviding {

    private let orchestrator: RegattaOrchestrator
    private let repoURL: URL
    private let diffProbe: any RegattaDiffProbing
    private let provider: any AgentProvider

    /// Creates a provider.
    ///
    /// - Parameters:
    ///   - orchestrator: The live orchestrator each iteration spawns through.
    ///   - repoURL: The on-disk repository the loop's agent works in.
    ///   - diffProbe: The worktree change-detection seam used both per iteration
    ///     and by the `dry` stop condition. Defaults to ``RegattaGitDiffProbe``.
    ///   - provider: The agent provider. Defaults to ``ClaudeCodeProvider``.
    init(
        orchestrator: RegattaOrchestrator,
        repoURL: URL,
        diffProbe: any RegattaDiffProbing = RegattaGitDiffProbe(),
        provider: any AgentProvider = ClaudeCodeProvider()
    ) {
        self.orchestrator = orchestrator
        self.repoURL = repoURL
        self.diffProbe = diffProbe
        self.provider = provider
    }

    func makeEngine(for configuration: RegattaLoopConfiguration) -> RegattaLoopEngine {
        let worker = OrchestratorLoopWorker(
            orchestrator: orchestrator,
            repoURL: repoURL,
            diffProbe: diffProbe,
            provider: provider
        )
        return RegattaLoopEngine(configuration: configuration, worker: worker)
    }
}

/// A ``RegattaLoopWorker`` that runs one real agent iteration through the live
/// ``RegattaOrchestrator``.
///
/// Each ``runIteration(index:goal:)`` spawns an agent worker against the loop's
/// repo, awaits a terminal status, and classifies the outcome:
/// - terminal `.done` with new worktree changes → ``RegattaLoopOutcome/Kind/progressed``,
/// - terminal `.done` with no changes → ``RegattaLoopOutcome/Kind/succeeded`` (the
///   paired `dry` condition stops the loop),
/// - any non-`.done` terminal status → ``RegattaLoopOutcome/Kind/failed``.
struct OrchestratorLoopWorker: RegattaLoopWorker {
    private let orchestrator: RegattaOrchestrator
    private let repoURL: URL
    private let diffProbe: any RegattaDiffProbing
    private let provider: any AgentProvider

    init(
        orchestrator: RegattaOrchestrator,
        repoURL: URL,
        diffProbe: any RegattaDiffProbing,
        provider: any AgentProvider
    ) {
        self.orchestrator = orchestrator
        self.repoURL = repoURL
        self.diffProbe = diffProbe
        self.provider = provider
    }

    func runIteration(index: Int, goal: String) async throws -> RegattaLoopOutcome {
        let spec = WorkerSpec(
            name: "loop pass \(index + 1)",
            prompt: goal,
            repoURL: repoURL,
            provider: provider
        )
        let id = await orchestrator.spawnWorker(spec)
        let terminal = await orchestrator.awaitTerminal(id)

        switch terminal?.status {
        case .done:
            let hasChanges: Bool
            if let worktree = await orchestrator.worktree(for: id) {
                hasChanges = (try? await diffProbe.hasUncommittedChanges(at: worktree.path)) ?? false
            } else {
                hasChanges = false
            }
            return RegattaLoopOutcome(
                kind: hasChanges ? .progressed : .succeeded,
                summary: hasChanges
                    ? "Iteration \(index + 1) made changes toward “\(goal)”"
                    : "Iteration \(index + 1) produced no new changes; stopping",
                tokensUsed: 0
            )
        case .failed(let reason), .blocked(let reason):
            return RegattaLoopOutcome(kind: .failed, summary: reason, tokensUsed: 0)
        default:
            return RegattaLoopOutcome(
                kind: .failed,
                summary: "Iteration \(index + 1) did not complete",
                tokensUsed: 0
            )
        }
    }
}
