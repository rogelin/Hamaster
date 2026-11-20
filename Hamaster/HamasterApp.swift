//
//  HamasterApp.swift
//  Hamaster
import SwiftUI

@main
struct HamasterApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuBarPanel()
                .environmentObject(appState)
        } label: {
            // Filled while a touch surface is being read, outline while idle, so the state
            // of the app is legible from the menu bar without opening anything.
            Image(systemName: appState.coordinator.activeDeviceKeys.isEmpty ? "magicmouse" : "magicmouse.fill")
                .accessibilityLabel("Hamaster")
        }
        // A window rather than a menu: the panel holds sliders and segmented controls,
        // which a real NSMenu can't host.
        .menuBarExtraStyle(.window)
    }
}
