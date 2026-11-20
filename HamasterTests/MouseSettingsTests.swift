import XCTest
@testable import Hamaster

final class MouseSettingsTests: XCTestCase {
    func testLegacyTouchpadFlagMigratesToMasterSwitch() throws {
        let data = Data(#"{"deviceKey":"mouse","displayName":"Magic Mouse","touchpadEnabled":true}"#.utf8)
        let settings = try JSONDecoder().decode(MouseSettings.self, from: data)

        XCTAssertTrue(settings.isEnabled)
        XCTAssertTrue(settings.touchpadEnabled)
        XCTAssertTrue(settings.pointerActive)
    }

    func testMissingPreferencesReceiveDefaultsInsteadOfInvalidatingRecord() throws {
        let data = Data(#"{"deviceKey":"mouse"}"#.utf8)
        let settings = try JSONDecoder().decode(MouseSettings.self, from: data)

        XCTAssertEqual(settings.displayName, "Magic Mouse")
        XCTAssertFalse(settings.isEnabled)
        XCTAssertTrue(settings.touchpadEnabled)
        XCTAssertEqual(settings.sensitivity, .three)
        XCTAssertTrue(settings.pinchToZoom)
    }

    func testGesturesCanRunWithoutPointerMode() {
        var settings = MouseSettings(deviceKey: "mouse", displayName: "Magic Mouse")
        settings.isEnabled = true
        settings.touchpadEnabled = false

        XCTAssertFalse(settings.pointerActive)
        XCTAssertTrue(settings.pinchToZoomActive)
        XCTAssertTrue(settings.threeFingerSwipesActive)
        XCTAssertTrue(settings.needsTouchStream)
    }

    func testMasterSwitchPausesEveryEffectiveFeature() {
        var settings = MouseSettings(deviceKey: "mouse", displayName: "Magic Mouse")
        settings.isEnabled = false

        XCTAssertFalse(settings.pointerActive)
        XCTAssertFalse(settings.pinchToZoomActive)
        XCTAssertFalse(settings.secondaryClickActive)
        XCTAssertFalse(settings.needsTouchStream)
        XCTAssertFalse(settings.needsEventTap)
    }
}

