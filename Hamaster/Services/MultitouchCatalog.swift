//
//  MultitouchCatalog.swift
//  Hamaster
//

import Combine
import Foundation

/// Keeps one long-lived `MultitouchDeviceSession` per physical touch surface on the system.
///
/// `MTDeviceCreateList()` is a snapshot, so a Magic Mouse that pairs *after* launch — the
/// normal case for a login-item menu bar app — is invisible until we ask again. `refresh()`
/// re-enumerates and adds sessions for surfaces we haven't seen.
///
/// Two lifetime rules from the private API shape this class:
///  - Every returned CFArray owns its MTDeviceRefs, so each one is retained forever. The
///    handful of arrays a session accumulates is far cheaper than a use-after-free.
///  - `MTDeviceStop` is the fragile call, so a superseded session is never stopped, only
///    orphaned: its handlers are dropped and its frames fall on the floor.
@MainActor
final class MultitouchCatalog: ObservableObject {
    @Published private(set) var sessions: [MultitouchDeviceSession] = []

    let isBridgeAvailable = PrivateMultitouchBridge.isAvailable

    /// Retains every array ever handed back by MTDeviceCreateList (see class note).
    private var retainedLists: [CFArray] = []
    /// deviceID → live session, so a re-enumeration recognises surfaces already tracked.
    private var sessionsByDeviceID: [UInt64: MultitouchDeviceSession] = [:]

    init() {
        refresh()
    }

    func refresh() {
        guard isBridgeAvailable, let list = PrivateMultitouchBridge.copyDeviceList() else { return }
        retainedLists.append(list)

        var didChange = false
        for device in PrivateMultitouchBridge.devices(in: list) {
            let deviceID = PrivateMultitouchBridge.deviceID(device)
            // Same surface, same underlying pointer: nothing to do. A *different* pointer
            // for a known deviceID means the device reconnected and the old ref is dead,
            // so the session is replaced.
            if let existing = sessionsByDeviceID[deviceID], existing.device == device { continue }

            let session = MultitouchDeviceSession(device: device)
            sessionsByDeviceID[deviceID] = session
            didChange = true
        }

        if didChange {
            sessions = Array(sessionsByDeviceID.values)
        }
    }

    /// Every surface that belongs to a mouse rather than a trackpad.
    var mouseSessions: [MultitouchDeviceSession] {
        sessions.filter(\.looksLikeMouseSurface)
    }
}
