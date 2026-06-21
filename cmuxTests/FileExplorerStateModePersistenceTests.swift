import Foundation
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class FileExplorerStateModePersistenceTests: XCTestCase {
    private let modeKey = "rightSidebar.mode"
    private let feedEnabledKey = RightSidebarBetaFeatureSettings.feedEnabledKey
    private let dockEnabledKey = RightSidebarBetaFeatureSettings.dockEnabledKey
    private let regattaEnabledKey = RegattaFeatureFlag.flagKey
    private let visibilityKey = "fileExplorer.isVisible"

    func testDefaultModeIsRegattaWhenNoStoredModeAndFlagOn() {
        withSavedRightSidebarModeDefaults {
            let defaults = UserDefaults.standard
            defaults.removeObject(forKey: modeKey)
            defaults.set(true, forKey: regattaEnabledKey)

            let state = FileExplorerState()

            XCTAssertEqual(state.mode, .regatta)
            XCTAssertEqual(defaults.string(forKey: modeKey), RightSidebarMode.regatta.rawValue)
        }
    }

    func testDefaultModeFallsBackToFilesWhenRegattaDisabled() {
        withSavedRightSidebarModeDefaults {
            let defaults = UserDefaults.standard
            defaults.removeObject(forKey: modeKey)
            defaults.set(false, forKey: regattaEnabledKey)

            let state = FileExplorerState()

            XCTAssertEqual(state.mode, .files)
            XCTAssertEqual(defaults.string(forKey: modeKey), RightSidebarMode.files.rawValue)
        }
    }

    func testExistingStoredModeIsNotOverriddenByRegattaDefault() {
        withSavedRightSidebarModeDefaults {
            let defaults = UserDefaults.standard
            defaults.set(RightSidebarMode.find.rawValue, forKey: modeKey)
            defaults.set(true, forKey: regattaEnabledKey)

            let state = FileExplorerState()

            XCTAssertEqual(state.mode, .find, "An existing user's saved mode must not be replaced by the Regatta default")
            XCTAssertEqual(defaults.string(forKey: modeKey), RightSidebarMode.find.rawValue)
        }
    }

    func testRightSidebarVisibleByDefaultWhenUnset() {
        withSavedRightSidebarModeDefaults {
            let defaults = UserDefaults.standard
            defaults.removeObject(forKey: visibilityKey)

            let state = FileExplorerState()

            XCTAssertTrue(state.isVisible, "Right sidebar should be visible by default on first run")
        }
    }

    func testRightSidebarRespectsExplicitHiddenChoice() {
        withSavedRightSidebarModeDefaults {
            let defaults = UserDefaults.standard
            defaults.set(false, forKey: visibilityKey)

            let state = FileExplorerState()

            XCTAssertFalse(state.isVisible, "A user who hid the sidebar should keep it hidden")
        }
    }

    func testDisabledFeedStoredModeFallsBackToFiles() {
        withSavedRightSidebarModeDefaults {
            let defaults = UserDefaults.standard
            defaults.set(RightSidebarMode.feed.rawValue, forKey: modeKey)
            defaults.set(false, forKey: feedEnabledKey)

            let state = FileExplorerState()

            XCTAssertEqual(state.mode, .files)
            XCTAssertEqual(defaults.string(forKey: modeKey), RightSidebarMode.files.rawValue)
        }
    }

    func testEnabledFeedStoredModeSurvives() {
        withSavedRightSidebarModeDefaults {
            let defaults = UserDefaults.standard
            defaults.set(RightSidebarMode.feed.rawValue, forKey: modeKey)
            defaults.set(true, forKey: feedEnabledKey)

            let state = FileExplorerState()

            XCTAssertEqual(state.mode, .feed)
            XCTAssertEqual(defaults.string(forKey: modeKey), RightSidebarMode.feed.rawValue)
        }
    }

    func testModeSetterClampsUnavailableBetaModes() {
        withSavedRightSidebarModeDefaults {
            let defaults = UserDefaults.standard
            defaults.set(false, forKey: feedEnabledKey)
            defaults.set(false, forKey: dockEnabledKey)
            let state = FileExplorerState()

            state.mode = .feed
            XCTAssertEqual(state.mode, .files)
            XCTAssertEqual(defaults.string(forKey: modeKey), RightSidebarMode.files.rawValue)

            defaults.set(true, forKey: dockEnabledKey)
            state.mode = .dock
            XCTAssertEqual(state.mode, .dock)
            XCTAssertEqual(defaults.string(forKey: modeKey), RightSidebarMode.dock.rawValue)

            defaults.set(false, forKey: dockEnabledKey)
            state.refreshModeAvailability()
            XCTAssertEqual(state.mode, .files)
            XCTAssertEqual(defaults.string(forKey: modeKey), RightSidebarMode.files.rawValue)
        }
    }

    func testCLIArgumentNormalizerMapsVaultAndSessionsToSessions() {
        XCTAssertEqual(RightSidebarMode.from(cliArgument: "files"), .files)
        XCTAssertEqual(RightSidebarMode.from(cliArgument: "find"), .find)
        XCTAssertEqual(RightSidebarMode.from(cliArgument: "vault"), .sessions)
        XCTAssertEqual(RightSidebarMode.from(cliArgument: "sessions"), .sessions)
        XCTAssertEqual(RightSidebarMode.from(cliArgument: "feed"), .feed)
        XCTAssertEqual(RightSidebarMode.from(cliArgument: "dock"), .dock)
        XCTAssertEqual(RightSidebarMode.from(cliArgument: " Vault "), .sessions)
        XCTAssertNil(RightSidebarMode.from(cliArgument: "unknown"))
    }

    private func withSavedRightSidebarModeDefaults(_ body: () -> Void) {
        let defaults = UserDefaults.standard
        let previousMode = defaults.object(forKey: modeKey)
        let previousFeedEnabled = defaults.object(forKey: feedEnabledKey)
        let previousDockEnabled = defaults.object(forKey: dockEnabledKey)
        let previousRegattaEnabled = defaults.object(forKey: regattaEnabledKey)
        let previousVisibility = defaults.object(forKey: visibilityKey)
        defer {
            restore(previousMode, forKey: modeKey)
            restore(previousFeedEnabled, forKey: feedEnabledKey)
            restore(previousDockEnabled, forKey: dockEnabledKey)
            restore(previousRegattaEnabled, forKey: regattaEnabledKey)
            restore(previousVisibility, forKey: visibilityKey)
        }
        body()
    }

    private func restore(_ value: Any?, forKey key: String) {
        let defaults = UserDefaults.standard
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}
