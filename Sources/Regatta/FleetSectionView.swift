import SwiftUI
import Foundation
import RegattaCore
import RegattaFleet
import RegattaGitHub

// MARK: - FleetSectionView

/// The unified Fleet rail section. It renders, top to bottom:
///
/// 1. the concurrency-cap stepper (#18),
/// 2. the live list of ephemeral brain-spawned ``Worker`` rows — each with a
///    provider badge (#36), a status dot, a cancel button, and a tap that summons
///    the worker-terminal grid (#17),
/// 3. the "Open Fleet grid" summon control (#17),
/// 4. the "Hand PR to Regatta" handoff control (#29), and
/// 5. the list of persistent PR ``ShepherdCard``s with per-PR autonomy toggles,
///    pending approvals, activity logs, and ci-fix-loop banners (#29/#30/#31/#32/#33).
///
/// ## Snapshot-boundary rule (CLAUDE.md)
/// Both lists read their snapshots from the `@Observable` view-model **above** the
/// `LazyVStack` and pass value copies (``Worker`` / ``ShepherdCardModel`` structs)
/// plus closures into rows. No view-model / orchestrator / `Fleet` reference
/// escapes the `ForEach`.
///
/// ## No state mutation in body
/// `observe()` runs in `.onAppear`; the `contextProvider` and summon closures are
/// only invoked from button/tap actions, never from `body`.
struct FleetSectionView: View {
    let viewModel: RegattaFleetViewModel

    /// Returns the active workspace context (incl. its PR) when the handoff button
    /// is tapped. `@MainActor`-isolated because the source of truth
    /// (`TabManager.selectedWorkspace`) is main-actor-bound. `nil` disables the
    /// handoff affordance.
    let contextProvider: (@MainActor () -> AttachedTabContext?)?

    /// Summons the worker-terminal grid overlay over the main work area (#17).
    /// Captured once at this level so the action closure passed into rows holds no
    /// `@Observable` reference (snapshot-boundary rule).
    private let onSummon: () -> Void = { RegattaSummonManager.shared.summon() }

    var body: some View {
        // Capture snapshots at this level — no @Observable read inside ForEach.
        let workers: [Worker] = viewModel.workers
        let summon = onSummon

        return VStack(alignment: .leading, spacing: 0) {
            FleetConcurrencyCapRow()
            workerSection(workers, summon: summon)
            summonRow(summon)
            Divider().opacity(0.3)
            handoffButton
            shepherdList
        }
        .frame(maxWidth: .infinity)
        .onAppear {
            viewModel.observe()
        }
    }

    // MARK: - Worker section (orchestrator)

    @ViewBuilder
    private func workerSection(_ workers: [Worker], summon: @escaping () -> Void) -> some View {
        if workers.isEmpty {
            workerEmptyView
        } else {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(workers) { worker in
                    WorkerRow(
                        worker: worker,
                        onCancel: { viewModel.cancelWorker(worker.id) },
                        onSummon: summon
                    )
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var workerEmptyView: some View {
        Text(String(localized: "regatta.fleet.empty.body", defaultValue: "Workers spawned by the brain will appear here."))
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
    }

    // MARK: - Summon control

    /// A full-width control that opens the worker-terminal grid overlay.
    private func summonRow(_ summon: @escaping () -> Void) -> some View {
        Button(action: summon) {
            HStack(spacing: 6) {
                Image(systemName: "rectangle.grid.2x2")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(String(localized: "regatta.summon.open", defaultValue: "Open Fleet grid"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(String(localized: "regatta.summon.open.help", defaultValue: "Open the worker terminal grid"))
        .accessibilityIdentifier("RegattaSummonOpenButton")
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

    /// The list of persistent shepherd cards.
    ///
    /// Snapshot-boundary: each card's ``ShepherdCardModel`` is projected here
    /// (before the `ForEach`) as an immutable value. Cards receive value copies +
    /// closures only — no view-model or `Fleet`/`AutonomyGate` reference escapes.
    private var shepherdList: some View {
        let cards: [ShepherdCardModel] = viewModel.shepherds.map { shepherd in
            ShepherdCardModel(
                state: shepherd,
                pending: viewModel.pendingActions.filter {
                    $0.pullRequest.id == shepherd.pullRequest.id
                },
                activity: viewModel.activity(for: shepherd.pullRequest),
                fixLoop: viewModel.fixLoop(for: shepherd.pullRequest)
            )
        }

        return Group {
            if cards.isEmpty {
                shepherdEmptyView
            } else {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(cards) { card in
                        let ref = card.state.pullRequest
                        ShepherdCard(
                            model: card,
                            actions: ShepherdCardActions(
                                onDismiss: { dismiss(ref) },
                                onSetMode: { mode in setMode(mode, for: ref) },
                                onApprove: { id in approve(id) },
                                onReject: { id in reject(id) }
                            )
                        )
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
        }
    }

    private var shepherdEmptyView: some View {
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

    private func dismiss(_ ref: PullRequestRef) { viewModel.dismiss(ref) }
    private func setMode(_ mode: AutonomyMode, for ref: PullRequestRef) { viewModel.setAutonomyMode(mode, for: ref) }
    private func approve(_ id: UUID) { viewModel.approve(id) }
    private func reject(_ id: UUID) { viewModel.reject(id) }
}

// MARK: - FleetConcurrencyCapRow

/// A stepper row controlling the Fleet concurrency cap — the maximum number of
/// workers allowed to run at once before the rest are held ``WorkerStatus/queued``
/// (issue #18).
///
/// Bound to `regatta.maxConcurrentWorkers` in `UserDefaults` via `@AppStorage`,
/// the same key the settings file store writes from `~/.config/cmux/cmux.json`.
/// ``RegattaFleetManager`` observes the change and pushes the new cap into the
/// orchestrator live. This row sits **above** the worker `LazyVStack`, so it holds
/// no store reference inside the list snapshot boundary.
private struct FleetConcurrencyCapRow: View {
    @AppStorage(RegattaConcurrencySettings.maxConcurrentWorkersKey)
    private var cap: Int = RegattaConcurrencySettings.defaultMaxConcurrentWorkers

    private var clampedCap: Int { RegattaConcurrencySettings.clamp(cap) }

    var body: some View {
        HStack(spacing: 8) {
            Text(String(localized: "regatta.fleet.cap.label", defaultValue: "Max concurrent"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Stepper(
                value: $cap,
                in: RegattaConcurrencySettings.minimumMaxConcurrentWorkers
                    ... RegattaConcurrencySettings.maximumMaxConcurrentWorkers
            ) {
                Text("\(clampedCap)")
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
            }
            .labelsHidden()
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            String.localizedStringWithFormat(
                String(localized: "regatta.fleet.cap.a11y", defaultValue: "Maximum concurrent workers, %lld"),
                clampedCap
            )
        )
    }
}

// MARK: - WorkerRow

/// A single Fleet worker row. Receives a ``Worker`` **value snapshot** plus
/// closures — no `@Observable` / orchestrator reference held (snapshot-boundary
/// rule).
private struct WorkerRow: View {
    let worker: Worker
    let onCancel: () -> Void
    /// Opens the worker-terminal grid overlay (issue #17).
    let onSummon: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            statusDot
            VStack(alignment: .leading, spacing: 1) {
                Text(worker.name)
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                HStack(spacing: 4) {
                    providerBadge
                    Text(statusLabel)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if worker.status.isCancellable {
                cancelButton
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSummon)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            String.localizedStringWithFormat(
                String(localized: "regatta.fleet.worker.a11y", defaultValue: "Worker %@, %@, %@"),
                worker.name,
                worker.providerID.displayName,
                statusLabel
            )
        )
    }

    // MARK: Provider badge

    /// A small badge naming the worker's CLI agent provider (issue #36). The
    /// provider name is a product brand name shown verbatim and not translated.
    private var providerBadge: some View {
        Text(worker.providerID.displayName)
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(.quaternary)
            )
            .lineLimit(1)
            .fixedSize()
    }

    // MARK: Status dot

    private var statusDot: some View {
        Circle()
            .fill(statusColor)
            .frame(width: 8, height: 8)
            .accessibilityHidden(true)
    }

    private var statusColor: Color {
        switch worker.status {
        case .queued:    return .secondary
        case .running:   return .blue
        case .done:      return .green
        case .failed:    return .red
        case .cancelled: return .orange
        case .interrupted: return .yellow
        }
    }

    private var statusLabel: String {
        switch worker.status {
        case .queued:
            return String(localized: "regatta.fleet.status.queued", defaultValue: "Queued")
        case .running:
            return String(localized: "regatta.fleet.status.running", defaultValue: "Running")
        case .done:
            return String(localized: "regatta.fleet.status.done", defaultValue: "Done")
        case .failed(let reason):
            return String.localizedStringWithFormat(
                String(localized: "regatta.fleet.status.failed", defaultValue: "Failed: %@"),
                reason
            )
        case .cancelled:
            return String(localized: "regatta.fleet.status.cancelled", defaultValue: "Cancelled")
        case .interrupted:
            return String(localized: "regatta.fleet.status.interrupted", defaultValue: "Interrupted")
        }
    }

    // MARK: Cancel button

    private var cancelButton: some View {
        Button(action: onCancel) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
        }
        .buttonStyle(.plain)
        .help(String(localized: "regatta.fleet.cancel.help", defaultValue: "Cancel worker"))
        .accessibilityLabel(
            String.localizedStringWithFormat(
                String(localized: "regatta.fleet.cancel.a11y", defaultValue: "Cancel worker %@"),
                worker.name
            )
        )
    }
}

// MARK: - ShepherdCardActions

/// The closure bundle passed to a ``ShepherdCard``. Keeps the snapshot-boundary
/// contract: cards hold value snapshots + this bundle of actions, never a store
/// reference.
struct ShepherdCardActions {
    let onDismiss: () -> Void
    let onSetMode: (AutonomyMode) -> Void
    let onApprove: (UUID) -> Void
    let onReject: (UUID) -> Void
}
