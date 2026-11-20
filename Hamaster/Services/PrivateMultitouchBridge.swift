//
//  PrivateMultitouchBridge.swift
//  Hamaster
//

import CoreFoundation
import Foundation

/// Direct dlopen bridge to the private MultitouchSupport.framework, using
/// MTDeviceCreateList() + per-device MTRegisterContactFrameCallback().
///
/// Kyome22/OpenMultitouchSupport (the SPM package originally used here) only wires up
/// MTDeviceCreateDefault() — a single "default" device. On a desktop Mac with no built-in
/// trackpad that excludes external Bluetooth accessories entirely (verified empirically:
/// MTDeviceCreateDefault produced nothing for a Magic Mouse/Trackpad on this machine).
/// MTDeviceCreateList() is still exported on this macOS version and was confirmed, via a
/// standalone dlsym probe, to deliver live contact frames for both external devices.
///
/// Struct/function signatures below are taken verbatim from that package's own
/// (MIT-licensed) private header OpenMultitouchSupportXCF/OpenMTInternal.h rather than
/// re-derived from scratch, and were validated against this machine's real hardware.
enum PrivateMultitouchBridge {
    typealias MTDeviceRef = UnsafeMutableRawPointer

    struct MTPoint {
        var x: Float = 0
        var y: Float = 0
    }

    struct MTVector {
        var position = MTPoint()
        var velocity = MTPoint()
    }

    struct MTTouch {
        var frame: Int32 = 0
        var timestamp: Double = 0
        var identifier: Int32 = 0
        var state: Int32 = 0
        var fingerId: Int32 = 0
        var handId: Int32 = 0
        var normalizedPosition = MTVector()
        var total: Float = 0
        var pressure: Float = 0
        var angle: Float = 0
        var majorAxis: Float = 0
        var minorAxis: Float = 0
        var absolutePosition = MTVector()
        var field14: Int32 = 0
        var field15: Int32 = 0
        var density: Float = 0
    }

    // The touches array is typed as a raw pointer here rather than
    // UnsafeMutablePointer<MTTouch> — a plain Swift struct as a pointee makes the whole
    // closure type fail "representable in Objective-C" checking that @convention(c)
    // requires. Callers rebind it to MTTouch themselves once past the C boundary.
    typealias FrameCallback = @convention(c) (MTDeviceRef, UnsafeMutableRawPointer, Int32, Double, Int32) -> Void

    private typealias DeviceCreateListFn = @convention(c) () -> Unmanaged<CFArray>?
    private typealias RegisterCallbackFn = @convention(c) (MTDeviceRef, FrameCallback) -> Void
    private typealias DeviceStartFn = @convention(c) (MTDeviceRef, Int32) -> Int32
    private typealias DeviceStopFn = @convention(c) (MTDeviceRef) -> Int32
    private typealias DeviceGetDeviceIDFn = @convention(c) (MTDeviceRef, UnsafeMutablePointer<UInt64>) -> Int32
    private typealias DeviceIsBuiltInFn = @convention(c) (MTDeviceRef) -> Bool
    private typealias DeviceGetSensorDimensionsFn = @convention(c) (MTDeviceRef, UnsafeMutablePointer<Int32>, UnsafeMutablePointer<Int32>) -> Int32
    private typealias DeviceGetFamilyIDFn = @convention(c) (MTDeviceRef, UnsafeMutablePointer<Int32>) -> Int32
    private typealias DeviceGetSurfaceDimensionsFn = @convention(c) (MTDeviceRef, UnsafeMutablePointer<Int32>, UnsafeMutablePointer<Int32>) -> Int32

    /// Immutable after initialization; dlsym handles are safe to share for lookup.
    nonisolated(unsafe) private static let handle: UnsafeMutableRawPointer? = dlopen(
        "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport",
        RTLD_NOW
    )

    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        guard let handle, let sym = dlsym(handle, name) else { return nil }
        return unsafeBitCast(sym, to: T.self)
    }

    private static let deviceCreateListFn = symbol("MTDeviceCreateList", as: DeviceCreateListFn.self)
    private static let registerCallbackFn = symbol("MTRegisterContactFrameCallback", as: RegisterCallbackFn.self)
    private static let unregisterCallbackFn = symbol("MTUnregisterContactFrameCallback", as: RegisterCallbackFn.self)
    private static let deviceStartFn = symbol("MTDeviceStart", as: DeviceStartFn.self)
    private static let deviceStopFn = symbol("MTDeviceStop", as: DeviceStopFn.self)
    private static let deviceGetDeviceIDFn = symbol("MTDeviceGetDeviceID", as: DeviceGetDeviceIDFn.self)
    private static let deviceIsBuiltInFn = symbol("MTDeviceIsBuiltIn", as: DeviceIsBuiltInFn.self)
    private static let deviceGetSensorDimensionsFn = symbol("MTDeviceGetSensorDimensions", as: DeviceGetSensorDimensionsFn.self)
    private static let deviceGetFamilyIDFn = symbol("MTDeviceGetFamilyID", as: DeviceGetFamilyIDFn.self)
    private static let deviceGetSurfaceDimensionsFn = symbol("MTDeviceGetSensorSurfaceDimensions", as: DeviceGetSurfaceDimensionsFn.self)

    static var isAvailable: Bool {
        deviceCreateListFn != nil && registerCallbackFn != nil && deviceStartFn != nil
    }

    /// Returns the retained CFArray from MTDeviceCreateList. The CALLER MUST KEEP THIS
    /// ARRAY ALIVE for as long as any MTDeviceRef extracted from it is in use: the array
    /// owns the device objects, and letting it deallocate frees them — after which
    /// MTDeviceStart silently delivers nothing and MTDeviceStop traps (EXC_BAD_INSTRUCTION).
    static func copyDeviceList() -> CFArray? {
        deviceCreateListFn?()?.takeRetainedValue()
    }

    static func devices(in list: CFArray) -> [MTDeviceRef] {
        let count = CFArrayGetCount(list)
        var result: [MTDeviceRef] = []
        result.reserveCapacity(count)
        for i in 0..<count {
            if let raw = CFArrayGetValueAtIndex(list, i) {
                result.append(UnsafeMutableRawPointer(mutating: raw))
            }
        }
        return result
    }

    static func deviceID(_ device: MTDeviceRef) -> UInt64 {
        guard let deviceGetDeviceIDFn else { return 0 }
        var value: UInt64 = 0
        _ = deviceGetDeviceIDFn(device, &value)
        return value
    }

    static func isBuiltIn(_ device: MTDeviceRef) -> Bool {
        deviceIsBuiltInFn?(device) ?? false
    }

    /// Apple's own device-family identifier for the touch sensor. The Magic Mouse
    /// families are distinct from every trackpad family, which makes this the cleanest
    /// signal for "this touch surface belongs to a mouse, not a trackpad" — far better
    /// than inferring it from sensor size. Returns nil if the symbol is unavailable.
    static func familyID(_ device: MTDeviceRef) -> Int? {
        guard let deviceGetFamilyIDFn else { return nil }
        var value: Int32 = 0
        guard deviceGetFamilyIDFn(device, &value) == 0 else { return nil }
        return Int(value)
    }

    /// Physical size of the touch surface in millimetres. The framework reports hundredths
    /// of a millimetre. A Magic Mouse's surface is far taller than it is wide, so this is
    /// what lets movement be scaled to real finger travel instead of to normalised units.
    static func surfaceSizeMillimetres(_ device: MTDeviceRef) -> (width: Double, height: Double)? {
        guard let deviceGetSurfaceDimensionsFn else { return nil }
        var width: Int32 = 0
        var height: Int32 = 0
        guard deviceGetSurfaceDimensionsFn(device, &width, &height) == 0, width > 0, height > 0 else { return nil }
        return (Double(width) / 100.0, Double(height) / 100.0)
    }

    static func sensorDimensions(_ device: MTDeviceRef) -> (rows: Int, cols: Int)? {
        guard let deviceGetSensorDimensionsFn else { return nil }
        var rows: Int32 = 0
        var cols: Int32 = 0
        let status = deviceGetSensorDimensionsFn(device, &rows, &cols)
        guard status == 0 else { return nil }
        return (Int(rows), Int(cols))
    }

    static func start(_ device: MTDeviceRef, callback: FrameCallback) {
        registerCallbackFn?(device, callback)
        _ = deviceStartFn?(device, 0)
    }

    static func stop(_ device: MTDeviceRef, callback: FrameCallback) {
        _ = deviceStopFn?(device)
        unregisterCallbackFn?(device, callback)
    }
}
