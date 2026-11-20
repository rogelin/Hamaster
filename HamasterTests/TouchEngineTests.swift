import CoreGraphics
import XCTest
@testable import Hamaster

final class TouchEngineTests: XCTestCase {
    func testPinchWorksWhilePointerModeIsOff() {
        let harness = Harness()
        harness.settings.touchpadEnabled = false
        harness.settings.pinchToZoom = true
        harness.applySettings()

        harness.engine.process(harness.pair(leftX: 0.40, rightX: 0.60, frame: 1))
        harness.engine.process(harness.pair(leftX: 0.38, rightX: 0.62, frame: 2))
        harness.engine.process(harness.pair(leftX: 0.36, rightX: 0.64, frame: 3))
        harness.engine.process([])

        XCTAssertEqual(harness.output.magnifyPhases, [.began, .changed, .ended])
        XCTAssertTrue(harness.output.cursorMoves.isEmpty)
    }

    func testTwoFingerScrollIsLeftToMacOSWhenPointerModeIsOff() {
        let harness = Harness()
        harness.settings.touchpadEnabled = false
        harness.settings.pinchToZoom = false
        harness.applySettings()

        harness.engine.process(harness.pair(y: 0.40, frame: 1))
        harness.engine.process(harness.pair(y: 0.44, frame: 2))
        harness.engine.process(harness.pair(y: 0.48, frame: 3))
        harness.engine.process([])

        XCTAssertTrue(harness.output.scrolls.isEmpty)
    }

    func testMasterSwitchPreventsTouchOutput() {
        let harness = Harness(enabled: false)

        harness.engine.process([harness.contact(id: 1, x: 0.5, y: 0.5, frame: 1)])
        harness.engine.process([harness.contact(id: 1, x: 0.6, y: 0.5, frame: 2)])
        harness.engine.process([])

        XCTAssertTrue(harness.output.cursorMoves.isEmpty)
        XCTAssertTrue(harness.output.scrolls.isEmpty)
        XCTAssertTrue(harness.output.magnifyPhases.isEmpty)
    }
}

private final class Harness {
    let output = RecordingTouchOutput()
    let snapshot = SettingsSnapshot()
    let bridge = InputBridge()
    var settings: MouseSettings
    let engine: TouchEngine

    init(enabled: Bool = true) {
        settings = MouseSettings(deviceKey: "mouse", displayName: "Magic Mouse")
        settings.isEnabled = enabled
        snapshot.update(["mouse": settings])
        engine = TouchEngine(
            deviceKey: "mouse",
            bridge: bridge,
            tracker: NoPhysicalMovement(),
            snapshot: snapshot,
            surfaceWidthMM: 51.5,
            aspectRatio: 1.76,
            output: output
        )
    }

    func applySettings() {
        snapshot.update(["mouse": settings])
    }

    func pair(leftX: Double = 0.4, rightX: Double = 0.6, y: Double = 0.5, frame: Int32) -> [TouchContact] {
        [
            contact(id: 1, x: leftX, y: y, frame: frame),
            contact(id: 2, x: rightX, y: y, frame: frame),
        ]
    }

    func contact(id: Int32, x: Double, y: Double, frame: Int32) -> TouchContact {
        TouchContact(
            identifier: id,
            frame: frame,
            timestamp: Double(frame) / 120,
            state: .touching,
            normalizedPosition: TouchVector(x: x, y: y),
            normalizedVelocity: TouchVector(x: 0, y: 0),
            majorAxis: 0,
            minorAxis: 0,
            angle: 0,
            totalCapacitance: 0,
            pressure: 0,
            density: 0
        )
    }
}

private struct NoPhysicalMovement: PhysicalMovementTracking {
    func hasRecentPhysicalMovement(deviceKey: String, within window: TimeInterval) -> Bool {
        false
    }
}

private final class RecordingTouchOutput: @unchecked Sendable, TouchEventOutput {
    private(set) var cursorMoves: [(Double, Double)] = []
    private(set) var scrolls: [(Int32, Int32, EventSynthesis.ScrollPhase)] = []
    private(set) var magnifyPhases: [EventSynthesis.MagnifyPhase] = []

    func resyncCursor() {}

    func moveCursor(dx: Double, dy: Double, trustOwnPosition: Bool) {
        cursorMoves.append((dx, dy))
    }

    func scroll(dx: Int32, dy: Int32, phase: EventSynthesis.ScrollPhase, flags: CGEventFlags) {
        scrolls.append((dx, dy, phase))
    }

    func magnify(_ amount: Double, phase: EventSynthesis.MagnifyPhase) {
        magnifyPhases.append(phase)
    }

    func smartMagnify() {}
    func missionControl() {}
    func appExpose() {}
}

