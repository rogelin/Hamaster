//
//  InputMonitoringAccess.swift
//  Hamaster
//

import AppKit
import Combine
import Foundation
@preconcurrency import IOKit.hid

/// Wraps the Input Monitoring permission, which is what lets `PointerActivityTracker`
/// actually receive HID input rather than just enumerate devices.
///
/// Optional, unlike Accessibility. Without it the app still works — it just can't tell one
/// pointing device from another, so `Separated` movement mode and "ignore physical mouse
/// movement" are unavailable and the UI says why.
@MainActor
final class InputMonitoringAccess: ObservableObject {
    @Published private(set) var isGranted: Bool = false

    /// True once TCC has an answer on file, in which case the system prompt is spent and
    /// System Settings is the only remaining route. Drives the button's title so it never
    /// promises a dialog that macOS will not show.
    @Published private(set) var mustUseSystemSettings: Bool = false

    private var recheckTimer: Timer?
    private var recheckDeadline: TimeInterval = 0

    init() {
        refresh()
    }

    func refresh() {
        let access = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)

        let granted = access == kIOHIDAccessTypeGranted
        if granted != isGranted { isGranted = granted }

        // `kIOHIDAccessTypeUnknown` means never asked — the one state in which the system
        // prompt still appears.
        let spent = access != kIOHIDAccessTypeUnknown && !granted
        if spent != mustUseSystemSettings { mustUseSystemSettings = spent }

        if granted { stopRechecking() }
    }

    /// What the permission card's button does.
    ///
    /// `IOHIDRequestAccess` shows its prompt exactly once per app, ever. Every call after
    /// the user has answered returns silently without any UI — which is what made this
    /// button appear to do nothing at all. So the prompt is only attempted while TCC has no
    /// answer on file; after that the button goes straight to the Settings pane, which is
    /// genuinely the only place the decision can still be changed.
    func request() {
        if IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeUnknown {
            _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        } else {
            openSystemSettings()
        }
        refresh()
        if !isGranted { startRechecking() }
    }

    func openSystemSettings() {
        // Falls back to the Privacy & Security pane as a whole if the deep link stops
        // resolving on some future macOS: landing one level out still leaves the user
        // somewhere they can finish the job, which beats nothing happening.
        let deepLink = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
        let pane = URL(string: "x-apple.systempreferences:com.apple.preference.security")
        guard let url = deepLink ?? pane else { return }
        if !NSWorkspace.shared.open(url), let pane {
            NSWorkspace.shared.open(pane)
        }
    }

    /// There is no change notification for TCC grants, so poll slowly while waiting.
    private func startRechecking() {
        recheckDeadline = ProcessInfo.processInfo.systemUptime + 60
        guard recheckTimer == nil else { return }
        let timer = Timer(timeInterval: 2.0, repeats: true) { _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.refresh()
                if ProcessInfo.processInfo.systemUptime >= self.recheckDeadline {
                    self.stopRechecking()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        recheckTimer = timer
    }

    private func stopRechecking() {
        recheckTimer?.invalidate()
        recheckTimer = nil
    }
}
