public import SwiftUI
import RegattaCore

/// The loop view: define the goal, pick the exit condition + check, see the
/// safety caps, watch iteration history stream live, and control the loop
/// (pause, jump into terminal, edit, stop).
///
/// Opens from a worker's ``RegattaLoopBadge`` in the Fleet. It is driven by a
/// ``RegattaLoopViewModel`` held by reference at this top level only. The live
/// history list reads ``RegattaLoopViewModel/iterations`` (an array of value
/// snapshots) *before* its `LazyVStack` and passes copies into rows, so no row
/// holds the view model or engine (snapshot-boundary rule).
public struct RegattaLoopView: View {
    @Bindable private var viewModel: RegattaLoopViewModel

    /// Creates the loop view.
    ///
    /// - Parameter viewModel: The loop view model to drive the UI.
    public init(viewModel: RegattaLoopViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if case .editing = viewModel.phase {
                RegattaLoopEditorView(
                    initial: viewModel.configuration,
                    onCommit: { viewModel.commitEdit($0) },
                    onCancel: { viewModel.cancelEdit() }
                )
            } else {
                summaryHeader
                Divider().opacity(0.4)
                controlBar
                Divider().opacity(0.4)
                historySection
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("RegattaLoopView")
    }

    // MARK: - Summary header

    private var summaryHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                statusChip
                Spacer(minLength: 0)
                Text(
                    String(
                        format: String(localized: "regatta.loop.summary.tokens", defaultValue: "%lld tok"),
                        viewModel.totalTokensUsed
                    )
                )
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            }

            Text(goalText)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            HStack(spacing: 10) {
                Label(exitConditionText, systemImage: "flag.checkered")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Label(capsText, systemImage: "shield.lefthalf.filled")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var statusChip: some View {
        Text(statusText)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(statusColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(statusColor.opacity(0.15)))
    }

    // MARK: - Control bar

    private var controlBar: some View {
        HStack(spacing: 8) {
            if viewModel.phase.isActive {
                controlButton(
                    title: String(localized: "regatta.loop.control.pause", defaultValue: "Pause"),
                    systemImage: "pause.fill",
                    action: { viewModel.pause() }
                )
                controlButton(
                    title: String(localized: "regatta.loop.control.stop", defaultValue: "Stop"),
                    systemImage: "stop.fill",
                    tint: .red,
                    action: { viewModel.stop() }
                )
            } else {
                controlButton(
                    title: startTitle,
                    systemImage: "play.fill",
                    tint: .green,
                    action: { viewModel.start() }
                )
                .disabled(!viewModel.phase.canStart)
            }

            controlButton(
                title: String(localized: "regatta.loop.control.edit", defaultValue: "Edit"),
                systemImage: "pencil",
                action: { viewModel.beginEdit() }
            )
            .disabled(!viewModel.canEdit)

            Spacer(minLength: 0)

            controlButton(
                title: String(localized: "regatta.loop.control.takeover", defaultValue: "Terminal"),
                systemImage: "terminal",
                action: { viewModel.jumpIntoTerminal() }
            )
            .disabled(!viewModel.canJumpIntoTerminal)
            .help(
                viewModel.canJumpIntoTerminal
                    ? String(localized: "regatta.loop.control.takeover.help", defaultValue: "Jump into the worker's terminal")
                    : String(localized: "regatta.loop.control.takeover.unavailable", defaultValue: "Terminal takeover is not available yet")
            )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func controlButton(
        title: String,
        systemImage: String,
        tint: Color = .secondary,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 11, weight: .medium))
                .labelStyle(.titleAndIcon)
        }
        .buttonStyle(.plain)
        .foregroundStyle(tint)
    }

    // MARK: - History

    private var historySection: some View {
        // Snapshot-boundary: capture the value-typed rows BEFORE the LazyVStack.
        let rows = viewModel.iterations

        return Group {
            if rows.isEmpty {
                emptyHistory
            } else {
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(rows) { row in
                            RegattaLoopIterationRowView(row: row)
                            Divider().opacity(0.2)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private var emptyHistory: some View {
        Text(String(localized: "regatta.loop.history.empty", defaultValue: "No iterations yet. Start the loop to begin."))
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
    }

    // MARK: - Derived text

    private var goalText: String {
        let trimmed = viewModel.configuration.goal.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return String(localized: "regatta.loop.summary.noGoal", defaultValue: "No goal set")
        }
        return trimmed
    }

    private var startTitle: String {
        if case .paused = viewModel.phase {
            return String(localized: "regatta.loop.control.resume", defaultValue: "Resume")
        }
        return String(localized: "regatta.loop.control.start", defaultValue: "Start")
    }

    private var exitConditionText: String {
        switch viewModel.configuration.stopCondition {
        case .manual:
            return String(localized: "regatta.loop.summary.exit.manual", defaultValue: "Manual")
        case .iterations(let count):
            return String(
                format: String(localized: "regatta.loop.summary.exit.iterations", defaultValue: "%lld iterations"),
                count
            )
        }
    }

    private var capsText: String {
        let caps = viewModel.configuration.safetyCaps
        if let budget = caps.tokenBudget {
            return String(
                format: String(localized: "regatta.loop.summary.caps.full", defaultValue: "max %lld · %lld tok"),
                caps.maxIterations,
                budget
            )
        }
        return String(
            format: String(localized: "regatta.loop.summary.caps.iterations", defaultValue: "max %lld"),
            caps.maxIterations
        )
    }

    private var statusText: String {
        switch viewModel.phase {
        case .idle:
            return String(localized: "regatta.loop.status.idle", defaultValue: "Idle")
        case .running:
            return String(localized: "regatta.loop.status.running", defaultValue: "Running")
        case .paused:
            return String(localized: "regatta.loop.status.paused", defaultValue: "Paused")
        case .editing:
            return String(localized: "regatta.loop.status.editing", defaultValue: "Editing")
        case .finished(let status):
            return finishedText(status)
        }
    }

    private func finishedText(_ status: RegattaLoopStatus) -> String {
        switch status {
        case .failed:
            return String(localized: "regatta.loop.status.failed", defaultValue: "Failed")
        case .stopped(let reason):
            switch reason {
            case .goalReached:
                return String(localized: "regatta.loop.status.goalReached", defaultValue: "Goal reached")
            case .iterationCountMet:
                return String(localized: "regatta.loop.status.done", defaultValue: "Done")
            case .manualStop:
                return String(localized: "regatta.loop.status.stopped", defaultValue: "Stopped")
            case .cancelled:
                return String(localized: "regatta.loop.status.cancelled", defaultValue: "Cancelled")
            case .maxIterationsCap:
                return String(localized: "regatta.loop.status.maxIterationsCap", defaultValue: "Max iterations cap")
            case .tokenBudgetCap:
                return String(localized: "regatta.loop.status.tokenBudgetCap", defaultValue: "Token budget cap")
            }
        default:
            return String(localized: "regatta.loop.status.idle", defaultValue: "Idle")
        }
    }

    private var statusColor: Color {
        switch viewModel.phase {
        case .running: return .blue
        case .paused, .editing: return .orange
        case .idle: return .secondary
        case .finished(let status):
            switch status {
            case .failed: return .red
            case .stopped(let reason): return reason.isSafetyCap ? .orange : .green
            default: return .secondary
            }
        }
    }
}
