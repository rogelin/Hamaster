//
//  DeviceKey.swift
//  Hamaster
//

import Foundation
import IOKit
import IOKit.hid

/// Stable per-physical-mouse identity used to key settings and to attribute CGEvents.
///
/// The Bluetooth address arrives as the HID serial number and survives sleep, reconnects
/// and reboots, so it is preferred. Vendor/product alone is the fallback: it collides if
/// someone owns two identical Magic Mice, which is rare enough to accept in exchange for
/// settings that don't silently reset.
enum DeviceKey {
    static func make(vendorID: Int?, productID: Int?, serialNumber: String?) -> String {
        let vid = String(format: "%04x", vendorID ?? 0)
        let pid = String(format: "%04x", productID ?? 0)
        guard let serialNumber, !serialNumber.isEmpty else { return "\(vid)-\(pid)" }
        let safe = serialNumber
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .lowercased()
        return "\(vid)-\(pid)-\(safe)"
    }

    static func forDevice(_ device: IOHIDDevice) -> String {
        make(
            vendorID: intProperty(device, kIOHIDVendorIDKey),
            productID: intProperty(device, kIOHIDProductIDKey),
            serialNumber: stringProperty(device, kIOHIDSerialNumberKey)
        )
    }

    static func intProperty(_ device: IOHIDDevice, _ key: String) -> Int? {
        (IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber)?.intValue
    }

    static func stringProperty(_ device: IOHIDDevice, _ key: String) -> String? {
        IOHIDDeviceGetProperty(device, key as CFString) as? String
    }

    static func registryEntryID(for device: IOHIDDevice) -> UInt64? {
        let service = IOHIDDeviceGetService(device)
        guard service != MACH_PORT_NULL else { return nil }
        var entryID: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(service, &entryID) == KERN_SUCCESS else { return nil }
        return entryID
    }
}
