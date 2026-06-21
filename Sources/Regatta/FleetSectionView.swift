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

    var body: some View {
        // Capture the snapshot at this level — no @Observable read inside ForEach.
        let snapshots: [Worker] = viewModel.workers

        return Group {
            if snapshots.isEmpty {
                emptyView
            } else {
                workerList(snapshots)
            }
        }
        .frame(maxWidth: .infinity)
        .onAppear {
            viewModel.startObserving()
        }
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
    private func workerList(_ snapshots: [Worker]) -> some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(snapshots) { worker in
                WorkerRow(
                    worker: worker,
                    onCancel: { viewModel.cancelWorker(worker.id) }
                )
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - WorkerRow

/// A single Fleet worker row. Receives a ``Worker`` **value snapshot** plus a
/// cancel closure — no `@Observable` / orchestrator reference held
/// (snapshot-boundary rule).
private struct WorkerRow: View {
    let worker: Worker
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            statusDot
            VStack(alignment: .leading, spacing: 1) {
                Text(worker.name)
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(statusLabel)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if worker.status.isCancellable {
                cancelButton
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            String.localizedStringWithFormat(
                String(localized: "regatta.fleet.worker.a11y", defaultValue: "Worker %@, %@"),
                worker.name,
                statusLabel
            )
        )
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
