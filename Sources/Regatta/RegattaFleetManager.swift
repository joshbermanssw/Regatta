import Foundation
import RegattaFleet

/// A thin `@MainActor` seam holding the app-lifetime ``Fleet`` so that
/// ``RegattaRailView`` and the handoff action share a single Fleet instance.
///
/// The Fleet owns every long-lived PR shepherd watcher; its identity-keyed
/// registry is what makes handing the same PR off twice idempotent across the
/// whole app, regardless of which entrypoint triggered the handoff.
///
/// Design note: a singleton is warranted for the same reason as
/// ``RegattaMemoryManager`` — `AppDelegate` (the composition root) and the
/// SwiftUI view tree both need the same Fleet and there is no other injection
/// path between them. The seam holds no logic.
@MainActor
final class RegattaFleetManager {

    /// Shared instance accessed by the rail view and the handoff action.
    static let shared = RegattaFleetManager()

    /// The shared production ``Fleet`` (real `gh`-backed poller).
    let fleet: Fleet

    private init() {
        fleet = Fleet()
    }
}
