import SwiftUI

/// Connects the reusable settings view to the device and its persisted preferences.
struct MouseCard: View {
    let mouse: MagicMouse
    let isActive: Bool
    let canAttributeDevices: Bool
    @EnvironmentObject private var appState: AppState

    var body: some View {
        MouseSettingsView(
            name: mouse.displayName,
            connection: mouse.connectionDescription,
            hasTouchSurface: mouse.session != nil,
            isActive: isActive,
            hasAccessibility: appState.accessibility.isGranted,
            canAttributeDevices: canAttributeDevices,
            isEventTapRunning: appState.interceptor.isTapInstalled,
            systemSmartZoomEnabled: SystemPreferences.systemSmartZoomEnabled,
            settings: Binding(
                get: { appState.store.settings(for: mouse) },
                set: { appState.store.update($0) }
            )
        )
    }
}
