import AppKit
import SwiftUI

// MARK: - State (visibility toggle)

final class FileExplorerState: ObservableObject {
    private static let modeKey = "rightSidebar.mode"

    @Published var isVisible: Bool {
        didSet { UserDefaults.standard.set(isVisible, forKey: "fileExplorer.isVisible") }
    }
    @Published var width: CGFloat {
        didSet { UserDefaults.standard.set(Double(width), forKey: "fileExplorer.width") }
    }

    /// Proportion of sidebar height allocated to the tab list (0.0-1.0).
    /// The file explorer gets the remaining space below.
    @Published var dividerPosition: CGFloat {
        didSet { UserDefaults.standard.set(Double(dividerPosition), forKey: "fileExplorer.dividerPosition") }
    }

    /// Whether hidden files (dotfiles) are shown in the tree.
    @Published var showHiddenFiles: Bool {
        didSet { UserDefaults.standard.set(showHiddenFiles, forKey: "fileExplorer.showHidden") }
    }

    @Published private var storedMode: RightSidebarMode

    /// Active mode for the right sidebar (file tree, search, sessions, or enabled beta modes).
    var mode: RightSidebarMode {
        get { storedMode }
        set { setMode(newValue) }
    }

    init() {
        let defaults = UserDefaults.standard
        // Show the right sidebar by default on first run. Only honor an explicit
        // stored value so a user who hid the sidebar keeps it hidden.
        self.isVisible = defaults.object(forKey: "fileExplorer.isVisible") == nil
            ? true
            : defaults.bool(forKey: "fileExplorer.isVisible")
        let storedWidth = defaults.double(forKey: "fileExplorer.width")
        self.width = storedWidth > 0 ? CGFloat(storedWidth) : 220
        let storedPosition = defaults.double(forKey: "fileExplorer.dividerPosition")
        self.dividerPosition = storedPosition > 0 ? CGFloat(storedPosition) : 0.6
        let storedShowHidden = defaults.object(forKey: "fileExplorer.showHidden")
        self.showHiddenFiles = storedShowHidden == nil ? true : defaults.bool(forKey: "fileExplorer.showHidden")
        // Default to the Regatta rail when the user has no saved mode. If the
        // stored mode string is present we honor it (clamped to availability),
        // so an existing user's choice is never overridden.
        let storedModeString = defaults.string(forKey: Self.modeKey)
        let defaultMode = Self.initialDefaultMode(defaults: defaults)
        let storedMode = storedModeString.flatMap { RightSidebarMode(rawValue: $0) } ?? defaultMode
        self.storedMode = Self.availableMode(storedMode, defaults: defaults)
        defaults.set(self.storedMode.rawValue, forKey: Self.modeKey)
    }

    /// The mode to select when the user has no previously stored choice.
    /// Prefers Regatta when its feature flag makes it available; otherwise Files.
    static func initialDefaultMode(defaults: UserDefaults) -> RightSidebarMode {
        RightSidebarMode.regatta.isAvailable(defaults: defaults) ? .regatta : .files
    }

    func refreshModeAvailability(defaults: UserDefaults = .standard) {
        setMode(storedMode, defaults: defaults)
    }

    func toggle() {
        setVisible(!isVisible)
    }

    func setVisible(_ nextValue: Bool) {
        guard isVisible != nextValue else { return }

        // Suppress both SwiftUI transactions and AppKit/Core Animation implicit layout changes.
        NSAnimationContext.beginGrouping()
        CATransaction.begin()
        defer {
            CATransaction.commit()
            NSAnimationContext.endGrouping()
        }

        NSAnimationContext.current.duration = 0
        NSAnimationContext.current.allowsImplicitAnimation = false
        CATransaction.setDisableActions(true)

        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            isVisible = nextValue
        }
    }

    private func setMode(_ mode: RightSidebarMode, defaults: UserDefaults = .standard) {
        let nextMode = Self.availableMode(mode, defaults: defaults)
        guard storedMode != nextMode else {
            if defaults.string(forKey: Self.modeKey) != nextMode.rawValue {
                defaults.set(nextMode.rawValue, forKey: Self.modeKey)
            }
            return
        }
        storedMode = nextMode
        defaults.set(nextMode.rawValue, forKey: Self.modeKey)
    }

    private static func availableMode(_ mode: RightSidebarMode, defaults: UserDefaults) -> RightSidebarMode {
        mode.isAvailable(defaults: defaults) ? mode : .files
    }
}
