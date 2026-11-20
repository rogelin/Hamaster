//
//  PointerActivityTracker.swift
//  Hamaster
//

import Foundation
@preconcurrency import IOKit.hid

/// Answers "which pointing device produced that CGEvent?".
///
/// CGEvents carry no device identity, so the event tap has no way of telling a Magic Mouse
/// click from a trackpad click or a third-party mouse's click. Watching raw HID input and
/// attributing each CGEvent to the device that most recently sent something is the standard
/// solution; it can only be wrong if two pointing devices produce input in the same instant.
///
/// This is why the app can leave other hardware alone. Every interception in the event tap
/// is gated on the answer here being a Magic Mouse the user has configured — anything else
/// falls through untouched.
///
/// Listening is strictly passive: the manager is opened without `kIOHIDOptionsTypeSeizeDevice`,
/// so devices are observed, never captured, and their events still reach the system normally.
final class PointerActivityTracker: @unchecked Sendable, PhysicalMovementTracking {
    private let manager: IOHIDManager
    private let lock = NSLock()

    private var lastDeviceKey: String?
    private var lastMovementByKey: [String: TimeInterval] = [:]
    private var keyByDevice: [UInt64: String] = [:]
    private var thread: Thread?

    init() {
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching: [[String: Any]] = [
            [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_Mouse],
            [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_Pointer],
            // Apple's own trackpads answer on the Mouse usage above, but third-party ones
            // and pen tablets describe themselves as digitizers. They have to be visible
            // here, because attribution works by one device out-reporting the others —
            // a pointing device the tracker never hears from can't take an event away
            // from the Magic Mouse.
            [kIOHIDDeviceUsagePageKey: kHIDPage_Digitizer, kIOHIDDeviceUsageKey: kHIDUsage_Dig_TouchPad],
            [kIOHIDDeviceUsagePageKey: kHIDPage_Digitizer, kIOHIDDeviceUsageKey: kHIDUsage_Dig_Pen],
        ]
        IOHIDManagerSetDeviceMatchingMultiple(manager, matching as CFArray)

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterInputValueCallback(manager, { context, _, sender, value in
            guard let context, let sender else { return }
            let tracker = Unmanaged<PointerActivityTracker>.fromOpaque(context).takeUnretainedValue()
            let device = Unmanaged<IOHIDDevice>.fromOpaque(sender).takeUnretainedValue()
            tracker.handleInput(from: device, value: value)
        }, context)

        startListening()
    }

    deinit {
        thread?.cancel()
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    /// The HID stream gets a thread of its own rather than the main run loop.
    ///
    /// The timestamps recorded here are the moment the callback runs, and they are compared
    /// against the arrival of CGEvents on the event tap's thread to decide which device an
    /// event belongs to. On the main run loop a SwiftUI layout pass or a menu opening can
    /// delay a batch of reports past that comparison and make a device that has stopped
    /// moving look like it is still moving. A dedicated user-interactive run loop keeps
    /// pointer reports independent of whatever the UI is doing.
    private func startListening() {
        let manager = self.manager
        let thread = Thread {
            IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
            IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            while !Thread.current.isCancelled {
                // A bounded run keeps the loop from returning immediately if it ever ends up
                // with no sources, and gives cancellation somewhere to take effect.
                CFRunLoopRunInMode(.defaultMode, 5.0, false)
            }
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        }
        thread.name = "com.hamaster.pointer-activity"
        thread.qualityOfService = .userInteractive
        thread.start()
        self.thread = thread
    }

    /// Device key of the pointing device that most recently sent any HID input.
    var activeDeviceKey: String? {
        lock.lock()
        defer { lock.unlock() }
        return lastDeviceKey
    }

    /// Whether this device was physically slid within the last `window` seconds. Drives
    /// `MovementMode.separated`, where touch defers to the hand moving the whole mouse.
    func hasRecentPhysicalMovement(deviceKey: String, within window: TimeInterval = 0.12) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let last = lastMovementByKey[deviceKey] else { return false }
        return ProcessInfo.processInfo.systemUptime - last < window
    }

    /// Whether this device is, positively, the thing that just moved the pointer.
    ///
    /// Deliberately stricter than `hasRecentPhysicalMovement`, because this is what licenses
    /// throwing a movement event away, and throwing away another device's movement freezes
    /// hardware the user never configured. Two conditions, each covering a different way the
    /// weaker tests get it wrong:
    ///  - the movement must be recent, so a mouse lying still cannot claim motion it did not
    ///    produce merely because nothing else has reported any;
    ///  - no other pointing device may have moved more recently, so sliding a trackpad hands
    ///    the answer to the trackpad even with a hand resting on the mouse.
    ///
    /// The window is wide enough to cover the jitter between a HID report reaching this
    /// thread and the CGEvent built from it reaching the event tap. Erring wide costs at
    /// most a moment of blocking just after the mouse stops; erring narrow would let the
    /// mouse's own movement leak through mid-slide, which is the thing being suppressed.
    func isMovementSource(deviceKey: String, within window: TimeInterval = 0.2) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let last = lastMovementByKey[deviceKey] else { return false }
        guard ProcessInfo.processInfo.systemUptime - last < window else { return false }
        return lastMovementByKey.allSatisfy { $0.key == deviceKey || $0.value <= last }
    }

    private func handleInput(from device: IOHIDDevice, value: IOHIDValue) {
        let key = cachedKey(for: device)
        let element = IOHIDValueGetElement(value)
        let usagePage = Int(IOHIDElementGetUsagePage(element))
        let usage = Int(IOHIDElementGetUsage(element))
        let isMovement = usagePage == kHIDPage_GenericDesktop && (usage == kHIDUsage_GD_X || usage == kHIDUsage_GD_Y)

        lock.lock()
        lastDeviceKey = key
        if isMovement, IOHIDValueGetIntegerValue(value) != 0 {
            lastMovementByKey[key] = ProcessInfo.processInfo.systemUptime
        }
        lock.unlock()
    }

    /// Reading HID properties on every input value would be far too slow at mouse report
    /// rates, so the derived key is cached against the device's registry entry.
    private func cachedKey(for device: IOHIDDevice) -> String {
        let registryID = DeviceKey.registryEntryID(for: device) ?? 0
        lock.lock()
        let cached = keyByDevice[registryID]
        lock.unlock()
        if let cached { return cached }

        let key = DeviceKey.forDevice(device)
        lock.lock()
        keyByDevice[registryID] = key
        lock.unlock()
        return key
    }
}
