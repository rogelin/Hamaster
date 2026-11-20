//
//  TouchEngine.swift
//  Hamaster
//

import CoreGraphics
import Foundation

/// Turns one Magic Mouse's contact frames into pointer movement, scrolling and gestures.
///
/// Runs entirely on the private framework's callback thread — it never touches the main
/// actor, reads its configuration from a lock-protected snapshot, and talks to the event
/// tap only through `InputBridge`. One instance per physical mouse.
///
/// Two ideas do most of the work here. Finger count is *sticky*: fingers never land or lift
/// together, so a raw count flickers between two and three during any three-finger gesture,
/// and reacting to every flicker is what makes such gestures unrecognisable. And movement is
/// *accumulated* from frame to frame rather than measured against a fixed anchor, so a
/// finger joining or leaving mid-gesture shifts nothing.
final class TouchEngine: @unchecked Sendable {
    private let deviceKey: String
    private let bridge: InputBridge
    private let tracker: any PhysicalMovementTracking
    private let snapshot: SettingsSnapshot
    private let output: any TouchEventOutput
    private let momentum: MomentumScroller

    /// Physical width of the touch surface, in millimetres. Movement is computed in real
    /// finger travel rather than normalised units, which is what lets the acceleration curve
    /// be expressed the way a trackpad's is — points of pointer movement per millimetre.
    private let surfaceWidthMM: Double
    /// How much taller the surface is than it is wide.
    private let aspect: Double

    init(
        deviceKey: String,
        bridge: InputBridge,
        tracker: any PhysicalMovementTracking,
        snapshot: SettingsSnapshot,
        surfaceWidthMM: Double,
        aspectRatio: Double,
        output: any TouchEventOutput = SystemTouchEventOutput()
    ) {
        self.deviceKey = deviceKey
        self.bridge = bridge
        self.tracker = tracker
        self.snapshot = snapshot
        self.surfaceWidthMM = surfaceWidthMM
        self.aspect = aspectRatio
        self.output = output
        self.momentum = MomentumScroller(output: output)
    }

    // MARK: - Tuning

    /// Pointer gain at a crawl and at speed, in points per millimetre of finger travel.
    /// These bracket what the built-in trackpad does at its default speed: precise enough
    /// to hit a checkbox, fast enough to cross a 5K display in one flick.
    private let slowPointsPerMM = 3.0
    private let fastPointsPerMM = 24.0
    /// Finger speed, in mm/s, at which the pointer curve reaches full gain.
    private let pointerAccelerationReference = 320.0

    /// The same idea for scrolling, in scrolled points per millimetre of finger travel.
    private let slowScrollPointsPerMM = 4.0
    private let fastScrollPointsPerMM = 24.0
    private let scrollAccelerationReference = 260.0

    /// Converts a change in finger separation into magnification units, where 1.0 is a
    /// doubling — matching what NSEvent.magnification reports for a trackpad.
    private let pinchScale = 2.2

    // Distances below are in surface widths after aspect correction, so 1.0 is the full
    // width of the touch strip — about 51mm on a Magic Mouse.

    /// Roughly 1mm of movement before a two-finger gesture commits to scrolling or pinching.
    private let twoFingerCommitThreshold = 0.018
    /// Roughly 7mm of vertical travel before a three-finger swipe fires.
    private let threeFingerSwipeThreshold = 0.14
    /// A swipe must be clearly more vertical than horizontal, so drifting sideways across
    /// the surface with three fingers resting on it doesn't trigger Mission Control.
    private let threeFingerVerticalDominance = 1.3

    /// How long a reduced finger count must persist before it's believed.
    private let fingerCountSettleDelay = 0.09

    /// Sub-point movement below this is dropped in Smoothed mode.
    private let smoothedDeadZone = 0.10

    private let tapMaxDuration = 0.25
    private let tapMaxTravel = 0.035
    private let doubleTapMaxGap = 0.45

    // MARK: - State

    private enum Mode {
        case idle
        case pointer
        /// Two fingers down, not yet decided between scrolling and pinching.
        case twoFingerUndecided
        case scroll
        /// Two fingers, resolved to scrolling but handled by macOS rather than by us
        /// (touch-as-trackpad is off), so its scroll events must be left alone.
        case systemScroll
        case pinch
        case threeFinger
    }

    private var mode: Mode = .idle

    // Sticky finger count
    private var stickyCount = 0
    private var reducedCountSince: TimeInterval?

    // Pointer
    private var pointerContactID: Int32?
    private var pointerAnchor: TouchVector?
    private let pointerFilter = OneEuroPointFilter()
    private var filterMode: MovementMode?
    private var lastPointerTimestamp: Double = 0

    // Multi-finger movement, accumulated frame to frame
    private var trackedIDs: [Int32] = []
    private var lastCentroid: TouchVector?
    private var centroidTravel: Double = 0
    private var separationTravel: Double = 0
    private var separationAnchor: Double = 0
    private var lastSeparation: Double = 0

    // Scroll
    private let scrollAccumulator = ScrollAccumulator()
    private var scrollPhaseStarted = false
    private var scrollVelocityX: Double = 0
    private var scrollVelocityY: Double = 0
    private var lastScrollTimestamp: Double = 0
    private var zoomRemainder: Double = 0

    // Three fingers
    private var swipeAccumulatedY: Double = 0
    private var swipeAccumulatedX: Double = 0
    private var swipeFired = false

    // Tap detection
    private var gestureStartUptime: TimeInterval = 0
    private var gestureStartCentroid: TouchVector?
    private var gestureMaxTravel: Double = 0
    private var gesturePeakContacts = 0
    private var lastTapUptime: TimeInterval = -.infinity

    // MARK: - Entry point

    func process(_ contacts: [TouchContact]) {
        let settings = snapshot.settings(for: deviceKey)
        let touching = contacts
            .filter { $0.state == .touching || $0.state == .making }
            .sorted { $0.identifier < $1.identifier }

        let timestamp = touching.first?.timestamp ?? ProcessInfo.processInfo.systemUptime
        let now = ProcessInfo.processInfo.systemUptime
        let count = stickyFingerCount(raw: touching.count, now: now)

        // New fingers on the surface stop a coasting scroll, exactly as they do on a trackpad.
        if touching.count > 0, mode == .idle {
            momentum.cancel()
            if !settings.blocksPhysicalMovement {
                // Pick up wherever the pointer actually is. Skipped while movement is being
                // discarded, because then the system's position is the one that has drifted.
                output.resyncCursor()
            }
        }

        updateGestureTracking(touching, now: now)
        bridge.setContactCount(touching.count, for: deviceKey)

        switch count {
        case 0:
            endGesture(fullyLifted: true)
        case 1:
            enter(.pointer)
            if let contact = touching.first {
                handlePointer(contact, timestamp: timestamp, settings: settings)
            }
        case 2:
            handleTwoFingers(touching, timestamp: timestamp, settings: settings)
        default:
            enter(.threeFinger)
            handleThreeFingers(touching, settings: settings)
        }

        bridge.setScrollSuppressed(shouldSuppressSystemScroll(settings: settings, count: touching.count), for: deviceKey)
    }

    /// Called when the engine is torn down, so a half-finished gesture can't leave the app
    /// under the cursor stuck mid-pinch or mid-scroll.
    func shutDown() {
        momentum.cancel()
        endGesture(fullyLifted: false)
        bridge.forget(deviceKey)
    }

    // MARK: - Sticky finger count

    /// Raw contact counts flicker: a third finger lands a frame late, or one contact drops
    /// out for a frame as it rolls. The count is therefore allowed to rise instantly but
    /// only to fall after it has stayed down for a moment — except to zero, which is
    /// unambiguous. Without this, three-finger swipes are barely recognisable.
    private func stickyFingerCount(raw: Int, now: TimeInterval) -> Int {
        if raw == 0 {
            stickyCount = 0
            reducedCountSince = nil
            return 0
        }
        if raw >= stickyCount {
            stickyCount = raw
            reducedCountSince = nil
            return stickyCount
        }
        let since = reducedCountSince ?? now
        reducedCountSince = since
        if now - since >= fingerCountSettleDelay {
            stickyCount = raw
            reducedCountSince = nil
        }
        return stickyCount
    }

    // MARK: - Scroll suppression policy

    /// macOS derives its own scroll events from the very same fingers. They have to be
    /// dropped whenever we're interpreting those fingers ourselves — but only then, so that
    /// with touch-as-trackpad off the mouse keeps scrolling exactly as it does normally.
    ///
    private func shouldSuppressSystemScroll(settings: MouseSettings, count: Int) -> Bool {
        if settings.pointerActive { return count > 0 }
        switch mode {
        case .pinch: return true
        case .threeFinger: return settings.threeFingerSwipesActive
        default: return false
        }
    }

    // MARK: - Mode transitions

    private func enter(_ newMode: Mode) {
        guard mode != newMode else { return }
        closeOutMode(fullyLifted: false)
        mode = newMode
    }

    private func endGesture(fullyLifted: Bool) {
        guard mode != .idle else { return }
        closeOutMode(fullyLifted: fullyLifted)
        mode = .idle
    }

    /// Finishes whatever the current mode was mid-way through, then clears its state.
    private func closeOutMode(fullyLifted: Bool) {
        switch mode {
        case .pinch:
            output.magnify(0, phase: .ended)
        case .scroll:
            if scrollPhaseStarted {
                output.scroll(dx: 0, dy: 0, phase: .ended, flags: [])
            }
            scrollAccumulator.reset()
            // Only a real lift throws the content; changing finger count mid-gesture is the
            // user reaching for something else, and coasting then would feel accidental.
            if fullyLifted, scrollPhaseStarted {
                momentum.launch(velocityX: scrollVelocityX, velocityY: scrollVelocityY)
            }
        default:
            break
        }

        pointerContactID = nil
        pointerAnchor = nil
        pointerFilter.reset()
        trackedIDs = []
        lastCentroid = nil
        centroidTravel = 0
        separationTravel = 0
        scrollPhaseStarted = false
        scrollVelocityX = 0
        scrollVelocityY = 0
        zoomRemainder = 0
        swipeAccumulatedX = 0
        swipeAccumulatedY = 0
        swipeFired = false
    }

    // MARK: - One finger → pointer

    private func handlePointer(_ contact: TouchContact, timestamp: Double, settings: MouseSettings) {
        guard settings.pointerActive else { return }

        // In separated mode the hand is either sliding the mouse or working the surface,
        // never both. Re-anchor while physically moving so touch resumes without a jump.
        //
        // Skipped when movement is being discarded: yielding to a movement that has already
        // been thrown away would freeze the pointer for no reason.
        if settings.movementMode == .separated,
           !settings.blocksPhysicalMovement,
           tracker.hasRecentPhysicalMovement(deviceKey: deviceKey) {
            pointerAnchor = nil
            pointerContactID = nil
            pointerFilter.reset()
            return
        }

        configureFilterIfNeeded(for: settings.movementMode)
        let position = pointerFilter.filter(contact.normalizedPosition, timestamp: timestamp)

        // A different finger, or the first frame of this one: anchor without moving.
        guard contact.identifier == pointerContactID, let anchor = pointerAnchor else {
            pointerContactID = contact.identifier
            pointerAnchor = position
            lastPointerTimestamp = timestamp
            return
        }
        pointerAnchor = position

        // Real finger travel in millimetres. The touch surface's origin is bottom-left;
        // the screen's is top-left, hence the inverted y.
        let dxMM = (position.x - anchor.x) * surfaceWidthMM
        let dyMM = (anchor.y - position.y) * surfaceWidthMM * aspect
        let travelMM = (dxMM * dxMM + dyMM * dyMM).squareRoot()
        guard travelMM > 0 else { return }

        let dt = max(timestamp - lastPointerTimestamp, 1.0 / 240.0)
        lastPointerTimestamp = timestamp

        let gain = pointerGain(speedMMPerSecond: travelMM / dt) * settings.sensitivity.multiplier
        let dx = dxMM * gain
        let dy = dyMM * gain

        if settings.movementMode == .smoothed, (dx * dx + dy * dy).squareRoot() < smoothedDeadZone { return }

        output.moveCursor(dx: dx, dy: dy, trustOwnPosition: settings.blocksPhysicalMovement)
    }

    /// The trackpad-style acceleration curve: gain rises smoothly with finger speed, so slow
    /// movement stays close to 1:1 for precision while a flick covers the whole screen.
    /// A smoothstep is used rather than a straight ramp because the knee is what makes the
    /// transition feel continuous instead of like the pointer suddenly letting go.
    private func pointerGain(speedMMPerSecond speed: Double) -> Double {
        let t = min(speed / pointerAccelerationReference, 1.0)
        let eased = t * t * (3.0 - 2.0 * t)
        let gain = slowPointsPerMM + (fastPointsPerMM - slowPointsPerMM) * eased
        return gain * SystemPreferences.trackpadSpeedFactor
    }

    private func scrollGain(speedMMPerSecond speed: Double) -> Double {
        let t = min(speed / scrollAccelerationReference, 1.0)
        let eased = t * t * (3.0 - 2.0 * t)
        return slowScrollPointsPerMM + (fastScrollPointsPerMM - slowScrollPointsPerMM) * eased
    }

    /// Filtering is always on; the mode only decides how aggressive it is.
    private func configureFilterIfNeeded(for mode: MovementMode) {
        guard filterMode != mode else { return }
        filterMode = mode
        switch mode {
        case .smoothed:
            // Heavier smoothing for a hand that shakes, at the cost of a little lag.
            pointerFilter.configure(minCutoff: 0.6, beta: 0.22)
        case .merged, .separated:
            // Just enough to erase capacitive shimmer without any perceptible delay.
            pointerFilter.configure(minCutoff: 1.8, beta: 0.65)
        }
        pointerFilter.reset()
    }

    // MARK: - Two fingers → scroll or pinch

    private func handleTwoFingers(_ contacts: [TouchContact], timestamp: Double, settings: MouseSettings) {
        let pair = Array(contacts.prefix(2))
        guard pair.count == 2 else { return }

        let ids = pair.map(\.identifier)
        let centroid = TouchVector.centroid(of: pair)
        let separation = physicalDistance(pair[0].normalizedPosition, pair[1].normalizedPosition)

        // A changed contact set re-references without emitting, so swapping fingers mid
        // gesture contributes no movement instead of a jump.
        guard ids == trackedIDs, let previous = lastCentroid else {
            if mode != .scroll, mode != .pinch, mode != .systemScroll {
                mode = .twoFingerUndecided
            }
            trackedIDs = ids
            lastCentroid = centroid
            separationAnchor = separation
            lastSeparation = separation
            lastScrollTimestamp = timestamp
            return
        }

        let stepX = centroid.x - previous.x
        let stepY = centroid.y - previous.y
        lastCentroid = centroid

        switch mode {
        case .twoFingerUndecided:
            centroidTravel += (stepX * stepX + (stepY * aspect) * (stepY * aspect)).squareRoot()
            separationTravel = max(separationTravel, abs(separation - separationAnchor))
            commitTwoFingerMode(settings: settings, separation: separation, timestamp: timestamp)

        case .scroll:
            emitScroll(stepX: stepX, stepY: stepY, timestamp: timestamp, settings: settings)

        case .pinch:
            emitZoom(separation: separation, settings: settings)

        case .systemScroll:
            break // macOS is handling these fingers; stay out of the way

        default:
            mode = .twoFingerUndecided
        }
    }

    /// Scrolling and pinching are both two fingers moving, distinguished by *how*: scrolling
    /// slides them together so the midpoint travels, pinching moves them against each other
    /// so the separation changes. Whichever accumulates first wins, and the mode then sticks
    /// for the rest of the gesture so a slightly uneven scroll can't turn into a zoom.
    private func commitTwoFingerMode(settings: MouseSettings, separation: Double, timestamp: Double) {
        guard max(centroidTravel, separationTravel) >= twoFingerCommitThreshold else { return }

        if separationTravel > centroidTravel, settings.pinchToZoomActive {
            mode = .pinch
            lastSeparation = separation
            zoomRemainder = 0
            if settings.zoomMethod == .pinchGesture {
                output.magnify(0, phase: .began)
            }
            return
        }

        // Only take over scrolling when we've replaced the trackpad behaviour wholesale;
        // otherwise the mouse's own scrolling is already perfect and should be left alone.
        if settings.pointerActive {
            mode = .scroll
            scrollPhaseStarted = false
            lastScrollTimestamp = timestamp
        } else {
            mode = .systemScroll
        }
    }

    private func emitScroll(stepX: Double, stepY: Double, timestamp: Double, settings: MouseSettings) {
        let dxMM = stepX * surfaceWidthMM
        let dyMM = stepY * surfaceWidthMM * aspect
        let travelMM = (dxMM * dxMM + dyMM * dyMM).squareRoot()

        let dt = max(timestamp - lastScrollTimestamp, 1.0 / 240.0)
        lastScrollTimestamp = timestamp
        guard travelMM > 0 else { return }

        let gain = scrollGain(speedMMPerSecond: travelMM / dt) * settings.sensitivity.multiplier
        // Touch y is bottom-up, and a natural-direction scroll sends a positive delta when
        // the fingers move *down*. Follows the system's own direction preference rather than
        // inventing a second setting for the same thing.
        let direction: Double = SystemPreferences.naturalScrolling ? -1 : 1
        let dx = -dxMM * gain * direction
        let dy = dyMM * gain * direction

        // Velocity is tracked from the true fractional movement, not the quantised output,
        // so the momentum flick reflects the whole gesture rather than rounding artefacts.
        scrollVelocityX += (dx / dt - scrollVelocityX) * 0.35
        scrollVelocityY += (dy / dt - scrollVelocityY) * 0.35

        guard let step = scrollAccumulator.take(dx: dx, dy: dy) else { return }
        output.scroll(
            dx: step.dx,
            dy: step.dy,
            phase: scrollPhaseStarted ? .changed : .began,
            flags: []
        )
        scrollPhaseStarted = true
    }

    private func emitZoom(separation: Double, settings: MouseSettings) {
        let delta = (separation - lastSeparation) * pinchScale
        lastSeparation = separation
        guard delta != 0 else { return }

        switch settings.zoomMethod {
        case .pinchGesture:
            output.magnify(delta, phase: .changed)
        case .commandScroll:
            // ⌘-scroll is quantised, so accumulate until there's a whole step to send.
            zoomRemainder += delta * 40
            let step = zoomRemainder.rounded(.towardZero)
            zoomRemainder -= step
            guard step != 0 else { return }
            output.scroll(dx: 0, dy: Int32(step), phase: .discrete, flags: .maskCommand)
        }
    }

    // MARK: - Three fingers → Mission Control / App Exposé

    private func handleThreeFingers(_ contacts: [TouchContact], settings: MouseSettings) {
        guard settings.threeFingerSwipesActive, !contacts.isEmpty else { return }

        let ids = contacts.map(\.identifier)
        let centroid = TouchVector.centroid(of: contacts)

        // Fingers land and lift one at a time, which moves the centroid without the hand
        // moving at all. Re-referencing on every change of the contact set — and only
        // accumulating while it's stable — keeps that out of the measured travel.
        guard ids == trackedIDs, let previous = lastCentroid else {
            trackedIDs = ids
            lastCentroid = centroid
            return
        }
        lastCentroid = centroid
        guard !swipeFired else { return }

        swipeAccumulatedX += centroid.x - previous.x
        swipeAccumulatedY += (centroid.y - previous.y) * aspect

        guard abs(swipeAccumulatedY) >= threeFingerSwipeThreshold,
              abs(swipeAccumulatedY) >= abs(swipeAccumulatedX) * threeFingerVerticalDominance else { return }

        swipeFired = true
        momentum.cancel()
        // Touch coordinates are bottom-up, so a positive accumulation is fingers moving up.
        if swipeAccumulatedY > 0 {
            output.missionControl()
        } else {
            output.appExpose()
        }
    }

    // MARK: - Taps → smart zoom

    private func updateGestureTracking(_ contacts: [TouchContact], now: TimeInterval) {
        let count = contacts.count

        if gestureStartCentroid == nil, count > 0 {
            gestureStartUptime = now
            gestureStartCentroid = TouchVector.centroid(of: contacts)
            gestureMaxTravel = 0
            gesturePeakContacts = count
            return
        }

        if count > 0 {
            gesturePeakContacts = max(gesturePeakContacts, count)
            if let start = gestureStartCentroid {
                gestureMaxTravel = max(gestureMaxTravel, physicalDistance(start, TouchVector.centroid(of: contacts)))
            }
            return
        }

        if gestureStartCentroid != nil {
            finishGesture(endedAt: now)
        }
    }

    private func finishGesture(endedAt now: TimeInterval) {
        defer { gestureStartCentroid = nil }
        guard snapshot.settings(for: deviceKey).smartZoomActive else { return }

        // A physical click also puts a finger on the surface briefly and barely moves it,
        // which is indistinguishable from a tap in the contact stream alone. The event tap
        // tells us a click happened, and that disqualifies the gesture — otherwise every
        // double-click would smart-zoom.
        guard gesturePeakContacts == 1,
              now - gestureStartUptime <= tapMaxDuration,
              gestureMaxTravel <= tapMaxTravel,
              !bridge.hasClicked(since: gestureStartUptime) else {
            lastTapUptime = -.infinity
            return
        }

        if now - lastTapUptime <= doubleTapMaxGap {
            lastTapUptime = -.infinity
            output.smartMagnify()
        } else {
            lastTapUptime = now
        }
    }

    /// Distance between two contacts in surface widths, corrected for the surface's shape
    /// so a threshold means the same physical distance in every direction.
    private func physicalDistance(_ a: TouchVector, _ b: TouchVector) -> Double {
        let dx = a.x - b.x
        let dy = (a.y - b.y) * aspect
        return (dx * dx + dy * dy).squareRoot()
    }
}

// MARK: - Geometry helpers

extension TouchVector {
    static func centroid(of contacts: [TouchContact]) -> TouchVector {
        guard !contacts.isEmpty else { return TouchVector(x: 0, y: 0) }
        let count = Double(contacts.count)
        return TouchVector(
            x: contacts.reduce(0) { $0 + $1.normalizedPosition.x } / count,
            y: contacts.reduce(0) { $0 + $1.normalizedPosition.y } / count
        )
    }
}

/// Lock-protected settings, readable from the multitouch callback thread.
final class SettingsSnapshot: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: MouseSettings] = [:]

    func update(_ values: [String: MouseSettings]) {
        lock.lock()
        self.values = values
        lock.unlock()
    }

    func settings(for deviceKey: String) -> MouseSettings {
        lock.lock()
        defer { lock.unlock() }
        return values[deviceKey] ?? MouseSettings(deviceKey: deviceKey, displayName: "")
    }
}

/// System preferences the engine has to respect so it doesn't contradict System Settings.
enum SystemPreferences {
    /// "Natural" scrolling, from System Settings ▸ Mouse. Absent means enabled, which is
    /// the macOS default.
    static var naturalScrolling: Bool {
        UserDefaults.standard.object(forKey: "com.apple.swipescrolldirection") as? Bool ?? true
    }

    /// Scales the pointer curve by the user's own trackpad speed setting, so the touch
    /// surface lands near the speed their trackpad already runs at.
    ///
    /// The ratio to the macOS default is square-rooted and tightly clamped deliberately.
    /// Applied directly, a "fast" system setting more than doubles a curve that is already
    /// tuned, and the touch strip is small enough that the pointer becomes uncontrollable.
    /// This lets the system preference lean the result without overwhelming it — the
    /// six sensitivity steps are what the user actually tunes with.
    static var trackpadSpeedFactor: Double {
        guard let scaling = UserDefaults.standard.object(forKey: "com.apple.trackpad.scaling") as? Double,
              scaling > 0 else {
            return 1.0
        }
        let systemDefault = 0.6875
        let ratio = (scaling + 0.35) / (systemDefault + 0.35)
        return min(max(ratio.squareRoot(), 0.7), 1.6)
    }

    /// Whether macOS's own Magic Mouse smart zoom is on. If it is, ours would fire on the
    /// same double tap and the two zooms would cancel out, so the UI warns instead of
    /// silently misbehaving. Read-only — changing it is the user's call, in System Settings.
    static var systemSmartZoomEnabled: Bool {
        guard let defaults = UserDefaults(suiteName: "com.apple.AppleMultitouchMouse"),
              let value = defaults.object(forKey: "MouseOneFingerDoubleTapGesture") as? Int else {
            return true
        }
        return value != 0
    }
}
