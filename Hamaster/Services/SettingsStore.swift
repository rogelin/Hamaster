//
//  SettingsStore.swift
//  Hamaster
//

import Combine
import Foundation

/// Per-mouse settings, persisted in UserDefaults as one JSON blob keyed by device.
///
/// Settings survive the mouse being unplugged: the entry is kept after disconnect so that
/// unpairing and re-pairing, or simply letting the battery die, doesn't silently reset a
/// carefully tuned configuration.
@MainActor
final class SettingsStore: ObservableObject {
    @Published private(set) var settings: [String: MouseSettings] = [:]

    private let defaults: UserDefaults
    private let storageKey = "MouseSettings"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([String: MouseSettings].self, from: data) {
            settings = decoded
        }
    }

    func settings(for mouse: MagicMouse) -> MouseSettings {
        settings[mouse.deviceKey] ?? MouseSettings(deviceKey: mouse.deviceKey, displayName: mouse.displayName)
    }

    func update(_ value: MouseSettings) {
        guard settings[value.deviceKey] != value else { return }
        settings[value.deviceKey] = value
        persist()
    }

    /// Mutates in place so a view can bind to a single field without rebuilding the struct.
    func modify(_ mouse: MagicMouse, _ transform: (inout MouseSettings) -> Void) {
        var value = settings(for: mouse)
        value.displayName = mouse.displayName
        transform(&value)
        update(value)
    }

    func reset(_ mouse: MagicMouse) {
        update(MouseSettings(deviceKey: mouse.deviceKey, displayName: mouse.displayName))
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
