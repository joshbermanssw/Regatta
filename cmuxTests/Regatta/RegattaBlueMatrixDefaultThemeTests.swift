import Testing
import CmuxTerminalCore

@Suite("Regatta Blue Matrix default theme")
struct RegattaBlueMatrixDefaultThemeTests {
    @Test("default dark theme name is Blue Matrix")
    func defaultDarkThemeNameIsBlueMatrix() {
        #expect(GhosttyConfig.cmuxDefaultDarkThemeName == "Blue Matrix")
    }

    @Test("default dark theme name resolves for dark color scheme")
    func defaultThemeNameForDark() {
        let name = GhosttyConfig.cmuxDefaultThemeName(preferredColorScheme: .dark)
        #expect(name == "Blue Matrix")
    }

    @Test("default light theme name is unchanged")
    func defaultLightThemeNameUnchanged() {
        let name = GhosttyConfig.cmuxDefaultThemeName(preferredColorScheme: .light)
        #expect(name == "Apple System Colors Light")
    }

    @Test("Blue Matrix fallback config contains correct background color")
    func blueMatrixFallbackBackground() {
        let contents = GhosttyConfig.cmuxDefaultThemeConfigContents(
            preferredColorScheme: .dark,
            environment: [:],
            bundleResourceURL: nil
        )
        #expect(contents.contains("background = #101116"))
    }

    @Test("Blue Matrix fallback config contains correct foreground color")
    func blueMatrixFallbackForeground() {
        let contents = GhosttyConfig.cmuxDefaultThemeConfigContents(
            preferredColorScheme: .dark,
            environment: [:],
            bundleResourceURL: nil
        )
        #expect(contents.contains("foreground = #00a2ff"))
    }

    @Test("Blue Matrix fallback config contains correct cursor color")
    func blueMatrixFallbackCursor() {
        let contents = GhosttyConfig.cmuxDefaultThemeConfigContents(
            preferredColorScheme: .dark,
            environment: [:],
            bundleResourceURL: nil
        )
        #expect(contents.contains("cursor-color = #76ff9f"))
    }
}
