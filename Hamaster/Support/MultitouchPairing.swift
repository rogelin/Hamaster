//
//  MultitouchPairing.swift
//  Hamaster
//

import Foundation
import IOKit

/// Works out which touch surface belongs to which Magic Mouse.
///
/// There is no shared identifier between an `IOHIDDevice` and an `MTDeviceRef`, so the two
/// are correlated through the IORegistry instead: the `AppleMultitouchDevice` node carrying
/// a given multitouch ID and the mouse's HID node both descend from the same Bluetooth (or
/// USB) device, and that ancestor holds the hardware address. Normalising both sides to
/// bare hex digits makes the comparison immune to the different separators each layer uses.
///
/// Every step is best-effort. When correlation finds nothing — an unfamiliar registry
/// layout, a macOS release that renames a property — the caller falls back to positional
/// pairing, which is exactly right for the overwhelmingly common one-mouse case.
enum MultitouchPairing {
    /// Hardware address of the device owning the touch surface with this multitouch ID,
    /// as lowercase hex digits with separators stripped.
    static func hardwareAddress(forMultitouchID multitouchID: UInt64) -> String? {
        guard let service = multitouchService(id: multitouchID) else { return nil }
        defer { IOObjectRelease(service) }
        return ancestorHardwareAddress(of: service)
    }

    /// Same normalisation applied to a HID device's serial number, so the two are comparable.
    static func normalize(serialNumber: String?) -> String? {
        guard let serialNumber else { return nil }
        let hex = serialNumber.lowercased().filter(\.isHexDigit)
        return hex.count >= 12 ? String(hex.suffix(12)) : nil
    }

    // MARK: - Registry walking

    /// Finds the `AppleMultitouchDevice` node whose "Multitouch ID" matches, which is the
    /// registry-side counterpart of the `MTDeviceRef` the private framework handed us.
    private static func multitouchService(id: UInt64) -> io_service_t? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleMultitouchDevice"), &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        while case let service = IOIteratorNext(iterator), service != 0 {
            if let value = registryProperty(service, "Multitouch ID") as? NSNumber, value.uint64Value == id {
                return service
            }
            IOObjectRelease(service)
        }
        return nil
    }

    /// Walks up the service plane looking for the first ancestor that publishes a hardware
    /// address. Depth is bounded: the transport node sits a few levels above the touch
    /// device, and an unbounded walk would climb all the way to the root on a miss.
    private static func ancestorHardwareAddress(of service: io_service_t, maxDepth: Int = 6) -> String? {
        var current = service
        var ownsCurrent = false
        defer { if ownsCurrent { IOObjectRelease(current) } }

        for _ in 0..<maxDepth {
            if let address = hardwareAddress(of: current) { return address }

            var parent: io_service_t = 0
            guard IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) == KERN_SUCCESS, parent != 0 else {
                return nil
            }
            if ownsCurrent { IOObjectRelease(current) }
            current = parent
            ownsCurrent = true
        }
        return nil
    }

    /// Bluetooth publishes the address as six raw bytes under one of these keys; USB
    /// publishes a serial number string. Both normalise to the same hex digits.
    private static func hardwareAddress(of service: io_service_t) -> String? {
        for key in ["BD_ADDR", "DeviceAddress"] {
            if let data = registryProperty(service, key) as? Data, data.count == 6 {
                return data.map { String(format: "%02x", $0) }.joined()
            }
        }
        for key in ["SerialNumber", "USB Serial Number"] {
            if let string = registryProperty(service, key) as? String, let normalized = normalize(serialNumber: string) {
                return normalized
            }
        }
        return nil
    }

    private static func registryProperty(_ service: io_service_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
}
