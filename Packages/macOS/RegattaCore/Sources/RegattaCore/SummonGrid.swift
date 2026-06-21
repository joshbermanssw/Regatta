public import Foundation

/// A single tile in the Summon overlay grid.
///
/// The overlay fills the main work area with a grid of the Fleet's workers (issue
/// #17). Each ``SummonTile`` is either a live worker terminal cell or the trailing
/// `+ spawn worker` action tile. The view renders one SwiftUI cell per tile in
/// order, so this enum is the single source of truth for what the grid contains.
public enum SummonTile: Identifiable, Sendable, Equatable {

    /// A cell hosting a worker's live, interactive terminal.
    ///
    /// The associated ``Worker`` is an immutable snapshot (the snapshot-boundary
    /// rule: no orchestrator/actor reference crosses into the grid). The live
    /// terminal surface for this worker is resolved by the view from the worker's
    /// pane handle once issue #14/#16 exposes it; until then the cell renders a
    /// seam placeholder.
    case worker(Worker)

    /// The trailing tile that spawns a new worker when activated.
    case spawn

    /// A stable identity for `ForEach`: the worker's UUID, or a fixed sentinel for
    /// the spawn tile so it keeps its place as workers come and go.
    public var id: String {
        switch self {
        case .worker(let worker):
            return worker.id.uuidString
        case .spawn:
            return "regatta.summon.spawn-tile"
        }
    }
}

/// The pure, value-typed composition of the Summon overlay grid (issue #17).
///
/// Given a Fleet snapshot, ``SummonGrid`` produces the ordered list of
/// ``SummonTile`` values (one per worker, plus a trailing spawn tile) and the
/// number of columns the grid should use for that tile count. It holds no UI,
/// no actor reference, and no mutable state, so it is fully unit-testable without
/// SwiftUI: the overlay view-model builds one from the latest `updates()` snapshot
/// and the view lays the tiles out.
public struct SummonGrid: Sendable, Equatable {

    /// The ordered tiles: every worker in Fleet order, then the spawn tile.
    public let tiles: [SummonTile]

    /// The number of columns to lay the tiles out in (>= 1).
    public let columnCount: Int

    /// Builds a grid for the given Fleet snapshot.
    ///
    /// The workers appear in the order given (the orchestrator yields them in
    /// spawn order), followed by a single ``SummonTile/spawn`` tile. The column
    /// count is chosen so the grid stays roughly square as the worker count grows.
    ///
    /// - Parameter workers: The current Fleet snapshot, in spawn order.
    public init(workers: [Worker]) {
        var tiles: [SummonTile] = workers.map { .worker($0) }
        tiles.append(.spawn)
        self.tiles = tiles
        self.columnCount = Self.columnCount(forTileCount: tiles.count)
    }

    /// The worker tiles only, excluding the trailing spawn tile.
    public var workerTiles: [SummonTile] {
        tiles.filter {
            if case .worker = $0 { return true }
            return false
        }
    }

    /// Chooses a column count that keeps the grid roughly square.
    ///
    /// Uses the ceiling of the square root of the tile count, clamped to at least
    /// one column. For example: 1 tile → 1 col, 2–4 → 2 cols, 5–9 → 3 cols.
    ///
    /// - Parameter count: The total number of tiles (workers + spawn tile).
    /// - Returns: The number of columns, always `>= 1`.
    static func columnCount(forTileCount count: Int) -> Int {
        guard count > 1 else { return 1 }
        let root = Double(count).squareRoot()
        return max(1, Int(root.rounded(.up)))
    }
}
