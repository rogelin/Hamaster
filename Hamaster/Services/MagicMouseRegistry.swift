//
//  MagicMouseRegistry.swift
//  Hamaster
//

import Combine
import Foundation
@preconcurrency import IOKit.hid

/// Publishes the Magic Mice currently connected, each already paired with its touch surface.
///
/// Deliberately narrow: the IOHIDManager matches only Generic Desktop mice, and everything
/// that isn't a Magic Mouse is discarded immediately. The manager is opened non-exclusively
/// (never `kIOHIDOptionsTypeSeizeDevice`) and no input callback is registered here, so other
/// pointing devices, keyboards and trackpads are enumerated and then left completely alone.
@MainActor
final class MagicMouseRegistry: ObservableObject {
    @Published private(set) var mice: [MagicMouse] = []

    private let catalog: MultitouchCatalog
    nonisolated(unsafe) private let manager: IOHIDManager
    private var devices: [ObjectIdentifier: IOHIDDevice] = [:]
    private var cancellables = Set<AnyCancellable>()

    init(catalog: MultitouchCatalog) {
        self.catalog = catalog
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))

        let matching: [[String: Any]] = [
            [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_Mouse],
            [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_Pointer],
        ]
        IOHIDManagerSetDeviceMatchingMultiple(manager, matching as CFArray)

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
            guard let context else { return }
            let registry = Unmanaged<MagicMouseRegistry>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in registry.handleMatched(device) }
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            guard let context else { return }
            let registry = Unmanaged<MagicMouseRegistry>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in registry.handleRemoved(device) }
        }, context)

        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))

        // A surface can appear without any HID churn we observe (waking from sleep, or the
        // multitouch service attaching a beat after the HID interface), so rebuild whenever
        // the catalog gains a session too.
        catalog.$sessions
            .sink { [weak self] _ in self?.rebuild() }
            .store(in: &cancellables)
    }

    deinit {
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    /// Re-checks for touch surfaces that appeared after the last enumeration.
    func refreshTouchSurfaces() {
        catalog.refresh()
        rebuild()
    }

    // MARK: - Device churn

    private func handleMatched(_ device: IOHIDDevice) {
        guard MagicMouseIdentifier.matches(device) else { return }
        devices[ObjectIdentifier(device)] = device
        // The multitouch service attaches slightly after the HID interface does, so the
        // immediate enumeration usually misses it; the retry catches the surface once the
        // rest of the stack has settled.
        catalog.refresh()
        rebuild()
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(1500))
            self?.refreshTouchSurfaces()
        }
    }

    private func handleRemoved(_ device: IOHIDDevice) {
        guard devices.removeValue(forKey: ObjectIdentifier(device)) != nil else { return }
        rebuild()
    }

    // MARK: - Pairing

    private func rebuild() {
        let candidates = devices.values.map { device -> MagicMouse in
            let serial = DeviceKey.stringProperty(device, kIOHIDSerialNumberKey)
            return MagicMouse(
                deviceKey: DeviceKey.forDevice(device),
                displayName: DeviceKey.stringProperty(device, kIOHIDProductKey) ?? "Magic Mouse",
                transport: DeviceKey.stringProperty(device, kIOHIDTransportKey),
                hardwareAddress: MultitouchPairing.normalize(serialNumber: serial),
                session: nil
            )
        }

        // A Magic Mouse exposes more than one HID interface (pointer plus a vendor-defined
        // one); they collapse to the same device key, so dedupe before pairing.
        var unique: [String: MagicMouse] = [:]
        for candidate in candidates where unique[candidate.deviceKey] == nil {
            unique[candidate.deviceKey] = candidate
        }
        let sorted = unique.values.sorted { $0.deviceKey < $1.deviceKey }

        mice = pair(sorted, with: catalog.mouseSessions)
    }

    /// Correlates through the IORegistry where possible, and falls back to positional
    /// pairing — which is exactly right whenever there is a single Magic Mouse, the case
    /// that covers essentially every user.
    private func pair(_ mice: [MagicMouse], with sessions: [MultitouchDeviceSession]) -> [MagicMouse] {
        guard !sessions.isEmpty else { return mice }

        var available = sessions
        var addressBySession: [ObjectIdentifier: String] = [:]
        for session in sessions {
            addressBySession[ObjectIdentifier(session)] = MultitouchPairing.hardwareAddress(forMultitouchID: session.deviceID)
        }

        var result: [MagicMouse] = []
        var unmatched: [MagicMouse] = []

        for mouse in mice {
            guard let address = mouse.hardwareAddress,
                  let index = available.firstIndex(where: { addressBySession[ObjectIdentifier($0)] == address }) else {
                unmatched.append(mouse)
                continue
            }
            result.append(mouse.withSession(available.remove(at: index)))
        }

        for mouse in unmatched {
            result.append(mouse.withSession(available.isEmpty ? nil : available.removeFirst()))
        }
        return result.sorted { $0.deviceKey < $1.deviceKey }
    }
}

private extension MagicMouse {
    func withSession(_ session: MultitouchDeviceSession?) -> MagicMouse {
        MagicMouse(
            deviceKey: deviceKey,
            displayName: displayName,
            transport: transport,
            hardwareAddress: hardwareAddress,
            session: session
        )
    }
}
