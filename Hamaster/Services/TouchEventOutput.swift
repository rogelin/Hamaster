//
//  TouchEventOutput.swift
//  Hamaster
//

import CoreGraphics
import Foundation

/// The side effects produced by touch recognition. Keeping this boundary small lets the
/// recognizer be exercised with recorded contact frames without moving the real cursor or
/// opening Mission Control during a test run.
protocol TouchEventOutput: Sendable {
    func resyncCursor()
    func moveCursor(dx: Double, dy: Double, trustOwnPosition: Bool)
    func scroll(dx: Int32, dy: Int32, phase: EventSynthesis.ScrollPhase, flags: CGEventFlags)
    func magnify(_ amount: Double, phase: EventSynthesis.MagnifyPhase)
    func smartMagnify()
    func missionControl()
    func appExpose()
}

struct SystemTouchEventOutput: TouchEventOutput {
    func resyncCursor() {
        EventSynthesis.resyncCursor()
    }

    func moveCursor(dx: Double, dy: Double, trustOwnPosition: Bool) {
        EventSynthesis.moveCursor(dx: dx, dy: dy, trustOwnPosition: trustOwnPosition)
    }

    func scroll(
        dx: Int32,
        dy: Int32,
        phase: EventSynthesis.ScrollPhase,
        flags: CGEventFlags = []
    ) {
        EventSynthesis.scroll(dx: dx, dy: dy, phase: phase, flags: flags)
    }

    func magnify(_ amount: Double, phase: EventSynthesis.MagnifyPhase) {
        EventSynthesis.magnify(amount, phase: phase)
    }

    func smartMagnify() {
        EventSynthesis.smartMagnify()
    }

    func missionControl() {
        SystemActionBridge.missionControl()
    }

    func appExpose() {
        SystemActionBridge.appExpose()
    }
}

protocol PhysicalMovementTracking: Sendable {
    func hasRecentPhysicalMovement(deviceKey: String, within window: TimeInterval) -> Bool
}

extension PhysicalMovementTracking {
    func hasRecentPhysicalMovement(deviceKey: String) -> Bool {
        hasRecentPhysicalMovement(deviceKey: deviceKey, within: 0.12)
    }
}

