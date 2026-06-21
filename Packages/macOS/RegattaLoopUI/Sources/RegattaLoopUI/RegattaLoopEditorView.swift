import SwiftUI
import RegattaCore

/// The inline editor for a loop's goal, exit condition + check, and safety caps.
///
/// Edits a local draft (`@State`) and reports the result through closures, so it
/// holds no view model reference. The parent owns commit / cancel and decides
/// whether to start the loop afterwards.
struct RegattaLoopEditorView: View {
    let initial: RegattaLoopConfiguration
    let onCommit: (RegattaLoopConfiguration) -> Void
    let onCancel: () -> Void

    @State private var goal: String
    @State private var usesIterationLimit: Bool
    @State private var iterationCount: Int
    @State private var maxIterations: Int
    @State private var usesTokenBudget: Bool
    @State private var tokenBudget: Int

    init(
        initial: RegattaLoopConfiguration,
        onCommit: @escaping (RegattaLoopConfiguration) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.initial = initial
        self.onCommit = onCommit
        self.onCancel = onCancel
        _goal = State(initialValue: initial.goal)
        switch initial.stopCondition {
        case .manual:
            _usesIterationLimit = State(initialValue: false)
            _iterationCount = State(initialValue: 5)
        case .iterations(let count):
            _usesIterationLimit = State(initialValue: true)
            _iterationCount = State(initialValue: max(1, count))
        }
        _maxIterations = State(initialValue: initial.safetyCaps.maxIterations)
        if let budget = initial.safetyCaps.tokenBudget {
            _usesTokenBudget = State(initialValue: true)
            _tokenBudget = State(initialValue: budget)
        } else {
            _usesTokenBudget = State(initialValue: false)
            _tokenBudget = State(initialValue: 50_000)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            field(label: String(localized: "regatta.loop.editor.goal", defaultValue: "Goal")) {
                TextField(
                    String(localized: "regatta.loop.editor.goal.placeholder", defaultValue: "What should this loop achieve?"),
                    text: $goal,
                    axis: .vertical
                )
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
                .accessibilityIdentifier("RegattaLoopEditorGoal")
            }

            exitConditionSection

            safetyCapsSection

            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button(String(localized: "regatta.loop.editor.cancel", defaultValue: "Cancel"), action: onCancel)
                    .controlSize(.small)
                Button(String(localized: "regatta.loop.editor.save", defaultValue: "Save")) {
                    onCommit(makeConfiguration())
                }
                .controlSize(.small)
                .keyboardShortcut(.defaultAction)
                .disabled(goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - Sections

    private var exitConditionSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(localized: "regatta.loop.editor.exit", defaultValue: "Exit condition"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            Toggle(isOn: $usesIterationLimit) {
                Text(String(localized: "regatta.loop.editor.exit.iterations", defaultValue: "Stop after N iterations"))
                    .font(.system(size: 11))
            }
            .toggleStyle(.checkbox)
            .controlSize(.small)

            if usesIterationLimit {
                Stepper(value: $iterationCount, in: 1...500) {
                    Text(
                        String(
                            format: String(localized: "regatta.loop.editor.exit.count", defaultValue: "%lld iterations"),
                            iterationCount
                        )
                    )
                    .font(.system(size: 11))
                }
                .controlSize(.small)
            } else {
                Text(String(localized: "regatta.loop.editor.exit.manual", defaultValue: "Runs until you stop it (or a cap trips)."))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var safetyCapsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(localized: "regatta.loop.editor.caps", defaultValue: "Safety caps"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            Stepper(value: $maxIterations, in: 1...1000) {
                Text(
                    String(
                        format: String(localized: "regatta.loop.editor.caps.maxIterations", defaultValue: "Max iterations: %lld"),
                        maxIterations
                    )
                )
                .font(.system(size: 11))
            }
            .controlSize(.small)

            Toggle(isOn: $usesTokenBudget) {
                Text(String(localized: "regatta.loop.editor.caps.tokenBudget.toggle", defaultValue: "Token budget"))
                    .font(.system(size: 11))
            }
            .toggleStyle(.checkbox)
            .controlSize(.small)

            if usesTokenBudget {
                Stepper(value: $tokenBudget, in: 1_000...10_000_000, step: 1_000) {
                    Text(
                        String(
                            format: String(localized: "regatta.loop.editor.caps.tokenBudget.value", defaultValue: "%lld tokens"),
                            tokenBudget
                        )
                    )
                    .font(.system(size: 11))
                }
                .controlSize(.small)
            }
        }
    }

    // MARK: - Helpers

    private func field<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func makeConfiguration() -> RegattaLoopConfiguration {
        let condition: RegattaLoopStopCondition = usesIterationLimit ? .iterations(iterationCount) : .manual
        let caps = RegattaLoopSafetyCaps(
            maxIterations: maxIterations,
            tokenBudget: usesTokenBudget ? tokenBudget : nil
        )
        return RegattaLoopConfiguration(
            goal: goal.trimmingCharacters(in: .whitespacesAndNewlines),
            stopCondition: condition,
            safetyCaps: caps
        )
    }
}
