//
//  InputInterceptor.swift
//  Hamaster
//

import Combine
import CoreGraphics
import Foundation

/// The single CGEventTap. It does three things, all of them scoped to one Magic Mouse:
///  - turns a click made with two fingers on the surface into a secondary click,
///  - discards the mouse's own movement when the pointer is meant to come only from touch,
///  - drops the scroll events macOS derives from fingers the touch engine is already using.
///
/// Everything else is passed through byte-for-byte. Concretely, the app stays out of the way
/// of other hardware because:
///  - the event mask covers only mouse and scroll events, so keyboards are never tapped;
///  - no tap is installed at all unless some Magic Mouse has a feature switched on;
///  - every branch is gated on the event being attributed to *that* Magic Mouse, so
///    trackpads, tablets and third-party mice fall straight through;
///  - the app's own synthesised events are recognised and never re-processed.
@MainActor
final class InputInterceptor: ObservableObject {
    @Published private(set) var isTapInstalled = false

    private let bridge: InputBridge
    private let tracker: PointerActivityTracker
    private let state = TapState()

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var cancellables = Set<AnyCancellable>()

    init(
        registry: MagicMouseRegistry,
        store: SettingsStore,
        accessibility: AccessibilityAccess,
        bridge: InputBridge,
        tracker: PointerActivityTracker
    ) {
        self.bridge = bridge
        self.tracker = tracker

        Publishers.CombineLatest3(registry.$mice, store.$settings, accessibility.$isGranted)
            .sink { [weak self] mice, settings, isGranted in
                guard let self else { return }
                let connected = Set(mice.map(\.deviceKey))
                let relevant = settings.filter { connected.contains($0.key) && $0.value.needsEventTap }
                self.state.update(relevant)

                if isGranted, !relevant.isEmpty {
                    self.installTap()
                } else {
                    self.removeTap()
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Tap lifecycle

    private func installTap() {
        guard tap == nil else { return }

        let types: [CGEventType] = [
            .leftMouseDown, .leftMouseUp, .leftMouseDragged,
            .rightMouseDragged, .otherMouseDragged,
            .mouseMoved, .scrollWheel,
        ]
        let mask: CGEventMask = types.reduce(0) { $0 | (1 << $1.rawValue) }

        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let interceptor = Unmanaged<InputInterceptor>.fromOpaque(context).takeUnretainedValue()
                return interceptor.handle(type: type, event: event)
            },
            userInfo: context
        ) else { return }

        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        isTapInstalled = true
    }

    private func removeTap() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        self.tap = nil
        runLoopSource = nil
        isTapInstalled = false
        state.resetConversion()
    }

    // MARK: - Tap callback (runs on the tap's thread — no main-actor state here)

    nonisolated private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // macOS disables a tap that takes too long; re-enable and let the event through.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            Task { @MainActor [weak self] in
                guard let tap = self?.tap else { return }
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        // Our own output, on its way to the window server. Never reprocess it.
        guard event.getIntegerValueField(.eventSourceUserData) != EventSynthesis.syntheticMarker else {
            return Unmanaged.passUnretained(event)
        }

        let attribution = attribute()

        if type == .scrollWheel {
            // A scroll positively belonging to something else — a trackpad, another mouse —
            // is never ours to swallow. Suppression exists to hide the scrolls macOS derives
            // from fingers we are already reading ourselves, and those can only come from
            // the mouse those fingers are on.
            if case .foreign = attribution { return Unmanaged.passUnretained(event) }
            let momentum = event.getIntegerValueField(.scrollWheelEventMomentumPhase)
            return bridge.shouldSuppressScroll(momentumPhase: momentum, deviceKey: attribution.configuredKey) ? nil : Unmanaged.passUnretained(event)
        }

        let isMovement = Self.movementTypes.contains(type)
        let blockMovement = isMovement && shouldBlockMovement(attribution)

        // Movement we are letting through still moves the one shared cursor, and while
        // blocking is on the touch pointer is navigating by its own remembered position
        // rather than the system's. Without this the pointer would snap back to wherever
        // touch last left it the moment a finger moved after using a trackpad.
        if isMovement, !blockMovement, state.anyBlocksPhysicalMovement {
            EventSynthesis.resyncCursor()
        }

        guard let deviceKey = attribution.configuredKey, let settings = state.settings(for: deviceKey) else {
            return Unmanaged.passUnretained(event)
        }

        switch type {
        case .leftMouseDown:
            bridge.notePhysicalClick()
            guard settings.secondaryClickActive, bridge.contactCount(for: deviceKey) >= 2 else {
                return Unmanaged.passUnretained(event)
            }
            state.beginConversion()
            return Unmanaged.passUnretained(convertToSecondary(event, type: .rightMouseDown))

        case .leftMouseUp:
            guard state.endConversionIfActive() else { return Unmanaged.passUnretained(event) }
            return Unmanaged.passUnretained(convertToSecondary(event, type: .rightMouseUp))

        case .leftMouseDragged:
            if blockMovement { return Unmanaged.passUnretained(neutralizeMovement(event)) }
            guard state.isConverting else { return Unmanaged.passUnretained(event) }
            return Unmanaged.passUnretained(convertToSecondary(event, type: .rightMouseDragged))

        case .mouseMoved, .rightMouseDragged, .otherMouseDragged:
            guard blockMovement else { return Unmanaged.passUnretained(event) }
            return Unmanaged.passUnretained(neutralizeMovement(event))

        default:
            return Unmanaged.passUnretained(event)
        }
    }

    nonisolated private static let movementTypes: Set<CGEventType> = [
        .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
    ]

    /// Whether this event may have its movement discarded.
    ///
    /// Held to a higher standard than the rest of the tap: it needs positive HID evidence
    /// that this Magic Mouse is the thing currently being slid. Knowing merely that the
    /// mouse is configured and has a hand on it is enough to turn its click into a secondary
    /// click — a click has to come from the device under the hand — but it is not enough to
    /// throw movement away, because the hand resting on the mouse is usually not the hand
    /// doing the moving. Accepting the weaker evidence here is what made this setting freeze
    /// the trackpad and every other pointing device on the desk, not just the Magic Mouse.
    nonisolated private func shouldBlockMovement(_ attribution: Attribution) -> Bool {
        guard let deviceKey = attribution.configuredKey,
              state.settings(for: deviceKey)?.blocksPhysicalMovement == true else { return false }
        return tracker.isMovementSource(deviceKey: deviceKey)
    }

    /// Strips a movement event of its movement instead of dropping it.
    ///
    /// Dropping it is unreliable — the cursor's new position is worked out from the HID
    /// stream before the tap runs — and it also breaks drags, because an app in the middle
    /// of one stops hearing about the mouse entirely. Zeroing the deltas and rewriting the
    /// location back to where touch put the pointer discards the movement while leaving a
    /// well-formed event, which is effectively the "zero sensitivity, zero acceleration"
    /// treatment applied to physical motion only.
    nonisolated private func neutralizeMovement(_ event: CGEvent) -> CGEvent {
        let pinned = EventSynthesis.pinCursor(fallback: event.location)
        event.location = pinned
        event.setIntegerValueField(.mouseEventDeltaX, value: 0)
        event.setIntegerValueField(.mouseEventDeltaY, value: 0)
        // Games and 3D viewports commonly read the raw unaccelerated movement instead of
        // the deltas above, and would otherwise still see the mouse being pushed around.
        for field in Self.unacceleratedMovementFields {
            event.setIntegerValueField(field, value: 0)
        }
        return event
    }

    /// kCGEventUnacceleratedPointerMovementX / Y. Not declared publicly by CoreGraphics,
    /// but the field type imports as a RawRepresentable struct so they construct fine.
    nonisolated private static let unacceleratedMovementFields: [CGEventField] = [
        CGEventField(rawValue: 170)!,
        CGEventField(rawValue: 171)!,
    ]

    /// Rewrites the event in place rather than swallowing it and posting a replacement,
    /// which keeps the click's timestamp, location, modifiers and click-count intact —
    /// a synthesised substitute loses the double-click chain and can arrive out of order.
    nonisolated private func convertToSecondary(_ event: CGEvent, type: CGEventType) -> CGEvent {
        event.type = type
        event.setIntegerValueField(.mouseEventButtonNumber, value: Int64(CGMouseButton.right.rawValue))
        return event
    }

    /// Which device an event belongs to, and how sure we are.
    nonisolated private enum Attribution {
        /// The HID tracker named a Magic Mouse the user has configured.
        case configured(String)
        /// The HID tracker named something else — a trackpad, another mouse, a tablet.
        case foreign
        /// No HID attribution available, because Input Monitoring was never granted.
        case inferred(String?)

        /// The configured mouse to apply settings from, if any.
        var configuredKey: String? {
            switch self {
            case .configured(let key): key
            case .foreign: nil
            case .inferred(let key): key
            }
        }
    }

    /// Which configured Magic Mouse, if any, this event belongs to.
    ///
    /// The HID tracker is the accurate answer but needs Input Monitoring. When it has one,
    /// it is taken as final in both directions: naming a device that isn't ours is a
    /// positive answer of "not this mouse", and must not be talked out of by the guesswork
    /// below. Treating it as merely inconclusive is what let a trackpad's events be handed
    /// to a Magic Mouse that happened to have a hand resting on it.
    ///
    /// Without the permission the tracker returns nothing, so we fall back to the one
    /// inference available from data we already have: a Magic Mouse can't be clicked without
    /// a finger on it, so if exactly one is configured and fingers are on its surface, the
    /// event is probably its. Good enough to convert a click; `shouldBlockMovement` requires
    /// more than this before discarding anything.
    nonisolated private func attribute() -> Attribution {
        if let key = tracker.activeDeviceKey {
            return state.isConfigured(key) ? .configured(key) : .foreign
        }
        guard let onlyKey = state.soleConfiguredKey,
              bridge.hasRecentContact(for: onlyKey, within: 1.0) else { return .inferred(nil) }
        return .inferred(onlyKey)
    }
}

/// Settings and click-conversion state, readable from the tap thread.
private final class TapState: @unchecked Sendable {
    private let lock = NSLock()
    private var settings: [String: MouseSettings] = [:]
    private var converting = false

    func update(_ settings: [String: MouseSettings]) {
        lock.lock()
        self.settings = settings
        if settings.isEmpty { converting = false }
        lock.unlock()
    }

    func settings(for deviceKey: String) -> MouseSettings? {
        lock.lock()
        defer { lock.unlock() }
        return settings[deviceKey]
    }

    func isConfigured(_ deviceKey: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return settings[deviceKey] != nil
    }

    var soleConfiguredKey: String? {
        lock.lock()
        defer { lock.unlock() }
        return settings.count == 1 ? settings.keys.first : nil
    }

    /// Whether any mouse is currently having its movement discarded, which is what makes
    /// the touch pointer's own position authoritative and other devices' movement something
    /// it has to be told about.
    var anyBlocksPhysicalMovement: Bool {
        lock.lock()
        defer { lock.unlock() }
        return settings.values.contains { $0.blocksPhysicalMovement }
    }

    // MARK: Click conversion

    var isConverting: Bool {
        lock.lock()
        defer { lock.unlock() }
        return converting
    }

    func beginConversion() {
        lock.lock()
        converting = true
        lock.unlock()
    }

    /// Consumes the flag, so the matching mouse-up is converted and nothing after it is.
    /// Without this pairing a converted press could leave a button stuck down.
    func endConversionIfActive() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard converting else { return false }
        converting = false
        return true
    }

    func resetConversion() {
        lock.lock()
        converting = false
        lock.unlock()
    }
}
