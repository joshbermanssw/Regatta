import SwiftUI
import RegattaCore

// MARK: - FleetSectionView

/// The Fleet rail section: a live list of brain-spawned workers, each with a
/// name, a status dot, and a cancel button while it is still running.
///
/// ## Snapshot-boundary rule (CLAUDE.md)
/// Rows inside `ForEach` receive **value snapshots** (``Worker`` is a `struct`)
/// plus a cancel closure. No `@Observable` view-model reference is captured inside
/// the `LazyVStack` / `ForEach` closures: the view-model is read once at this
/// level into local `let` constants before entering the lazy boundary.
///
/// ## No state mutation in body
/// `startObserving()` runs in `.onAppear`, never in a `body`-computed property.
struct FleetSectionView: View {
    let viewModel: RegattaFleetViewModel

    /// Summons the worker-terminal grid overlay over the main work area (issue #17).
    /// Captured once at this level so the action closure passed into rows holds no
    /// `@Observable` reference (snapshot-boundary rule).
    private let onSummon: () -> Void = { RegattaSummonManager.shared.summon() }

    var body: some View {
        // Capture the snapshot at this level — no @Observable read inside ForEach.
        let snapshots: [Worker] = viewModel.workers
        let summon = onSummon

        return VStack(spacing: 0) {
            FleetConcurrencyCapRow()
            if snapshots.isEmpty {
                emptyView
            } else {
                workerList(snapshots, summon: summon)
            }
            summonRow(summon)
        }
        .frame(maxWidth: .infinity)
        .onAppear {
            viewModel.startObserving()
        }
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

    // MARK: - Empty

    private var emptyView: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(String(localized: "regatta.fleet.empty.title", defaultValue: "No workers yet"))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Text(String(localized: "regatta.fleet.empty.body", defaultValue: "Workers spawned by the brain will appear here."))
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - List

    /// The worker list. Snapshot-boundary: `snapshots` and the per-row cancel
    /// closure are the only things crossing into the lazy rows.
    private func workerList(_ snapshots: [Worker], summon: @escaping () -> Void) -> some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(snapshots) { worker in
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

// MARK: - FleetConcurrencyCapRow

/// A stepper row controlling the Fleet concurrency cap — the maximum number of
/// workers allowed to run at once before the rest are held ``WorkerStatus/queued``
/// (issue #18).
///
/// Bound to `regatta.maxConcurrentWorkers` in `UserDefaults` via `@AppStorage`, the
/// same key the settings file store writes from `~/.config/cmux/cmux.json`. Editing
/// it here updates that value; ``RegattaFleetManager`` observes the change and
/// pushes the new cap into the orchestrator live (promoting queued workers when
/// raised, holding new spawns when lowered). This row sits **above** the worker
/// `LazyVStack`, so it holds no store reference inside the list snapshot boundary.
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
                String(
                    localized: "regatta.fleet.cap.a11y",
                    defaultValue: "Maximum concurrent workers, %lld"
                ),
                clampedCap
            )
        )
    }
}

// MARK: - WorkerRow

/// A single Fleet worker row. Receives a ``Worker`` **value snapshot** plus a
/// cancel closure — no `@Observable` / orchestrator reference held
/// (snapshot-boundary rule).
private struct WorkerRow: View {
    let worker: Worker
    let onCancel: () -> Void
    /// Opens the worker-terminal grid overlay (issue #17). A clicked worker row
    /// summons the grid filling the main work area.
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
        .accessibilityAddTraits(.isButton)
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
    /// provider name is a product brand name (e.g. "Claude Code", "Codex",
    /// "Gemini") shown verbatim and not translated.
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
