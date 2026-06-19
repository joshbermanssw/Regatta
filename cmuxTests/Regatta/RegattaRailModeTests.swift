import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("RegattaRailMode availability")
struct RegattaRailModeTests {
    // MARK: isAvailable

    @Test("regatta mode is unavailable when flag is off")
    func regattaUnavailableWhenFlagOff() {
        #expect(
            RightSidebarMode.regatta.isAvailable(
                feedEnabled: false,
                dockEnabled: false,
                regattaEnabled: false
            ) == false
        )
    }

    @Test("regatta mode is available when flag is on")
    func regattaAvailableWhenFlagOn() {
        #expect(
            RightSidebarMode.regatta.isAvailable(
                feedEnabled: false,
                dockEnabled: false,
                regattaEnabled: true
            ) == true
        )
    }

    @Test("regatta availability is independent of feedEnabled and dockEnabled")
    func regattaAvailabilityIndependentOfOtherFlags() {
        #expect(
            RightSidebarMode.regatta.isAvailable(
                feedEnabled: true,
                dockEnabled: true,
                regattaEnabled: false
            ) == false
        )
        #expect(
            RightSidebarMode.regatta.isAvailable(
                feedEnabled: true,
                dockEnabled: true,
                regattaEnabled: true
            ) == true
        )
    }

    // MARK: availableModes

    @Test("availableModes excludes .regatta when flag is off")
    func availableModesExcludesRegattaWhenOff() {
        let modes = RightSidebarMode.availableModes(
            feedEnabled: false,
            dockEnabled: false,
            regattaEnabled: false
        )
        #expect(!modes.contains(.regatta))
    }

    @Test("availableModes includes .regatta when flag is on")
    func availableModesIncludesRegattaWhenOn() {
        let modes = RightSidebarMode.availableModes(
            feedEnabled: false,
            dockEnabled: false,
            regattaEnabled: true
        )
        #expect(modes.contains(.regatta))
    }

    @Test("availableModes includes core modes regardless of regattaEnabled")
    func coreModesAlwaysPresent() {
        let modesOff = RightSidebarMode.availableModes(
            feedEnabled: false,
            dockEnabled: false,
            regattaEnabled: false
        )
        #expect(modesOff.contains(.files))
        #expect(modesOff.contains(.find))
        #expect(modesOff.contains(.sessions))

        let modesOn = RightSidebarMode.availableModes(
            feedEnabled: false,
            dockEnabled: false,
            regattaEnabled: true
        )
        #expect(modesOn.contains(.files))
        #expect(modesOn.contains(.find))
        #expect(modesOn.contains(.sessions))
    }
}
