import SwiftUI
import RegattaCore

// MARK: - RegattaSummonOverlayView

/// The Summon overlay (issue #17): a grid that fills the main work area with the
/// Fleet's live worker terminals plus a trailing `+ spawn worker` tile, dismissed
/// with `esc`.
///
/// ## Snapshot-boundary rule (CLAUDE.md)
/// The grid feeds `ForEach` from value-typed ``SummonTile`` snapshots. The cells
/// receive a ``Worker`` value plus a cancel closure, and the spawn tile receives a
/// spawn closure — no `@Observable`/orchestrator reference crosses into the grid.
/// The view-model is read once at this top level into local `let` constants.
///
/// ## No state mutation in body
/// `startObserving()` runs in `.onAppear`. The `esc` key handler calls the
/// view-model's `dismiss()` intent; it never mutates store state inside `body`.
///
/// ## Live-surface seam (#14/#16)
/// Each worker cell renders a seam placeholder where its live terminal surface
/// will mount once the worker's pane handle is exposed (the ``Worker`` snapshot
/// does not carry it yet, and the production `PaneBridge` is #14). The grid,
/// dismiss, and spawn behavior are complete against that seam.
struct RegattaSummonOverlayView: View {
    let viewModel: RegattaSummonViewModel

    var body: some View {
        // Capture the snapshot at this level — no @Observable read inside ForEach.
        let grid = viewModel.grid
        let columns = Array(
            repeating: GridItem(.flexible(), spacing: Self.cellSpacing),
            count: max(1, grid.columnCount)
        )

        return ZStack {
            backdrop

            VStack(spacing: 0) {
                header
                ScrollView(.vertical) {
                    LazyVGrid(columns: columns, spacing: Self.cellSpacing) {
                        ForEach(grid.tiles) { tile in
                            tileView(tile)
                        }
                    }
                    .padding(Self.outerPadding)
                }
            }

            dismissHint
        }
        .background(EscDismissCatcher { viewModel.dismiss() })
        .onAppear { viewModel.startObserving() }
        .accessibilityIdentifier("RegattaSummonOverlay")
    }

    // MARK: - Backdrop

    private var backdrop: some View {
        Rectangle()
            .fill(.black.opacity(0.55))
            .background(.ultraThinMaterial)
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .accessibilityHidden(true)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sailboat")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(String(localized: "regatta.summon.title", defaultValue: "Fleet"))
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
            Spacer(minLength: 8)
            Button(action: { viewModel.dismiss() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .help(String(localized: "regatta.summon.close.help", defaultValue: "Dismiss overlay (esc)"))
            .accessibilityLabel(String(localized: "regatta.summon.close.a11y", defaultValue: "Dismiss Fleet overlay"))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Tiles

    @ViewBuilder
    private func tileView(_ tile: SummonTile) -> some View {
        switch tile {
        case .worker(let worker):
            WorkerCell(
                worker: worker,
                onCancel: { viewModel.cancelWorker(worker.id) }
            )
            .frame(minHeight: Self.cellMinHeight)
        case .spawn:
            SpawnTile(onSpawn: { viewModel.spawnWorker() })
                .frame(minHeight: Self.cellMinHeight)
        }
    }

    // MARK: - Dismiss hint

    private var dismissHint: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                Text(String(localized: "regatta.summon.dismissHint", defaultValue: "esc to dismiss"))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.thinMaterial, in: Capsule())
                    .padding(16)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: - Layout constants

    private static let cellSpacing: CGFloat = 12
    private static let outerPadding: CGFloat = 16
    private static let cellMinHeight: CGFloat = 200
}

// MARK: - WorkerCell

/// A grid cell hosting a single worker's live terminal (issue #17).
///
/// Receives a ``Worker`` value snapshot plus a cancel closure (snapshot-boundary
/// rule). The cell header mirrors the Fleet rail chrome — status dot, monospace
/// name, status label, cancel — and the body is the live-terminal seam.
private struct WorkerCell: View {
    let worker: Worker
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.4)
            terminalSeam
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(.white.opacity(0.08), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            String.localizedStringWithFormat(
                String(localized: "regatta.summon.cell.a11y", defaultValue: "Worker terminal %@, %@"),
                worker.name,
                statusLabel
            )
        )
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            Text(worker.name)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
            Text(statusLabel)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            if worker.status.isCancellable {
                Button(action: onCancel) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help(String(localized: "regatta.summon.cell.cancel.help", defaultValue: "Cancel worker"))
                .accessibilityLabel(
                    String.localizedStringWithFormat(
                        String(localized: "regatta.summon.cell.cancel.a11y", defaultValue: "Cancel worker %@"),
                        worker.name
                    )
                )
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// The seam where the worker's live terminal surface mounts once #14/#16 expose
    /// the worker's pane handle. Until then it shows the worker's prompt and a note.
    private var terminalSeam: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !worker.prompt.isEmpty {
                Text(worker.prompt)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer(minLength: 0)
            Text(String(localized: "regatta.summon.cell.seam", defaultValue: "Live terminal arrives with the Pane Bridge."))
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
}

// MARK: - SpawnTile

/// The trailing `+ spawn worker` tile (issue #17). Activating it asks the
/// orchestrator to spawn a new worker via the view-model's spawn intent.
private struct SpawnTile: View {
    let onSpawn: () -> Void

    var body: some View {
        Button(action: onSpawn) {
            VStack(spacing: 10) {
                Image(systemName: "plus")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(String(localized: "regatta.summon.spawn", defaultValue: "Spawn worker"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .buttonStyle(.plain)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(
                    style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])
                )
                .foregroundStyle(.tertiary)
        )
        .accessibilityLabel(String(localized: "regatta.summon.spawn.a11y", defaultValue: "Spawn a new worker"))
    }
}

// MARK: - EscDismissCatcher

/// An invisible AppKit responder that catches the `esc` (cancel) key and routes it
/// to the dismiss closure, so the overlay can be dismissed with `esc` regardless
/// of which terminal cell holds focus.
///
/// Uses `cancelOperation(_:)` — AppKit's standard mapping for the `esc` key — so
/// no global key monitor is installed and typing into worker terminals is
/// unaffected (the responder only acts when `esc` bubbles up unhandled).
private struct EscDismissCatcher: NSViewRepresentable {
    let onEsc: () -> Void

    func makeNSView(context: Context) -> EscCatchingView {
        let view = EscCatchingView()
        view.onEsc = onEsc
        return view
    }

    func updateNSView(_ nsView: EscCatchingView, context: Context) {
        nsView.onEsc = onEsc
    }

    final class EscCatchingView: NSView {
        var onEsc: (() -> Void)?

        override var acceptsFirstResponder: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.makeFirstResponder(self)
        }

        override func cancelOperation(_ sender: Any?) {
            onEsc?()
        }
    }
}
