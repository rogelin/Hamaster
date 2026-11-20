//
//  AccessibilityAccess.swift
//  Hamaster
//

import AppKit
@preconcurrency import ApplicationServices
import Combine
import Foundation

/// Wraps the Accessibility TCC permission, mirroring InputMonitoringAccess. Required for
/// the two synthetic-event features (touch-as-trackpad cursor movement and button
/// remapping); the rest of the app works without it. There is no change notification for
/// this permission, so after the user requests it we re-check briefly while they complete
/// the hand-off in System Settings.
@MainActor
final class AccessibilityAccess: ObservableObject {
    @Published private(set) var isGranted: Bool

    /// Set once the system prompt has been shown, so a second press goes to System Settings
    /// instead of re-showing a dialog the user has already dealt with.
    @Published private(set) var mustUseSystemSettings: Bool = false

    private var recheckTimer: Timer?
    private var recheckDeadline: TimeInterval = 0

    init() {
        isGranted = AXIsProcessTrusted()
    }

    func refresh() {
        let granted = AXIsProcessTrusted()
        if granted != isGranted {
            isGranted = granted
        }
        if granted {
            stopRechecking()
        }
    }

    /// Shows the system prompt the first time, then goes to System Settings.
    ///
    /// The prompt is worth trying first — it explains itself and offers its own way through
    /// — but macOS suppresses it once the user has dismissed it, so a button wired only to
    /// the prompt eventually stops doing anything visible.
    func request() {
        if mustUseSystemSettings {
            openSystemSettings()
        } else {
            mustUseSystemSettings = true
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
        startRechecking()
    }

    func openSystemSettings() {
        // See InputMonitoringAccess.openSystemSettings — same fallback, one level out.
        let deepLink = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        let pane = URL(string: "x-apple.systempreferences:com.apple.preference.security")
        guard let url = deepLink ?? pane else { return }
        if !NSWorkspace.shared.open(url), let pane {
            NSWorkspace.shared.open(pane)
        }
    }

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
