//
//  MagicMouse.swift
//  Hamaster
//

import Foundation
import IOKit.hid

/// One connected Magic Mouse, paired with the touch surface it owns.
struct MagicMouse: Identifiable {
    var id: String { deviceKey }

    /// Stable identity used for settings and for CGEvent attribution.
    let deviceKey: String
    let displayName: String
    let transport: String?
    /// Normalised hardware address, used to pair with a touch surface.
    let hardwareAddress: String?

    /// The multitouch stream for this mouse's surface. `nil` means the touch surface
    /// couldn't be reached — every touch feature is unavailable and the UI says so.
    let session: MultitouchDeviceSession?

    var isUSB: Bool { transport?.caseInsensitiveCompare("USB") == .orderedSame }

    var connectionDescription: String {
        guard let transport, !transport.isEmpty else { return "Connected" }
        return transport
    }
}

extension MagicMouse: Equatable {
    static func == (lhs: MagicMouse, rhs: MagicMouse) -> Bool {
        lhs.deviceKey == rhs.deviceKey
            && lhs.displayName == rhs.displayName
            && lhs.transport == rhs.transport
            && lhs.session === rhs.session
    }
}

/// Decides whether a HID device is a Magic Mouse.
///
/// The product string is the primary signal because it survives every model revision;
/// the product-ID list is a backstop for the (rare) case where a device reports no usable
/// name. Both are gated on Apple's vendor ID so a third-party mouse that happens to have
/// "magic" in its name can never match.
enum MagicMouseIdentifier {
    /// 0x05AC is Apple's USB vendor ID; 0x004C is the Bluetooth company identifier that
    /// some transports report instead.
    private static let appleVendorIDs: Set<Int> = [0x05AC, 0x004C]

    /// Magic Mouse (A1296), Magic Mouse 2 (A1657), Magic Mouse USB-C (A3170).
    private static let knownProductIDs: Set<Int> = [0x030D, 0x0269, 0x0323]

    static func matches(vendorID: Int?, productID: Int?, product: String?) -> Bool {
        guard let vendorID, appleVendorIDs.contains(vendorID) else { return false }
        if let product, product.range(of: "magic mouse", options: .caseInsensitive) != nil { return true }
        if let productID, knownProductIDs.contains(productID) { return true }
        return false
    }

    static func matches(_ device: IOHIDDevice) -> Bool {
        matches(
            vendorID: DeviceKey.intProperty(device, kIOHIDVendorIDKey),
            productID: DeviceKey.intProperty(device, kIOHIDProductIDKey),
            product: DeviceKey.stringProperty(device, kIOHIDProductKey)
        )
    }
}
