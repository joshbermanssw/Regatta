import Testing
import Foundation
@testable import RegattaCore

/// Behavior tests for the Summon overlay's pure composition + presentation models
/// (issue #17): grid composition from a Fleet snapshot, the trailing spawn tile,
/// column-count layout, and the esc-dismiss / summon presentation transitions.
@Suite("SummonGrid")
struct SummonGridTests {

    // MARK: - Fixtures

    private func worker(_ name: String, _ status: WorkerStatus = .running) -> Worker {
        Worker(id: UUID(), name: name, prompt: "do \(name)", status: status)
    }

    // MARK: - Grid composition

    @Test("an empty Fleet still produces a grid with just the spawn tile")
    func emptyFleetHasSpawnTileOnly() {
        let grid = SummonGrid(workers: [])
        #expect(grid.tiles.count == 1)
        #expect(grid.tiles.last == .spawn)
        #expect(grid.workerTiles.isEmpty)
    }

    @Test("each worker becomes a worker tile in spawn order, followed by the spawn tile")
    func workersBecomeTilesInOrderThenSpawn() {
        let a = worker("alpha")
        let b = worker("bravo")
        let c = worker("charlie")
        let grid = SummonGrid(workers: [a, b, c])

        #expect(grid.tiles.count == 4)
        #expect(grid.tiles[0] == .worker(a))
        #expect(grid.tiles[1] == .worker(b))
        #expect(grid.tiles[2] == .worker(c))
        #expect(grid.tiles[3] == .spawn)
    }

    @Test("the spawn tile keeps a stable identity distinct from any worker")
    func spawnTileHasStableDistinctIdentity() {
        let grid = SummonGrid(workers: [worker("alpha")])
        let ids = grid.tiles.map(\.id)
        #expect(Set(ids).count == ids.count) // all unique
        #expect(SummonTile.spawn.id == "regatta.summon.spawn-tile")
    }

    @Test("worker tile identity matches the worker's UUID for stable ForEach diffing")
    func workerTileIdentityMatchesWorkerID() {
        let a = worker("alpha")
        #expect(SummonTile.worker(a).id == a.id.uuidString)
    }

    @Test("workerTiles excludes the trailing spawn tile")
    func workerTilesExcludesSpawn() {
        let grid = SummonGrid(workers: [worker("a"), worker("b")])
        #expect(grid.workerTiles.count == 2)
        #expect(!grid.workerTiles.contains(.spawn))
    }

    // MARK: - Column layout

    @Test("column count stays roughly square as the tile count grows")
    func columnCountStaysRoughlySquare() {
        // count = workers + 1 spawn tile.
        #expect(SummonGrid(workers: []).columnCount == 1)            // 1 tile
        #expect(SummonGrid(workers: [worker("a")]).columnCount == 2) // 2 tiles
        #expect(SummonGrid(workers: (0..<3).map { worker("\($0)") }).columnCount == 2) // 4 tiles
        #expect(SummonGrid(workers: (0..<4).map { worker("\($0)") }).columnCount == 3) // 5 tiles
        #expect(SummonGrid(workers: (0..<8).map { worker("\($0)") }).columnCount == 3) // 9 tiles
        #expect(SummonGrid(workers: (0..<9).map { worker("\($0)") }).columnCount == 4) // 10 tiles
    }

    @Test("column count is never less than one")
    func columnCountNeverBelowOne() {
        #expect(SummonGrid.columnCount(forTileCount: 0) == 1)
        #expect(SummonGrid.columnCount(forTileCount: 1) == 1)
    }
}

/// Behavior tests for ``SummonPresentation`` — the esc-dismiss / summon state.
@Suite("SummonPresentation")
struct SummonPresentationTests {

    @Test("a fresh presentation starts hidden")
    func startsHidden() {
        #expect(SummonPresentation().isPresented == false)
    }

    @Test("summon shows the overlay")
    func summonShows() {
        var p = SummonPresentation()
        p.summon()
        #expect(p.isPresented == true)
    }

    @Test("dismiss (esc) hides the overlay")
    func dismissHides() {
        var p = SummonPresentation(isPresented: true)
        p.dismiss()
        #expect(p.isPresented == false)
    }

    @Test("dismiss is idempotent when already hidden")
    func dismissIdempotent() {
        var p = SummonPresentation(isPresented: false)
        p.dismiss()
        #expect(p.isPresented == false)
    }

    @Test("toggle flips presentation both ways")
    func toggleFlips() {
        var p = SummonPresentation()
        p.toggle()
        #expect(p.isPresented == true)
        p.toggle()
        #expect(p.isPresented == false)
    }
}
