// Compile with MouseSettings.swift, MousePanelStatus.swift, PanelChrome.swift,
// MouseSettingsView.swift and PermissionCard.swift. No device access or saved preferences.
import AppKit
import SwiftUI

struct MenuFixture: View {
    let variant: Int
    let dark: Bool

    var settings: MouseSettings {
        var s = MouseSettings(deviceKey: "preview", displayName: "Magic Mouse")
        s.isEnabled = variant != 1
        s.touchpadEnabled = variant != 2
        s.pinchToZoom = variant != 7
        s.smartZoom = variant == 6
        s.ignorePhysicalMovement = variant == 5 || variant == 10
        s.zoomMethod = variant == 2 ? .commandScroll : .pinchGesture
        s.sensitivity = variant == 2 ? .six : .three
        if variant == 11 {
            s.touchpadEnabled = false
            s.twoFingerSecondaryClick = false
            s.threeFingerSwipes = false
            s.pinchToZoom = false
        }
        s.movementMode = variant == 5 ? .separated : variant == 2 ? .merged : .smoothed
        return s
    }

    var body: some View {
        MenuPanelLayout {
            VStack(alignment: .leading, spacing: Panel.groupSpacing) {
                if variant == 8 {
                    Label("No Magic Mouse connected", systemImage: "magicmouse").font(.headline)
                    SettingCaption(text: "Connect an Apple Magic Mouse to configure its pointer and gestures.")
                } else {
                    if variant == 4 {
                        PermissionCard(title: "Accessibility required", message: "Allow Hamaster to move the pointer and send gestures.",
                                       isRequired: true, action: {}, actionTitle: "Open System Settings…")
                    }
                    MouseSettingsView(
                        name: variant == 6 ? "My very long custom Magic Mouse name" : "Rogelin’s Magic Mouse",
                        connection: "Bluetooth", hasTouchSurface: variant != 3,
                        isActive: ![1, 3, 4, 7, 11].contains(variant), hasAccessibility: variant != 4,
                        canAttributeDevices: variant != 5, isEventTapRunning: variant != 10, systemSmartZoomEnabled: variant == 6,
                        settings: .constant(settings)
                    )
                    if variant == 9 {
                        Divider()
                        MouseSettingsView(name: "Second Magic Mouse", connection: "USB", settings: .constant(settings))
                    }
                }
            }
        } footer: {
            HStack {
                SettingToggle("Open at login", isOn: .constant(false))
                Spacer(minLength: 12)
                Button("Quit") {}
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.colorScheme, dark ? .dark : .light)
        .environment(\.controlActiveState, .active)
    }
}

@main
struct RenderMenu {
    @MainActor static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let output = CommandLine.arguments[1]
        try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
        for dark in [false, true] {
            for variant in 0...11 {
                let view = NSHostingView(rootView: MenuFixture(variant: variant, dark: dark))
                view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                let size = view.fittingSize
                view.frame = NSRect(origin: .zero, size: size)
                let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.contentView = view
                view.layoutSubtreeIfNeeded()
                guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { fatalError("No bitmap") }
                view.cacheDisplay(in: view.bounds, to: bitmap)
                let data = bitmap.representation(using: .png, properties: [:])!
                try data.write(to: URL(fileURLWithPath: "\(output)/\(dark ? "dark" : "light")-\(variant).png"))
                print("\(dark ? "dark" : "light")-\(variant): \(size)")
            }
        }
    }
}
