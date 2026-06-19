import Foundation
import RegattaMemory

/// A thin `@MainActor` seam that holds the app-lifetime ``MemoryStore`` so that
/// ``RegattaRailView`` (and any future app-level code) share a single store instance.
///
/// The store is initialised once at the app's Application Support directory. If
/// the directory cannot be created, `store` is `nil` and the Memory inspector
/// shows a graceful error state.
///
/// Design note: a singleton is warranted because `AppDelegate` (the composition
/// root) and the SwiftUI view tree both need access to the same store, and there
/// is no other injection path between them. The singleton holds no logic — it is
/// a seam only.
@MainActor
final class RegattaMemoryManager {

    // MARK: - Shared instance

    /// Shared instance accessed by the rail view and any future App Delegate teardown.
    static let shared = RegattaMemoryManager()

    // MARK: - Store

    /// The shared ``MemoryStore``, or `nil` if the backing directory could not
    /// be created.
    let store: MemoryStore?

    // MARK: - Init

    private init() {
        guard
            let appSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first
        else {
            store = nil
            return
        }

        let memoryDir = appSupport
            .appendingPathComponent("Regatta")
            .appendingPathComponent("memory")

        store = try? MemoryStore(baseDirectory: memoryDir)
    }
}
