import Foundation

/// A thin `@MainActor` singleton that holds the app-lifetime
/// ``RegattaBrainViewModel`` so that ``AppDelegate`` can reach it for teardown
/// without the rail view needing to pass a reference up.
///
/// The rail creates the VM as a `@State` that owns it for rendering; this
/// manager holds the *same* instance so the AppDelegate can call
/// ``RegattaBrainManager/shutdown()`` on quit.
///
/// Design note: a singleton is warranted here because `AppDelegate` (the
/// composition root) has no other path to the view-model that the SwiftUI view
/// tree owns. The singleton holds no additional state — it is purely a seam.
@MainActor
final class RegattaBrainManager {
    /// Shared instance accessed by `AppDelegate.applicationWillTerminate`.
    static let shared = RegattaBrainManager()

    /// Set by `RegattaRailView` when it creates the view-model.
    var viewModel: RegattaBrainViewModel?

    private init() {}

    /// Tears down the active Brain session. Called from
    /// `AppDelegate.applicationWillTerminate`.
    func shutdown() {
        viewModel?.shutdown()
    }
}
