//
//  MenuBarPanel.swift
//  Hamaster
//

import SwiftUI

/// The whole user interface. Hamaster is a menu bar utility, so there is no main window —
/// the panel opens under the status item, does its job, and goes away.
struct MenuBarPanel: View {
    @EnvironmentObject private var appState: AppState

    /// The panel grows with the user's text size. A fixed width under Accessibility ▸
    /// Larger Text is what turns a roomy layout into a cramped one, because the labels
    /// scale and the box they sit in doesn't.
    @ScaledMetric(relativeTo: .body) private var width: CGFloat = Panel.width

    var body: some View {
        MenuPanelLayout(width: width) {
            VStack(alignment: .leading, spacing: Panel.groupSpacing) {
                permissionCards
                devices
            }
        } footer: {
            footer
        }
        .onAppear { appState.refresh() }
    }

    // MARK: - Permissions

    @ViewBuilder
    private var permissionCards: some View {
        if appState.isTouchUnavailable {
            PermissionCard(
                title: "Touch surfaces unavailable",
                message: "macOS didn't provide access to multitouch data on this system, so the touch features can't run.",
                isRequired: true
            )
        }

        if !appState.accessibility.isGranted {
            PermissionCard(
                title: "Accessibility required",
                message: "Hamaster moves the pointer and sends gestures on your behalf, which macOS only allows with Accessibility access.",
                isRequired: true,
                action: { appState.accessibility.request() },
                actionTitle: Self.grantTitle(opensSettings: appState.accessibility.mustUseSystemSettings)
            )
        } else if !appState.inputMonitoring.isGranted {
            PermissionCard(
                title: "Input Monitoring recommended",
                message: "Optional. It lets Hamaster tell your Magic Mouse apart from other pointing devices, which the Separated mode and movement blocking need.",
                isRequired: false,
                action: { appState.inputMonitoring.request() },
                actionTitle: Self.grantTitle(opensSettings: appState.inputMonitoring.mustUseSystemSettings)
            )
        }
    }

    /// The button says what it is about to do. Once the system prompt is spent, "Grant
    /// Access…" is a promise macOS will not keep — the grant can only be made in Settings.
    private static func grantTitle(opensSettings: Bool) -> String {
        opensSettings ? "Open System Settings…" : "Grant Access…"
    }

    // MARK: - Devices

    @ViewBuilder
    private var devices: some View {
        if appState.registry.mice.isEmpty {
            emptyState
        } else {
            // Wider than the spacing inside a card, so two connected mice read as two
            // things rather than one long list of switches.
            VStack(alignment: .leading, spacing: Panel.groupSpacing) {
                ForEach(Array(appState.registry.mice.enumerated()), id: \.element.id) { index, mouse in
                    if index > 0 { Divider() }
                    MouseCard(
                        mouse: mouse,
                        isActive: appState.coordinator.activeDeviceKeys.contains(mouse.deviceKey),
                        canAttributeDevices: appState.inputMonitoring.isGranted
                    )
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: Panel.captionSpacing) {
            Label("No Magic Mouse connected", systemImage: "magicmouse")
                .font(.headline)
            Text("Hamaster only works with Apple's Magic Mouse. Connect one and its settings will appear here.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Footer

    /// One row: the setting on the left edge every other control shares, the command as an
    /// ordinary push button on the right. A plain Button also brings its own focus ring,
    /// pressed state and keyboard activation, which a hand-built menu row has to imitate.
    private var footer: some View {
        VStack(alignment: .leading, spacing: Panel.captionSpacing) {
            HStack(alignment: .center) {
                SettingToggle("Open at login", isOn: Binding(
                    get: { appState.launchAtLogin.isEnabled },
                    set: { appState.launchAtLogin.isEnabled = $0 }
                ))

                Spacer(minLength: 12)

                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut("q", modifiers: .command)
                .help("Quit Hamaster (⌘Q)")
            }

            if let message = appState.launchAtLogin.errorMessage {
                InlineNote(text: message, systemImage: "exclamationmark.triangle", isWarning: true)
            }
        }
    }
}
