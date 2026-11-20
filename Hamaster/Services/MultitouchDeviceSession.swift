//
//  MultitouchDeviceSession.swift
//  Hamaster
//

import Foundation

/// Wraps one physical multitouch device (one MTDeviceRef from PrivateMultitouchBridge)
/// for its whole app lifetime, so switching HID device selections in the UI never tears
/// this down mid-callback the way per-selection objects would.
///
/// MTRegisterContactFrameCallback takes no context/userInfo parameter — only the
/// MTDeviceRef itself is passed back to the callback — so there's no way to route a frame
/// straight to a captured Swift closure. Instead every running session registers itself in
/// a small static, lock-protected table keyed by the device pointer, and the single free
/// C callback looks up the right session there and forwards the frame.
/// Multiple subscribers (the Debug Touch tab, TouchPointerService) can observe the same
/// device simultaneously via token-based handlers; the underlying MTDeviceStart/Stop is
/// refcounted so the hardware stream runs only while someone is listening.
final class MultitouchDeviceSession: @unchecked Sendable {
    let device: PrivateMultitouchBridge.MTDeviceRef
    let deviceID: UInt64
    let isBuiltIn: Bool
    let sensorDimensions: (rows: Int, cols: Int)?
    let familyID: Int?
    let surfaceSizeMillimetres: (width: Double, height: Double)?

    /// How much taller the surface is than it is wide. Normalised contact coordinates run
    /// 0...1 on both axes regardless of shape, so without this the same finger travel would
    /// produce more cursor movement sideways than vertically. A Magic Mouse is around 1.76.
    var surfaceAspectRatio: Double {
        guard let surfaceSizeMillimetres, surfaceSizeMillimetres.width > 0 else { return 1.76 }
        return surfaceSizeMillimetres.height / surfaceSizeMillimetres.width
    }

    /// Magic Mouse sensor families, as reported by MTDeviceGetFamilyID. Trackpads (built-in
    /// and Magic Trackpad alike) report entirely different values, so a positive match here
    /// is a reliable "this is a mouse surface".
    private static let magicMouseFamilies: Set<Int> = [112, 113]

    /// Falls back to sensor area when the family ID is unknown (an unreleased model, or a
    /// macOS build where the symbol moved): a mouse's touch strip is far smaller than any
    /// trackpad's, so a small non-built-in sensor is a mouse.
    var looksLikeMouseSurface: Bool {
        if let familyID { return Self.magicMouseFamilies.contains(familyID) }
        guard !isBuiltIn, let sensorDimensions else { return false }
        return sensorDimensions.rows * sensorDimensions.cols < 250
    }

    private let handlersLock = NSLock()
    private var handlers: [UUID: ([TouchContact]) -> Void] = [:]
    private var isRunning = false

    init(device: PrivateMultitouchBridge.MTDeviceRef) {
        self.device = device
        self.deviceID = PrivateMultitouchBridge.deviceID(device)
        self.isBuiltIn = PrivateMultitouchBridge.isBuiltIn(device)
        self.sensorDimensions = PrivateMultitouchBridge.sensorDimensions(device)
        self.familyID = PrivateMultitouchBridge.familyID(device)
        self.surfaceSizeMillimetres = PrivateMultitouchBridge.surfaceSizeMillimetres(device)
    }

    /// Adds a subscriber; starts the hardware stream if this is the first one.
    /// The handler is invoked on the framework's callback thread.
    @discardableResult
    func addHandler(_ handler: @escaping ([TouchContact]) -> Void) -> UUID {
        let token = UUID()
        handlersLock.lock()
        handlers[token] = handler
        let shouldStart = !isRunning
        if shouldStart { isRunning = true }
        handlersLock.unlock()

        if shouldStart {
            Self.register(self)
            PrivateMultitouchBridge.start(device, callback: Self.frameCallback)
        }
        return token
    }

    /// Removes a subscriber. The hardware stream is deliberately left running even when
    /// the last subscriber leaves: rapid device switching in the UI would otherwise
    /// produce tight MTDeviceStop/MTDeviceStart cycles, and MTDeviceStop is the fragile
    /// call in this private API. An idle stream just drops frames on the floor; sessions
    /// live for the app's lifetime and the OS cleans up at process exit.
    func removeHandler(_ token: UUID) {
        handlersLock.lock()
        handlers.removeValue(forKey: token)
        handlersLock.unlock()
    }

    fileprivate func handleFrame(_ touches: UnsafeMutablePointer<PrivateMultitouchBridge.MTTouch>, count: Int32, timestamp: Double, frame: Int32) {
        var contacts: [TouchContact] = []
        contacts.reserveCapacity(Int(count))
        for i in 0..<Int(count) {
            let t = touches[i]
            contacts.append(TouchContact(
                identifier: t.identifier,
                frame: frame,
                timestamp: timestamp,
                state: TouchContactState(rawState: t.state),
                normalizedPosition: TouchVector(x: Double(t.normalizedPosition.position.x), y: Double(t.normalizedPosition.position.y)),
                normalizedVelocity: TouchVector(x: Double(t.normalizedPosition.velocity.x), y: Double(t.normalizedPosition.velocity.y)),
                majorAxis: Double(t.majorAxis),
                minorAxis: Double(t.minorAxis),
                angle: Double(t.angle),
                totalCapacitance: Double(t.total),
                pressure: Double(t.pressure),
                density: Double(t.density)
            ))
        }
        handlersLock.lock()
        let currentHandlers = Array(handlers.values)
        handlersLock.unlock()
        for handler in currentHandlers {
            handler(contacts)
        }
    }

    // MARK: - Static dispatch table (see class doc comment)

    private static let lock = NSLock()
    /// Every access is serialized by the static `lock` directly above.
    nonisolated(unsafe) private static var sessionsByPointer: [UInt: MultitouchDeviceSession] = [:]

    private static func register(_ session: MultitouchDeviceSession) {
        lock.lock()
        sessionsByPointer[UInt(bitPattern: session.device)] = session
        lock.unlock()
    }

    private static let frameCallback: PrivateMultitouchBridge.FrameCallback = { device, touchesRaw, count, timestamp, frame in
        lock.lock()
        let session = sessionsByPointer[UInt(bitPattern: device)]
        lock.unlock()
        let touches = touchesRaw.assumingMemoryBound(to: PrivateMultitouchBridge.MTTouch.self)
        session?.handleFrame(touches, count: count, timestamp: timestamp, frame: frame)
    }
}
