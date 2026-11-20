//
//  InputBridge.swift
//  Hamaster
//

import Foundation

/// The only shared state between the multitouch callback thread and the event tap thread.
///
/// The two need to tell each other things neither can work out alone:
///  - The tap must swallow the scroll events macOS synthesises from the same finger
///    movement we're already interpreting, or a one-finger pointer swipe would scroll
///    whatever is under the cursor as it goes.
///  - The tap must know how many fingers are down to turn a click into a secondary click.
///  - The engine must know a physical click happened, so that a click isn't also counted
///    as a tap and mistaken for a smart-zoom double tap.
///
/// Everything is behind one lock and reduced to plain values; neither side ever touches
/// the other's objects.
final class InputBridge: @unchecked Sendable {
    private let lock = NSLock()

    private var contactCounts: [String: Int] = [:]
    private var lastContactUptimeByKey: [String: TimeInterval] = [:]
    private var suppressingKeys: Set<String> = []
    private var lastSuppressUptimeByKey: [String: TimeInterval] = [:]
    private var lastClickUptime: TimeInterval = 0

    // MARK: - Written by the touch engine

    func setContactCount(_ count: Int, for deviceKey: String) {
        lock.lock()
        contactCounts[deviceKey] = count
        if count > 0 {
            lastContactUptimeByKey[deviceKey] = ProcessInfo.processInfo.systemUptime
        }
        lock.unlock()
    }

    /// Marks that we are currently interpreting this device's fingers ourselves, so its
    /// system-generated scrolls should be dropped.
    func setScrollSuppressed(_ suppressed: Bool, for deviceKey: String) {
        lock.lock()
        if suppressed {
            suppressingKeys.insert(deviceKey)
            lastSuppressUptimeByKey[deviceKey] = ProcessInfo.processInfo.systemUptime
        } else {
            suppressingKeys.remove(deviceKey)
        }
        lock.unlock()
    }

    /// Clears every trace of a device — called when its engine stops, so a stale count or
    /// suppression flag can't keep affecting the tap forever.
    func forget(_ deviceKey: String) {
        lock.lock()
        contactCounts.removeValue(forKey: deviceKey)
        suppressingKeys.remove(deviceKey)
        lastSuppressUptimeByKey.removeValue(forKey: deviceKey)
        lock.unlock()
    }

    // MARK: - Read by the event tap

    func contactCount(for deviceKey: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return contactCounts[deviceKey] ?? 0
    }

    /// Whether fingers were on this surface recently, rather than exactly now.
    ///
    /// Contacts drop out for a frame as a finger rolls or a palm shifts, and a hand resting
    /// on a Magic Mouse doesn't register continuously. For deciding whose movement an event
    /// is, "a hand was on it a moment ago" is the useful question — nobody moves a mouse
    /// they aren't touching.
    func hasRecentContact(for deviceKey: String, within window: TimeInterval) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if (contactCounts[deviceKey] ?? 0) > 0 { return true }
        guard let last = lastContactUptimeByKey[deviceKey] else { return false }
        return ProcessInfo.processInfo.systemUptime - last < window
    }

    /// macOS keeps emitting momentum scroll events after the fingers lift, so a gesture we
    /// suppressed while it was happening gets its tail suppressed too — otherwise letting
    /// go of a two-finger scroll would fling the content under the cursor.
    ///
    /// `deviceKey` is the device the scroll was attributed to. When it's known, only that
    /// device's own suppression counts, so scrolling a trackpad while a finger happens to
    /// rest on the Magic Mouse still scrolls.
    func shouldSuppressScroll(momentumPhase: Int64, deviceKey: String?) -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        defer { lock.unlock() }

        if let deviceKey {
            if suppressingKeys.contains(deviceKey) {
                lastSuppressUptimeByKey[deviceKey] = now
                return true
            }
            return withinGrace(lastSuppressUptimeByKey[deviceKey], now: now, momentumPhase: momentumPhase)
        }

        if !suppressingKeys.isEmpty {
            for key in suppressingKeys { lastSuppressUptimeByKey[key] = now }
            return true
        }
        return withinGrace(lastSuppressUptimeByKey.values.max(), now: now, momentumPhase: momentumPhase)
    }

    private func withinGrace(_ last: TimeInterval?, now: TimeInterval, momentumPhase: Int64) -> Bool {
        guard let last else { return false }
        // The last few events of a gesture can trail the fingers lifting.
        if now - last < 0.3 { return true }
        return momentumPhase != 0 && now - last < 2.0
    }

    // MARK: - Written by the event tap, read by the touch engine

    func notePhysicalClick() {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        lastClickUptime = now
        lock.unlock()
    }

    func hasClicked(since uptime: TimeInterval) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return lastClickUptime >= uptime
    }
}
