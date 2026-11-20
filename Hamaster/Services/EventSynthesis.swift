//
//  EventSynthesis.swift
//  Hamaster
//

@preconcurrency import CoreGraphics
import Foundation

/// Everything Hamaster posts back into the system. Callable from any thread.
enum EventSynthesis {
    /// Stamped into the user-data field of every event we create so our own event tap can
    /// recognise them and pass them straight through. Without it the tap would re-process
    /// its own output — blocked movement would block the touch pointer too, and a
    /// synthesised secondary click would be converted again.
    static let syntheticMarker: Int64 = 0x48414D53 // "HAMS"

    /// Posting a synthetic mouse event normally makes macOS ignore the real mouse for a
    /// quarter of a second afterwards. At touch frame rates that would suppress the physical
    /// mouse permanently, so the interval is zeroed and real events are explicitly permitted.
    nonisolated(unsafe) private static let source: CGEventSource? = {
        let source = CGEventSource(stateID: .hidSystemState)
        source?.localEventsSuppressionInterval = 0
        source?.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitLocalKeyboardEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval
        )
        return source
    }()

    // MARK: - Pointer

    /// Moves the cursor by a delta, in points. Sub-point deltas accumulate rather than being
    /// rounded away, so a slow, deliberate finger still moves the pointer.
    ///
    /// `trustOwnPosition` is set while the mouse's physical movement is being discarded. In
    /// that state the position read back from the system can't be believed: the HID layer
    /// keeps accumulating the movement we're throwing away, so its idea of where the cursor
    /// is drifts away from where the cursor actually is.
    static func moveCursor(dx: Double, dy: Double, trustOwnPosition: Bool) {
        guard let (from, to) = virtualCursor.advance(dx: dx, dy: dy, allowResync: !trustOwnPosition) else { return }

        // The heart of the "pointer jumps between two places" bug. Posting an absolute mouse
        // event moves the visible cursor but leaves the HID system's own accumulated
        // position untouched, so the next physical movement is computed from the stale one
        // and the cursor snaps back to wherever the mouse "thinks" it is. Warping writes
        // that position, and re-associating makes the mouse resume from it — so touch and
        // mouse drive one shared cursor instead of two that fight over it.
        CGWarpMouseCursorPosition(to)
        CGAssociateMouseAndMouseCursorPosition(1)

        // Holding the mouse button and steering with a finger has to send drag events, not
        // plain moves — otherwise selecting text or dragging a file with touch does nothing.
        let (type, button) = heldButton()
        guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: to, mouseButton: button) else { return }
        // Apps that read deltas rather than positions (games, 3D viewports, drawing tools)
        // need these to match the movement, or the pointer moves while they see nothing.
        event.setIntegerValueField(.mouseEventDeltaX, value: Int64((to.x - from.x).rounded()))
        event.setIntegerValueField(.mouseEventDeltaY, value: Int64((to.y - from.y).rounded()))
        event.setIntegerValueField(.eventSourceUserData, value: syntheticMarker)
        event.post(tap: .cghidEventTap)
    }

    /// Which mouse button, if any, is currently held — read from the session's own button
    /// state rather than tracked ourselves, so it stays right even for presses that never
    /// reached our tap.
    private static func heldButton() -> (CGEventType, CGMouseButton) {
        if CGEventSource.buttonState(.combinedSessionState, button: .left) {
            return (.leftMouseDragged, .left)
        }
        if CGEventSource.buttonState(.combinedSessionState, button: .right) {
            return (.rightMouseDragged, .right)
        }
        if CGEventSource.buttonState(.combinedSessionState, button: .center) {
            return (.otherMouseDragged, .center)
        }
        return (.mouseMoved, .left)
    }

    /// Re-reads the real cursor position, so the next movement continues from wherever the
    /// pointer actually is. Called when a touch gesture starts.
    static func resyncCursor() {
        virtualCursor.resync()
    }

    /// Holds the pointer at the position touch put it, and reports where that is.
    ///
    /// This is how physical movement is discarded. Swallowing the mouse-moved event is not
    /// enough on its own: the cursor's position is decided from the HID stream before any
    /// event tap runs, so by the time the event could be dropped the pointer has often
    /// already moved. Writing the position back — both onto the event and through a warp,
    /// which is also what resets the HID layer's own accumulated position — pins it for
    /// certain, and leaves the event stream intact so hover and drag states stay coherent.
    static func pinCursor(fallback: CGPoint) -> CGPoint {
        let pinned = virtualCursor.pin(fallback: fallback)
        CGWarpMouseCursorPosition(pinned)
        return pinned
    }

    private static let virtualCursor = VirtualCursor()

    // MARK: - Scrolling

    /// Where a scroll sits in its gesture. Apps use this to drive rubber-band bounce and
    /// overscroll — a scroll event with no phase is treated as a legacy notched wheel and
    /// gets none of that, which is why unphased scrolling feels dead by comparison.
    enum ScrollPhase: Equatable {
        case began, changed, ended
        case momentumBegan, momentumChanged, momentumEnded
        /// No phase at all, the way a notched wheel scrolls. Used for ⌘-scroll zooming,
        /// which isn't a gesture and shouldn't make anything rubber-band.
        case discrete

        var scrollPhaseValue: Int64 {
            switch self {
            case .began: 1   // kCGScrollPhaseBegan
            case .changed: 2 // kCGScrollPhaseChanged
            case .ended: 4   // kCGScrollPhaseEnded
            default: 0       // momentum and discrete events carry no scroll phase
            }
        }

        var momentumPhaseValue: Int64 {
            switch self {
            case .momentumBegan: 1    // kCGMomentumScrollPhaseBegin
            case .momentumChanged: 2  // kCGMomentumScrollPhaseContinue
            case .momentumEnded: 3    // kCGMomentumScrollPhaseEnd
            default: 0
            }
        }
    }

    /// Posts a scroll, in whole pixels.
    ///
    /// Whole pixels because that is all the system carries: `NSEvent.scrollingDeltaY`, which
    /// is what every modern app reads, is fed by an integer field. Fractions therefore have
    /// to be accumulated by the caller (see `ScrollAccumulator`) rather than passed down
    /// here, or slow scrolling would round to zero on every frame and do nothing at all.
    static func scroll(dx: Int32, dy: Int32, phase: ScrollPhase, flags: CGEventFlags = []) {
        guard let event = CGEvent(
            scrollWheelEvent2Source: source,
            units: .pixel,
            wheelCount: 2,
            wheel1: dy,
            wheel2: dx,
            wheel3: 0
        ) else { return }

        // Marks this as trackpad-style scrolling rather than a notched wheel.
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: phase == .discrete ? 0 : 1)
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase.scrollPhaseValue)
        event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: phase.momentumPhaseValue)
        // Keeps the legacy `NSEvent.deltaY` in step with the precise delta, for the few
        // apps that still read it.
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: Double(dy))
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: Double(dx))

        if !flags.isEmpty { event.flags = flags }
        event.setIntegerValueField(.eventSourceUserData, value: syntheticMarker)
        event.post(tap: .cghidEventTap)
    }

    // MARK: - Gestures

    /// Field numbers and subtype values for gesture events.
    ///
    /// CoreGraphics has no public API for creating magnification or smart-zoom events —
    /// the fields below are the long-established reverse-engineered layout that every
    /// third-party gesture utility on macOS uses. Because they are undocumented, pinch is
    /// user-switchable to a ⌘-scroll fallback built only from public API (see ZoomMethod);
    /// if a future macOS changes the layout, the worst case is that pinch stops responding,
    /// never that a malformed event reaches an app.
    private enum GestureField {
        // CoreGraphics imports both types as RawRepresentable structs rather than closed
        // enums, so values it doesn't publicly declare — which is all of the ones below —
        // still construct successfully. The event *type* numbers are the ones NSEvent
        // documents for gesture and smart-magnify events.
        static let eventType = CGEventType(rawValue: 29)!            // NSEvent.EventType.gesture
        static let smartMagnifyEventType = CGEventType(rawValue: 32)! // NSEvent.EventType.smartMagnify

        static let subtype = CGEventField(rawValue: 115)!
        static let phase = CGEventField(rawValue: 132)!
        static let magnification = CGEventField(rawValue: 113)!

        static let subtypeMagnify: Int64 = 4
        static let subtypeBeginGesture: Int64 = 61
        static let subtypeEndGesture: Int64 = 62

        static let phaseBegan: Int64 = 1
        static let phaseEnded: Int64 = 4
    }

    enum MagnifyPhase: Equatable {
        case began, changed, ended
    }

    /// Posts one step of a pinch. `amount` is the incremental magnification for this
    /// frame — the same units NSEvent.magnification uses, where 1.0 would be a doubling.
    static func magnify(_ amount: Double, phase: MagnifyPhase) {
        switch phase {
        case .began:
            postGesture(subtype: GestureField.subtypeBeginGesture, phase: GestureField.phaseBegan, magnification: nil)
        case .changed:
            postGesture(subtype: GestureField.subtypeMagnify, phase: nil, magnification: amount)
        case .ended:
            postGesture(subtype: GestureField.subtypeEndGesture, phase: GestureField.phaseEnded, magnification: nil)
        }
    }

    /// Double-tap-to-zoom, as sent by a trackpad's two-finger double tap.
    static func smartMagnify() {
        guard let event = CGEvent(source: source) else { return }
        event.type = GestureField.smartMagnifyEventType
        event.setIntegerValueField(.eventSourceUserData, value: syntheticMarker)
        event.post(tap: .cghidEventTap)
    }

    private static func postGesture(subtype: Int64, phase: Int64?, magnification: Double?) {
        guard let event = CGEvent(source: source) else { return }
        event.type = GestureField.eventType
        event.setIntegerValueField(GestureField.subtype, value: subtype)
        if let phase {
            event.setIntegerValueField(GestureField.phase, value: phase)
        }
        if let magnification {
            event.setDoubleValueField(GestureField.magnification, value: magnification)
        }
        event.setIntegerValueField(.eventSourceUserData, value: syntheticMarker)
        event.post(tap: .cghidEventTap)
    }
}

/// Carries the sub-pixel remainder between scroll frames.
///
/// Scroll deltas reach apps as whole pixels, so a gentle two-finger slide producing a third
/// of a pixel per frame would otherwise round away to nothing and the content would sit
/// still. Holding the remainder turns three such frames into one pixel of movement.
final class ScrollAccumulator {
    private var remainderX: Double = 0
    private var remainderY: Double = 0

    /// Adds fractional movement and returns whole pixels once there are any.
    func take(dx: Double, dy: Double) -> (dx: Int32, dy: Int32)? {
        remainderX += dx
        remainderY += dy
        let stepX = remainderX.rounded(.towardZero)
        let stepY = remainderY.rounded(.towardZero)
        remainderX -= stepX
        remainderY -= stepY
        guard stepX != 0 || stepY != 0 else { return nil }
        return (Int32(stepX), Int32(stepY))
    }

    func reset() {
        remainderX = 0
        remainderY = 0
    }
}

/// Keeps the cursor position at full precision between frames.
///
/// Reading the cursor back from the system each frame loses the fraction, so a finger
/// moving slowly enough to produce less than a point per frame would move the pointer not
/// at all. Tracking our own position fixes that, at the cost of needing to notice when
/// something else moves the cursor — the physical mouse, another app, a window activating —
/// which shows up as our position diverging from the real one.
private final class VirtualCursor: @unchecked Sendable {
    private let lock = NSLock()
    private var position: CGPoint?

    /// Forgets the tracked position so the next movement starts from the real cursor.
    func resync() {
        lock.lock()
        position = nil
        lock.unlock()
    }

    /// The position to hold the cursor at, adopting `fallback` if nothing is tracked yet —
    /// which is the case the first time the mouse is nudged before any finger has moved it.
    func pin(fallback: CGPoint) -> CGPoint {
        lock.lock()
        defer { lock.unlock() }
        if let position { return position }
        position = fallback
        return fallback
    }

    /// Returns the (previous, next) positions, or nil if the move rounds to nothing.
    func advance(dx: Double, dy: Double, allowResync: Bool) -> (CGPoint, CGPoint)? {
        let actual = CGEvent(source: nil)?.location ?? .zero

        lock.lock()
        defer { lock.unlock() }

        var base = position ?? actual
        // Only trust the system's position when it's actually authoritative. While physical
        // movement is being discarded it isn't, and resyncing to it is what made the pointer
        // teleport to wherever the mouse had been pushed.
        if allowResync, hypot(base.x - actual.x, base.y - actual.y) > 2.0 {
            base = actual
        }
        let target = DisplayGeometry.clamp(CGPoint(x: base.x + dx, y: base.y + dy))
        position = target

        // Nothing to post if the pointer wouldn't visibly move; the fraction is kept.
        guard abs(target.x - base.x) >= 0.5 || abs(target.y - base.y) >= 0.5 else { return nil }
        return (base, target)
    }
}

/// Cached bounds of the display arrangement, so cursor movement can be clamped from the
/// multitouch thread without touching NSScreen (which is main-thread only).
///
/// Clamping to the union rather than the main display matters on a multi-monitor desk: the
/// original single-display clamp would have pinned the touch pointer inside one screen.
private enum DisplayGeometry {
    private static let lock = NSLock()
    /// Access is serialized by `lock`; `nonisolated(unsafe)` documents that synchronization
    /// boundary for Swift's concurrency checker.
    nonisolated(unsafe) private static var cachedBounds: CGRect = .null
    nonisolated(unsafe) private static var cachedAt: TimeInterval = -.infinity

    static func clamp(_ point: CGPoint) -> CGPoint {
        let bounds = currentBounds()
        guard !bounds.isNull else { return point }
        return CGPoint(
            x: min(max(point.x, bounds.minX), bounds.maxX - 1),
            y: min(max(point.y, bounds.minY), bounds.maxY - 1)
        )
    }

    private static func currentBounds() -> CGRect {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        defer { lock.unlock() }
        // Re-read periodically so plugging in a display is picked up without needing a
        // reconfiguration callback on a thread that has no run loop of its own.
        if now - cachedAt < 2.0 { return cachedBounds }

        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return cachedBounds }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else { return cachedBounds }

        cachedBounds = displays.prefix(Int(count)).reduce(CGRect.null) { $0.union(CGDisplayBounds($1)) }
        cachedAt = now
        return cachedBounds
    }
}
