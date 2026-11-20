import SwiftUI

/// Presentation is separate from hardware so every menu state can be previewed.
struct MouseSettingsView: View {
    let name: String
    let connection: String
    var hasTouchSurface = true
    var isActive = true
    var hasAccessibility = true
    var canAttributeDevices = true
    var isEventTapRunning = true
    var systemSmartZoomEnabled = false
    @Binding var settings: MouseSettings

    private var status: MousePanelStatus {
        MousePanelStatus.resolve(
            isEnabled: settings.isEnabled, hasTouchSurface: hasTouchSurface,
            hasAccessibility: hasAccessibility, isActive: isActive
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Panel.groupSpacing) {
            header
            SettingToggle("Enable Hamaster", isOn: $settings.isEnabled)
                .help("Pause or resume all Hamaster features for this mouse.")

            if !hasTouchSurface {
                InlineNote(text: "Touch surface unavailable. Reconnect your mouse to try again.",
                           systemImage: "exclamationmark.triangle", isWarning: true)
            } else {
                if !settings.isEnabled {
                    SettingCaption(text: "Paused. Your settings are saved for when you enable Hamaster again.")
                }
                VStack(alignment: .leading, spacing: Panel.groupSpacing) {
                    pointerSection
                    gesturesSection
                }
                .disabled(!settings.isEnabled)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "magicmouse.fill")
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 36)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(name)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                Text(connection).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Text(status.rawValue)
                .font(.caption.weight(.medium))
                .foregroundStyle(status == .active ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.quaternary, in: Capsule())
                .fixedSize()
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private var pointerSection: some View {
        SettingsGroup("Pointer") {
            SettingToggle("Touch surface as trackpad", isOn: $settings.touchpadEnabled)
                .help("One finger moves the pointer; two fingers scroll.")

            if settings.touchpadEnabled {
                Divider()
                sensitivitySlider
                movementPicker
                VStack(alignment: .leading, spacing: Panel.captionSpacing) {
                    SettingToggle("Ignore mouse movement", isOn: $settings.ignorePhysicalMovement)
                        .disabled(!canAttributeDevices)
                        .help("Use only the touch surface to move the pointer.")
                        .accessibilityHint(canAttributeDevices
                            ? "Use only the touch surface to move the pointer."
                            : "Requires Input Monitoring access.")
                    if !canAttributeDevices {
                        InlineNote(text: "Requires Input Monitoring access.")
                    } else if settings.ignorePhysicalMovement && !isEventTapRunning {
                        InlineNote(text: "Movement blocking is unavailable. Check Accessibility access.",
                                   systemImage: "exclamationmark.triangle", isWarning: true)
                    }
                }
            }
        }
    }

    private var sensitivitySlider: some View {
        VStack(alignment: .leading, spacing: Panel.captionSpacing) {
            HStack {
                Text("Sensitivity")
                Spacer()
                Text("\(settings.sensitivity.label) / \(Sensitivity.allCases.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            Slider(value: Binding(
                get: { Double(settings.sensitivity.rawValue) },
                set: { if let step = Sensitivity(rawValue: Int($0.rounded())) { settings.sensitivity = step } }
            ), in: 0...Double(Sensitivity.allCases.count - 1), step: 1) {
                Text("Sensitivity")
            } minimumValueLabel: {
                Text("Slow").font(.caption).foregroundStyle(.secondary)
            } maximumValueLabel: {
                Text("Fast").font(.caption).foregroundStyle(.secondary)
            }
            .labelsHidden()
            .accessibilityLabel("Pointer sensitivity")
            .accessibilityValue("Step \(settings.sensitivity.label) of \(Sensitivity.allCases.count)")
        }
    }

    private var movementPicker: some View {
        VStack(alignment: .leading, spacing: Panel.captionSpacing) {
            Text("Movement")
            Picker("Movement", selection: $settings.movementMode) {
                ForEach(MovementMode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("Pointer movement")
            .accessibilityHint(settings.movementMode.explanation)
            SettingCaption(text: settings.movementMode.explanation)
            if settings.movementMode == .separated && !canAttributeDevices {
                InlineNote(text: "Requires Input Monitoring to detect mouse movement.")
            }
        }
    }

    private var gesturesSection: some View {
        SettingsGroup("Gestures") {
            SettingToggle("Two-finger secondary click", isOn: $settings.twoFingerSecondaryClick)
                .help("Click with two fingers resting on the surface to right-click.")
            SettingToggle("Three-finger swipe", isOn: $settings.threeFingerSwipes)
                .help("Swipe up for Mission Control; down for App Exposé.")
            VStack(alignment: .leading, spacing: Panel.rowSpacing) {
                SettingToggle("Pinch to zoom", isOn: $settings.pinchToZoom)
                if settings.pinchToZoom {
                    HStack(spacing: 12) {
                        Text("Zoom method").foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        Picker("Zoom method", selection: $settings.zoomMethod) {
                            ForEach(ZoomMethod.allCases) { Text($0.label).tag($0) }
                        }
                        .labelsHidden()
                        .accessibilityLabel("Zoom method")
                        .fixedSize()
                    }
                    .help("Try ⌘ + scroll in apps that don't support pinch gestures.")
                }
            }
            VStack(alignment: .leading, spacing: Panel.captionSpacing) {
                SettingToggle("Double-tap smart zoom", isOn: $settings.smartZoom)
                if settings.smartZoom && systemSmartZoomEnabled {
                    InlineNote(text: "Turn off smart zoom in System Settings → Mouse to avoid sending it twice.",
                               systemImage: "exclamationmark.triangle", isWarning: true)
                }
            }
        }
    }
}
