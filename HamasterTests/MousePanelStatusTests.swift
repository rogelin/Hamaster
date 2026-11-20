import XCTest
@testable import Hamaster

final class MousePanelStatusTests: XCTestCase {
    func testUnavailableSurfaceTakesPrecedenceOverSavedEnabledState() {
        for enabled in [false, true] {
            XCTAssertEqual(MousePanelStatus.resolve(isEnabled: enabled, hasTouchSurface: false,
                                                    hasAccessibility: true, isActive: true), .unavailable)
        }
    }

    func testPausedOrBlockedDeviceNeverClaimsToBeActive() {
        XCTAssertEqual(MousePanelStatus.resolve(isEnabled: false, hasTouchSurface: true,
                                                hasAccessibility: true, isActive: true), .paused)
        XCTAssertEqual(MousePanelStatus.resolve(isEnabled: true, hasTouchSurface: true,
                                                hasAccessibility: false, isActive: true), .needsAccess)
    }

    func testReadyDeviceReportsItsActualStreamState() {
        XCTAssertEqual(MousePanelStatus.resolve(isEnabled: true, hasTouchSurface: true,
                                                hasAccessibility: true, isActive: false), .idle)
        XCTAssertEqual(MousePanelStatus.resolve(isEnabled: true, hasTouchSurface: true,
                                                hasAccessibility: true, isActive: true), .active)
    }
}
