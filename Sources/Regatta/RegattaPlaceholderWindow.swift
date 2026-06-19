import AppKit
import SwiftUI

final class RegattaPlaceholderWindowController: ReleasingWindowController {
    static let shared = RegattaPlaceholderWindowController()

    private override init() {
        super.init()
    }

    override func makeWindow() -> NSWindow {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 360),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "regatta.placeholder.title", defaultValue: "Regatta")
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.isMovableByWindowBackground = true
        window.identifier = NSUserInterfaceItemIdentifier("cmux.regatta.placeholder")
        window.center()
        window.contentView = NSHostingView(rootView: RegattaPlaceholderView())
        AppDelegate.shared?.applyWindowDecorations(to: window)
        return window
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @MainActor
    func show() {
        showManagedWindow()
    }
}

private struct RegattaPlaceholderView: View {
    var body: some View {
        VStack(spacing: 12) {
            Text(String(localized: "regatta.placeholder.title", defaultValue: "Regatta"))
                .font(.headline)
            Text(String(localized: "regatta.placeholder.body", defaultValue: "Regatta is not configured yet."))
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}
