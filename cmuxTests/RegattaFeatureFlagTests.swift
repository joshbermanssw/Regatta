import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class RegattaFeatureFlagTests: XCTestCase {
    private var suiteName: String!
    private var testDefaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "regatta.test.\(UUID().uuidString)"
        testDefaults = UserDefaults(suiteName: suiteName)!
        testDefaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        testDefaults.removePersistentDomain(forName: suiteName)
        testDefaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testFlagDefaultsOff() {
        let flag = RegattaFeatureFlag(defaults: testDefaults)
        XCTAssertFalse(flag.isEnabled, "RegattaFeatureFlag should default to false when no value is stored")
    }

    func testFlagReadsTrueWhenSet() {
        testDefaults.set(true, forKey: RegattaFeatureFlag.flagKey)
        let flag = RegattaFeatureFlag(defaults: testDefaults)
        XCTAssertTrue(flag.isEnabled, "RegattaFeatureFlag should return true when the key is set to true")
    }
}
