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

    /// Local key-event monitor active only while the overlay is visible, so `esc`
    /// dismisses it regardless of which window holds key focus (a borderless child
    /// window does not reliably become key, so relying on the responder chain alone
    /// missed `esc`).
    private var escMonitor: Any?

    private init() {}

    /// Summons the overlay grid over the main window's content area.
    ///
    /// - Parameters:
    ///   - mainWindow: The window whose content frame the overlay covers.
    ///     Defaults to the key window.
    ///   - contextProvider: Supplies the active workspace tab's context so the spawn
    ///     form defaults its repository to the active repo. Recorded on the
    ///     view-model so the window-hosted overlay can reach it.
    func summon(
        over mainWindow: NSWindow? = NSApp.keyWindow,
        contextProvider: (@MainActor () -> AttachedTabContext?)? = nil
    ) {
        if let contextProvider {
            viewModel.setContextProvider(contextProvider)
        }
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
        if let escMonitor {
            NSEvent.removeMonitor(escMonitor)
            self.escMonitor = nil
        }
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
        installEscMonitor()
    }

    /// Installs a local key-down monitor that dismisses the overlay on `esc`
    /// (keyCode 53) and passes every other key through untouched, so typing is
    /// unaffected. Idempotent — only one monitor is ever active.
    private func installEscMonitor() {
        guard escMonitor == nil else { return }
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.overlayWindow?.isVisible == true else { return event }
            if event.keyCode == 53 { // esc
                self.dismiss()
                return nil
            }
            return event
        }
    }

    private func makeOverlayWindow() -> NSWindow {
        let window = SummonOverlayWindow(
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

/// A borderless overlay window that is allowed to become key.
///
/// Borderless `NSWindow`s return `canBecomeKey == false` by default, which would
/// stop the summon overlay from ever receiving key events — so `esc`
/// (`cancelOperation(_:)`) would never reach `EscDismissCatcher`. Overriding this
/// lets the overlay take key focus and be dismissed with `esc`.
private final class SummonOverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
