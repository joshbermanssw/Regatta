import AppKit
import SwiftUI

/// A `@MainActor` seam that owns the app-lifetime Summon overlay view-model and
/// presents the overlay window over the main work area (issue #17).
///
/// ## Why a singleton seam
/// Like ``RegattaFleetManager`` / ``RegattaBrainManager``, the Fleet rail (which
/// triggers a summon) and the overlay window (which renders it) both need the
/// *same* ``RegattaSummonViewModel``, and there is no other injection path between
/// a SwiftUI rail section and a separately-hosted overlay window. The seam holds no
/// logic beyond constructing the view-model once and showing/hiding the window.
///
/// ## Window-hosted overlay
/// The overlay fills the main area but is hosted in its own borderless window sized
/// and pinned to the main window's content frame, rather than mounted inside the
/// 16k-line `ContentView` god file. This keeps it entirely off the typing-latency
/// hot paths (`hitTest`, `TabItemView`, `forceRefresh`) per CLAUDE.md while still
/// covering the work area.
@MainActor
final class RegattaSummonManager {

    /// Shared instance used by the Fleet rail summon trigger and the overlay window.
    static let shared = RegattaSummonManager()

    /// The app-lifetime overlay view-model, observed by the overlay view.
    let viewModel = RegattaSummonViewModel()

    /// The borderless window hosting the overlay, created lazily on first summon.
    private var overlayWindow: NSWindow?

    private init() {}

    /// Summons the overlay grid over the main window's content area.
    ///
    /// - Parameter mainWindow: The window whose content frame the overlay covers.
    ///   Defaults to the key window.
    func summon(over mainWindow: NSWindow? = NSApp.keyWindow) {
        viewModel.summon()
        present(over: mainWindow)
    }

    /// Toggles the overlay over the main window's content area.
    ///
    /// - Parameter mainWindow: The window whose content frame the overlay covers.
    func toggle(over mainWindow: NSWindow? = NSApp.keyWindow) {
        if overlayWindow?.isVisible == true {
            dismiss()
        } else {
            summon(over: mainWindow)
        }
    }

    /// Dismisses the overlay, leaving the underlying work untouched.
    func dismiss() {
        viewModel.dismiss()
        overlayWindow?.orderOut(nil)
    }

    // MARK: - Window presentation

    private func present(over mainWindow: NSWindow?) {
        guard let host = mainWindow else { return }
        let frame = host.contentRect(forFrameRect: host.frame)

        let window = overlayWindow ?? makeOverlayWindow()
        overlayWindow = window
        window.setFrame(frame, display: true)
        host.addChildWindow(window, ordered: .above)
        window.makeKeyAndOrderFront(nil)
    }

    private func makeOverlayWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .normal
        window.identifier = NSUserInterfaceItemIdentifier("cmux.regatta.summon")
        window.contentView = NSHostingView(
            rootView: RegattaSummonOverlayView(viewModel: viewModel)
        )
        return window
    }
}
