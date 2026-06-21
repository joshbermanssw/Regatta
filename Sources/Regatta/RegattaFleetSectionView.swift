import SwiftUI
import RegattaCore
import RegattaLoopUI

/// The Fleet rail section: lists workers and, for each, a loop badge that opens
/// the loop view (define goal / exit condition / caps, watch iteration history,
/// and control the loop).
///
/// Issue #22 wires the loop view's entry point. The worker model and its real
/// terminal pane come from the orchestration work in issues #16/#17; until those
/// land, this section drives the loop view with a built-in demo worker and the
/// terminal-jump action is stubbed behind ``RegattaLoopTerminalJumping``.
///
/// ## Snapshot boundary
/// The worker list reads its rows before the `LazyVStack` and passes value
/// snapshots plus closures into rows — no view model reference crosses the
/// boundary. The opened ``RegattaLoopView`` is mounted *outside* the list.
struct RegattaFleetSectionView: View {
    @State private var loopViewModel: RegattaLoopViewModel
    @State private var isLoopOpen = false

    init() {
        // Demo worker so the loop view is exercisable before #16/#17 wire a real
        // agent. Reports progress each turn; the engine's caps still backstop it.
        let provider = RegattaLoopEngineProvider { configuration in
            let worker = RegattaClosureLoopWorker { index, goal in
                RegattaLoopOutcome(
                    kind: .progressed,
                    summary: "Worked on “\(goal)” (pass \(index + 1))",
                    tokensUsed: 1_200
                )
            }
            return RegattaLoopEngine(configuration: configuration, worker: worker)
        }
        _loopViewModel = State(
            initialValue: RegattaLoopViewModel(
                configuration: RegattaLoopConfiguration(
                    goal: "",
                    stopCondition: .iterations(5),
                    safetyCaps: RegattaLoopSafetyCaps(maxIterations: 25, tokenBudget: 100_000)
                ),
                workerID: "demo-worker",
                engineProvider: provider
            )
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            workerRow
            if isLoopOpen {
                Divider().opacity(0.4)
                RegattaLoopView(viewModel: loopViewModel)
            }
        }
    }

    private var workerRow: some View {
        // Snapshot values captured before constructing the row.
        let phase = loopViewModel.phase
        let completed = loopViewModel.iterations.count

        return HStack(spacing: 6) {
            Image(systemName: "person.crop.circle")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text(String(localized: "regatta.fleet.worker.demo", defaultValue: "Demo worker"))
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer(minLength: 4)
            RegattaLoopBadge(
                phase: phase,
                completedIterations: completed,
                onOpen: { isLoopOpen.toggle() }
            )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}
