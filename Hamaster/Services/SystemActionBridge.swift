//
//  SystemActionBridge.swift
//  Hamaster
//

import CoreFoundation
import Foundation

/// Triggers macOS system UI actions (Mission Control, App Exposé, Show Desktop, Launchpad)
/// through `CoreDockSendNotification` — the same private-but-stable Carbon entry point the
/// system's own Dock uses.
///
/// This is far more reliable than synthesizing the default Control+Arrow keyboard
/// shortcuts: those only fire if the user hasn't changed or disabled the shortcut in
/// System Settings, whereas the CoreDock notification drives the action directly and needs
/// no Accessibility grant of its own.
enum SystemActionBridge {
    private typealias SendNotificationFn = @convention(c) (CFString, Int32) -> Void

    private static let sendNotification: SendNotificationFn? = {
        // Carbon re-exports CoreDock's symbols; dlopen it, then resolve the function.
        guard let handle = dlopen("/System/Library/Frameworks/Carbon.framework/Carbon", RTLD_NOW),
              let sym = dlsym(handle, "CoreDockSendNotification") else { return nil }
        return unsafeBitCast(sym, to: SendNotificationFn.self)
    }()

    static var isAvailable: Bool { sendNotification != nil }

    static func missionControl() { send("com.apple.expose.awake") }
    static func appExpose() { send("com.apple.expose.front.awake") }
    static func showDesktop() { send("com.apple.showdesktop.awake") }
    static func launchpad() { send("com.apple.launchpad.toggle") }

    private static func send(_ notification: String) {
        sendNotification?(notification as CFString, 0)
    }
}
