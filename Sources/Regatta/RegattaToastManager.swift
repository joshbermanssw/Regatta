import AppKit
import Observation
import SwiftUI

/// A `@MainActor` seam that hosts the bottom-right toast overlay in a borderless,
/// click-through window pinned over the active main window's content frame.
///
/// ## Why a window, not an in-`ContentView` overlay
/// Mirrors ``RegattaSummonManager``: the overlay must show app-wide regardless of
/// which Regatta surface triggered it, and must stay entirely off the
/// typing-latency hot paths (`hitTest`, `TabItemView`, `forceRefresh`) in the
/// 16k-line `ContentView` god file. A separately-hosted window pinned to the host
/// content frame covers the work area without touching those paths or burying the
/// toasts inside the narrow Regatta rail.
///
/// ## Present-on-demand
/// ``start()`` observes ``RegattaToastCenter`` and lazily shows the overlay window
/// over the current key/main window the moment a toast appears, hiding it again
/// when the queue empties. This needs no hook into the AppDelegate window-creation
/// flow — the same on-demand strategy ``RegattaSummonManager`` uses.
///
/// ## Click-through & focus
/// The window never becomes key (so it never steals focus or typing) and its
/// hosting view passes mouse events through every transparent region — only the
/// toast cards intercept clicks. The work area beneath stays fully interactive.
@MainActor
final class RegattaToastManager {

    /// The shared app-lifetime instance.
    static let shared = RegattaToastManager()

    /// The toast center the overlay renders and observes.
    private let center: RegattaToastCenter

    /// The borderless overlay window, created lazily on first presentation.
    private var overlayWindow: NSWindow?

    /// The window the overlay is currently parented to, tracked so it can be
    /// re-parented when the front window changes.
    private weak var hostWindow: NSWindow?

    /// Observer for the host window's frame changes.
    private var frameObserver: NSObjectProtocol?

    /// Whether ``start()`` has armed the observation loop.
    private var started = false

    /// Creates a toast manager.
    ///
    /// - Parameter center: The toast center to render (defaults to the shared
    ///   instance every Regatta action emits into).
    init(center: RegattaToastCenter = .shared) {
        self.center = center
    }

    /// Begins observing the toast center and presenting the overlay on demand.
    /// Idempotent — only the first call arms the loop.
    func start() {
        guard !started else { return }
        started = true
        observeToasts()
    }

    // MARK: - Observation loop

    /// Reads ``RegattaToastCenter/toasts`` inside `withObservationTracking` so this
    /// re-runs on every change, syncing window presentation to the queue state.
    private func observeToasts() {
        let hasToasts = withObservationTracking {
            !center.toasts.isEmpty
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeToasts() }
        }
        syncPresentation(hasToasts: hasToasts)
    }

    private func syncPresentation(hasToasts: Bool) {
        if hasToasts {
            present()
        } else {
            hide()
        }
    }

    // MARK: - Window plumbing

    private func present() {
        guard let host = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible }) else {
            return
        }
        let window = overlayWindow ?? makeOverlayWindow()
        overlayWindow = window

        if hostWindow !== host {
            detachFromHost()
            host.addChildWindow(window, ordered: .above)
            hostWindow = host
            installFrameObserver(on: host)
        }
        reposition()
        window.orderFront(nil)
    }

    private func hide() {
        overlayWindow?.orderOut(nil)
    }

    private func reposition() {
        guard let window = overlayWindow, let host = hostWindow else { return }
        window.setFrame(host.contentRect(forFrameRect: host.frame), display: true)
    }

    private func installFrameObserver(on host: NSWindow) {
        frameObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification,
            object: host,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reposition() }
        }
    }

    private func detachFromHost() {
        if let frameObserver {
            NotificationCenter.default.removeObserver(frameObserver)
            self.frameObserver = nil
        }
        if let window = overlayWindow, let hostWindow {
            hostWindow.removeChildWindow(window)
        }
        hostWindow = nil
    }

    private func makeOverlayWindow() -> NSWindow {
        let window = ToastOverlayWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 600),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .normal
        window.ignoresMouseEvents = false
        window.identifier = NSUserInterfaceItemIdentifier("cmux.regatta.toast")
        let hosting = ClickThroughHostingView(rootView: RegattaToastOverlayView(center: center))
        hosting.autoresizingMask = [.width, .height]
        window.contentView = hosting
        return window
    }
}

/// A borderless overlay window that never becomes key or main, so the toast stack
/// never steals focus or interrupts typing in the work area beneath it.
private final class ToastOverlayWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// An `NSHostingView` that passes mouse events through every transparent region,
/// so only the toast cards themselves intercept clicks and the work area beneath
/// the overlay stays interactive.
private final class ClickThroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? {
        // SwiftUI hosting views return `self` for empty/transparent regions; map
        // that back to `nil` so the click falls through to the window below. A hit
        // on an actual interactive subview (a toast's dismiss button) returns it.
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}
