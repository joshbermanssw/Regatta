import SwiftUI
import RegattaCore
import RegattaFleet

// MARK: - RegattaSummonOverlayView

/// The Summon overlay (issue #17): a grid that fills the main work area with both
/// the handed-off PR **shepherds** and the Fleet's live ephemeral **workers**, so
/// "Open Fleet grid" shows the same Fleet the rail does. It stacks a Shepherds
/// section (a grid of compact shepherd cards, one per watched PR) above a Workers
/// section (worker cells + the trailing `+ spawn worker` tile). Dismissed with `esc`.
///
/// ## Snapshot-boundary rule (CLAUDE.md)
/// Both grids feed `ForEach` from value-typed snapshots projected at this top
/// level: the worker grid from ``SummonTile`` values, the shepherd grid from
/// ``ShepherdGridCellModel`` values. Cells receive a value plus closures — no
/// `@Observable`/orchestrator/`Fleet` reference crosses into a grid cell. The
/// view-model is read once here into local `let` constants.
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

    /// The spawn-form view-model while the form sheet is presented, or `nil`. Built
    /// from the overlay view-model when the spawn tile is activated so it carries the
    /// active tab's default repository. Mounted **outside** the tile `ForEach`, so
    /// its `@Observable` reference never crosses the grid snapshot boundary.
    @State private var spawnForm: RegattaSpawnFormViewModel?

    var body: some View {
        // Capture snapshots at this level — no @Observable read inside ForEach.
        let grid = viewModel.grid
        // Project shepherd snapshots into value-typed cell models here, before the
        // ForEach, so cells hold values + closures only (snapshot-boundary rule).
        let shepherdCells = viewModel.shepherds.map(ShepherdGridCellModel.init(state:))

        return ZStack {
            backdrop

            VStack(spacing: 0) {
                header
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: Self.sectionSpacing) {
                        shepherdsSection(shepherdCells)
                        workersSection(grid)
                    }
                    .padding(Self.outerPadding)
                }
            }

            dismissHint
        }
        .background(EscDismissCatcher { viewModel.dismiss() })
        .onAppear { viewModel.startObserving() }
        .accessibilityIdentifier("RegattaSummonOverlay")
        .sheet(item: $spawnForm) { formViewModel in
            RegattaSpawnFormView(
                viewModel: formViewModel,
                onClose: { spawnForm = nil }
            )
        }
    }

    // MARK: - Shepherds section

    /// The Shepherds section: a header plus a grid of compact shepherd cards (one
    /// per handed-off PR), or an empty-state line when no PR has been handed off.
    @ViewBuilder
    private func shepherdsSection(_ cells: [ShepherdGridCellModel]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader(
                icon: "sailboat.fill",
                title: String(localized: "regatta.summon.section.shepherds", defaultValue: "Shepherds")
            )
            if cells.isEmpty {
                sectionEmpty(
                    String(
                        localized: "regatta.summon.shepherds.empty",
                        defaultValue: "Hand a PR to Regatta and it appears here."
                    )
                )
            } else {
                LazyVGrid(columns: shepherdColumns, spacing: Self.cellSpacing) {
                    ForEach(cells) { cell in
                        ShepherdGridCell(
                            model: cell,
                            onDismiss: { viewModel.dismissShepherd(cell.pullRequest) }
                        )
                    }
                }
            }
        }
    }

    // MARK: - Workers section

    /// The Workers section: a header plus the worker grid and trailing spawn tile.
    @ViewBuilder
    private func workersSection(_ grid: SummonGrid) -> some View {
        let columns = Array(
            repeating: GridItem(.flexible(), spacing: Self.cellSpacing),
            count: max(1, grid.columnCount)
        )
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader(
                icon: "rectangle.grid.2x2",
                title: String(localized: "regatta.summon.section.workers", defaultValue: "Workers")
            )
            LazyVGrid(columns: columns, spacing: Self.cellSpacing) {
                ForEach(grid.tiles) { tile in
                    tileView(tile)
                }
            }
        }
    }

    /// A two-column flexible grid for the compact shepherd cards.
    private var shepherdColumns: [GridItem] {
        [
            GridItem(.flexible(), spacing: Self.cellSpacing),
            GridItem(.flexible(), spacing: Self.cellSpacing),
        ]
    }

    // MARK: - Section chrome

    private func sectionHeader(icon: String, title: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.5)
            Spacer(minLength: 0)
        }
        .accessibilityAddTraits(.isHeader)
    }

    private func sectionEmpty(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
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
                onCancel: { viewModel.cancelWorker(worker.id) },
                onRemove: { viewModel.removeWorker(worker.id) }
            )
            .frame(minHeight: Self.cellMinHeight)
        case .spawn:
            SpawnTile(onSpawn: { spawnForm = viewModel.makeSpawnFormViewModel() })
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
    private static let sectionSpacing: CGFloat = 20
}

// MARK: - ShepherdGridCellModel

/// A pure, value-typed projection of one handed-off PR shepherd into the compact
/// card the Open Fleet Grid renders.
///
/// It wraps ``ShepherdCardModel`` (reusing its CI-rollup and open-thread
/// projection rather than duplicating that logic) and surfaces the few fields the
/// grid-sized card shows: the PR reference and title, the CI rollup, the open
/// review-thread count, and the autonomy mode. Being a value (no `Fleet`/view-model
/// reference) keeps it on the safe side of the snapshot-boundary rule.
struct ShepherdGridCellModel: Identifiable, Equatable {
    /// The reused full card projection (CI rollup, thread rows, etc.).
    let card: ShepherdCardModel

    /// Stable identity, one card per PR.
    var id: String { card.id }

    /// The watched pull request (used for the dismiss intent and the title line).
    var pullRequest: PullRequestRef { card.state.pullRequest }

    /// The PR row title, e.g. `"regatta#42"`.
    var title: String { card.state.title }

    /// The coarse CI rollup for the header dot + label.
    var ciRollup: ShepherdCardModel.CIRollup { card.ciRollup }

    /// The number of open (unresolved) review threads.
    var openThreadCount: Int { card.openThreadCount }

    /// The per-PR autonomy mode.
    var autonomyMode: AutonomyMode { card.state.autonomyMode }

    /// The watcher's polling phase, used to surface starting/paused states.
    var phase: ShepherdPollPhase { card.state.phase }

    /// Projects a raw shepherd snapshot into a grid cell model.
    ///
    /// - Parameter state: The latest ``ShepherdState`` snapshot from the Fleet.
    init(state: ShepherdState) {
        self.card = ShepherdCardModel(state: state)
    }
}

// MARK: - ShepherdGridCell

/// A grid cell showing one handed-off PR shepherd in the Open Fleet Grid.
///
/// Receives a ``ShepherdGridCellModel`` value snapshot plus a dismiss closure
/// (snapshot-boundary rule). It mirrors the rail's ``ShepherdCard`` chrome in a
/// compact, tile-sized form: a CI-coloured status dot, the PR ref, a CI-rollup +
/// thread-count summary, an autonomy-mode badge, and a dismiss control.
private struct ShepherdGridCell: View {
    let model: ShepherdGridCellModel
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            summaryLine
            Spacer(minLength: 0)
            autonomyBadge
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(.white.opacity(0.08), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("RegattaSummonShepherdCell")
        .accessibilityLabel(
            String.localizedStringWithFormat(
                String(
                    localized: "regatta.summon.shepherd.a11y",
                    defaultValue: "Shepherd for %1$@, %2$@"
                ),
                model.title,
                ciLabel
            )
        )
    }

    private var header: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            Text(model.title)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help(String(localized: "regatta.summon.shepherd.dismiss.help", defaultValue: "Dismiss shepherd"))
            .accessibilityLabel(
                String.localizedStringWithFormat(
                    String(
                        localized: "regatta.summon.shepherd.dismiss.a11y",
                        defaultValue: "Dismiss shepherd for %@"
                    ),
                    model.title
                )
            )
        }
    }

    private var summaryLine: some View {
        Text(summaryText)
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var autonomyBadge: some View {
        Text(autonomyText)
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(.quaternary)
            )
            .lineLimit(1)
            .fixedSize()
    }

    // MARK: Derived presentation

    /// The summary line: the watcher phase when it has no data, otherwise the CI
    /// rollup plus open-thread count.
    private var summaryText: String {
        switch model.phase {
        case .starting:
            return String(localized: "fleet.shepherd.starting", defaultValue: "Starting…")
        case .failed(let reason):
            return String(
                format: String(localized: "fleet.shepherd.failed", defaultValue: "Poll failed: %@"),
                reason
            )
        case .paused(let reason, _):
            return String(
                format: String(localized: "fleet.shepherd.paused", defaultValue: "Paused: %@"),
                reason
            )
        case .watching:
            let open = model.openThreadCount
            guard open > 0 else { return ciLabel }
            let threads = String(
                format: String(localized: "fleet.shepherd.threads", defaultValue: "%lld open threads"),
                open
            )
            return "\(ciLabel) · \(threads)"
        }
    }

    private var ciLabel: String {
        switch model.ciRollup {
        case .none: return String(localized: "fleet.shepherd.ci.none", defaultValue: "No checks")
        case .failing: return String(localized: "fleet.shepherd.ci.failing", defaultValue: "CI failing")
        case .passing: return String(localized: "fleet.shepherd.ci.passing", defaultValue: "CI passing")
        case .running: return String(localized: "fleet.shepherd.ci.pending", defaultValue: "CI running")
        }
    }

    private var autonomyText: String {
        switch model.autonomyMode {
        case .staged: return String(localized: "fleet.autonomy.staged.badge", defaultValue: "Staged")
        case .auto: return String(localized: "fleet.autonomy.auto.badge", defaultValue: "Auto")
        }
    }

    /// CI-coloured status dot, mirroring the rail card's dot colour logic.
    private var statusColor: Color {
        switch model.phase {
        case .starting: return .gray
        case .failed: return .yellow
        case .paused: return .orange
        case .watching:
            switch model.ciRollup {
            case .failing: return .red
            case .passing: return .green
            case .running, .none: return .blue
            }
        }
    }
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
    let onRemove: () -> Void

    /// The shared, legible status presentation — the same projection the rail row
    /// uses, so the two surfaces never drift (shared-behavior policy).
    private var presentation: WorkerStatusPresentation {
        WorkerStatusPresentation(worker.status)
    }

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
                presentation.accessibilitySummary
            )
        )
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(presentation.dotColor)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            Text(worker.name)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
            Text(presentation.label)
                .font(.system(size: 10, weight: presentation.needsAttention ? .semibold : .regular))
                .foregroundStyle(presentation.needsAttention ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                .lineLimit(1)
            Spacer(minLength: 4)
            // Always offer a way to get rid of a worker: cancel while it's still
            // running, remove once it has reached a terminal state (done/failed/
            // cancelled/blocked) so dead cells can be cleared.
            Button(action: worker.status.isCancellable ? onCancel : onRemove) {
                Image(systemName: worker.status.isCancellable ? "xmark.circle.fill" : "trash.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help(
                worker.status.isCancellable
                    ? String(localized: "regatta.summon.cell.cancel.help", defaultValue: "Cancel worker")
                    : String(localized: "regatta.summon.cell.remove.help", defaultValue: "Remove worker")
            )
            .accessibilityLabel(
                String.localizedStringWithFormat(
                    worker.status.isCancellable
                        ? String(localized: "regatta.summon.cell.cancel.a11y", defaultValue: "Cancel worker %@")
                        : String(localized: "regatta.summon.cell.remove.a11y", defaultValue: "Remove worker %@"),
                    worker.name
                )
            )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// The seam where the worker's live terminal surface mounts once #14/#16 expose
    /// the worker's pane handle. Until then it leads with the worker's *goal* (the
    /// prominent content: "what's happening" clarity), surfaces any error reason,
    /// and demotes the live-terminal note to a muted footnote so it never reads as
    /// the main content.
    private var terminalSeam: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !worker.prompt.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text(String(localized: "regatta.summon.cell.goal", defaultValue: "Goal").uppercased())
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .tracking(0.5)
                    Text(worker.prompt)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.primary)
                        .lineLimit(5)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
            }
            if let detail = presentation.detail {
                Label(detail, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.orange)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer(minLength: 0)
            Label(
                String(localized: "regatta.summon.cell.seam", defaultValue: "Live terminal arrives with the Pane Bridge."),
                systemImage: "terminal"
            )
            .labelStyle(.titleAndIcon)
            .font(.system(size: 9))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
