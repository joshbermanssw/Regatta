import SwiftUI
import RegattaFleet
import RegattaGitHub

// MARK: - FleetSectionView

/// The Fleet rail section: a "hand to Regatta" action plus the list of
/// persistent PR shepherd watchers, driven by ``RegattaFleetViewModel``.
///
/// ## Handoff
/// When the active tab is attached to a PR, the header shows a "Hand to Regatta"
/// button. Tapping it resolves the PR from the injected `contextProvider` and
/// hands it off to the ``Fleet``, creating a persistent shepherd. Handing the
/// same PR off again is idempotent (no duplicate).
///
/// ## Snapshot-boundary rule (CLAUDE.md)
/// `shepherds` is read from the `@Observable` view-model at this level and
/// passed as **value snapshots** (`ShepherdState` is a `struct`) into
/// ``ShepherdRow`` — no view-model or `Fleet` reference escapes the `ForEach`.
///
/// ## No state mutation in body
/// The handoff is triggered only from a `Button` action; the `contextProvider`
/// closure is never called from `body`.
struct FleetSectionView: View {
    let viewModel: RegattaFleetViewModel
    /// Returns the active workspace context (incl. its PR) when the handoff
    /// button is tapped. `@MainActor`-isolated because the source of truth
    /// (`TabManager.selectedWorkspace`) is main-actor-bound. `nil` disables the
    /// handoff affordance.
    let contextProvider: (@MainActor () -> AttachedTabContext?)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            handoffButton
            shepherdList
        }
        .frame(maxWidth: .infinity)
        .onAppear {
            viewModel.observe()
        }
    }

    // MARK: - Handoff button

    @ViewBuilder
    private var handoffButton: some View {
        if contextProvider != nil {
            Button {
                handoffActiveTab()
            } label: {
                Label(
                    String(localized: "fleet.handoff.label", defaultValue: "Hand PR to Regatta"),
                    systemImage: "sailboat.fill"
                )
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .accessibilityIdentifier("FleetHandoffButton")
            .accessibilityLabel(
                String(localized: "fleet.handoff.a11y", defaultValue: "Hand the active tab's pull request to Regatta")
            )
            .help(String(localized: "fleet.handoff.tooltip", defaultValue: "Create a persistent shepherd that watches this PR's CI and reviews"))
        }
    }

    // MARK: - Shepherd list

    /// The list of persistent shepherds.
    ///
    /// Snapshot-boundary: `snapshots` is captured here (before the `ForEach`) as
    /// an immutable value array. Rows receive `ShepherdState` value copies only.
    private var shepherdList: some View {
        let snapshots: [ShepherdState] = viewModel.shepherds

        return Group {
            if snapshots.isEmpty {
                emptyView
            } else {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(snapshots) { shepherd in
                        ShepherdRow(
                            state: shepherd,
                            onDismiss: { dismiss(shepherd.pullRequest) }
                        )
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private var emptyView: some View {
        Text(String(localized: "fleet.empty", defaultValue: "No shepherds yet"))
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
    }

    // MARK: - Actions

    /// Resolves the active tab's PR and hands it off. Called only from a button.
    private func handoffActiveTab() {
        guard
            let ctx = contextProvider?(),
            let pr = ctx.pullRequest,
            let ref = PullRequestRef.parse(label: pr.label, number: pr.number)
        else { return }
        viewModel.handoff(ref)
    }

    private func dismiss(_ ref: PullRequestRef) {
        viewModel.dismiss(ref)
    }
}

// MARK: - ShepherdRow

/// A single shepherd row. Receives a `ShepherdState` **value snapshot** — no
/// view-model / `Fleet` reference is held (snapshot-boundary rule).
private struct ShepherdRow: View {
    let state: ShepherdState
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            statusDot
            VStack(alignment: .leading, spacing: 1) {
                Text(state.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(detailLine)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                String(localized: "fleet.shepherd.dismiss.a11y", defaultValue: "Dismiss shepherd")
            )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
    }

    /// A coloured dot summarising the shepherd's current health.
    private var statusDot: some View {
        Circle()
            .fill(dotColor)
            .frame(width: 7, height: 7)
    }

    private var dotColor: Color {
        switch state.phase {
        case .starting:
            return .gray
        case .failed:
            return .yellow
        case .watching:
            if state.checks.anyFailed { return .red }
            if state.checks.allSucceeded { return .green }
            return .blue // pending / in-progress
        }
    }

    /// The secondary line: CI summary + unresolved-thread count, or the phase.
    private var detailLine: String {
        switch state.phase {
        case .starting:
            return String(localized: "fleet.shepherd.starting", defaultValue: "Starting…")
        case .failed(let reason):
            return String(
                format: String(localized: "fleet.shepherd.failed", defaultValue: "Poll failed: %@"),
                reason
            )
        case .watching:
            return watchingDetail
        }
    }

    private var watchingDetail: String {
        let checks = state.checks
        let ci: String
        if checks.checks.isEmpty {
            ci = String(localized: "fleet.shepherd.ci.none", defaultValue: "No checks")
        } else if checks.anyFailed {
            ci = String(localized: "fleet.shepherd.ci.failing", defaultValue: "CI failing")
        } else if checks.allSucceeded {
            ci = String(localized: "fleet.shepherd.ci.passing", defaultValue: "CI passing")
        } else {
            ci = String(localized: "fleet.shepherd.ci.pending", defaultValue: "CI running")
        }

        let threads = state.unresolvedThreadCount
        guard threads > 0 else { return ci }
        let threadText = String(
            format: String(localized: "fleet.shepherd.threads", defaultValue: "%lld open threads"),
            threads
        )
        return "\(ci) · \(threadText)"
    }
}
