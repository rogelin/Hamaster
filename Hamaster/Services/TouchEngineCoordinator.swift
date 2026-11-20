//
//  TouchEngineCoordinator.swift
//  Hamaster
//

import Combine
import Foundation

/// Starts and stops one `TouchEngine` per Magic Mouse, following the settings.
///
/// Nothing subscribes to a touch surface unless that mouse actually has a touch feature
/// switched on, so with everything off the multitouch stream isn't running at all and the
/// app costs nothing.
@MainActor
final class TouchEngineCoordinator: ObservableObject {
    /// Mice whose touch surface is currently being read — drives the "active" state in the UI.
    @Published private(set) var activeDeviceKeys: Set<String> = []

    private let bridge: InputBridge
    private let tracker: PointerActivityTracker
    private let snapshot: SettingsSnapshot

    private struct Running {
        let engine: TouchEngine
        let session: MultitouchDeviceSession
        let token: UUID
    }

    private var running: [String: Running] = [:]
    private var cancellables = Set<AnyCancellable>()

    init(
        registry: MagicMouseRegistry,
        store: SettingsStore,
        accessibility: AccessibilityAccess,
        bridge: InputBridge,
        tracker: PointerActivityTracker,
        snapshot: SettingsSnapshot
    ) {
        self.bridge = bridge
        self.tracker = tracker
        self.snapshot = snapshot

        Publishers.CombineLatest3(registry.$mice, store.$settings, accessibility.$isGranted)
            .sink { [weak self] mice, settings, isGranted in
                self?.reconcile(mice: mice, settings: settings, isGranted: isGranted)
            }
            .store(in: &cancellables)
    }

    private func reconcile(mice: [MagicMouse], settings: [String: MouseSettings], isGranted: Bool) {
        snapshot.update(settings)

        // Everything the engine does ends in a synthesised event, which needs Accessibility.
        // Without it there's no point reading the surface at all.
        var wanted: [String: MultitouchDeviceSession] = [:]
        if isGranted {
            for mouse in mice {
                guard let session = mouse.session,
                      settings[mouse.deviceKey]?.needsTouchStream == true else { continue }
                wanted[mouse.deviceKey] = session
            }
        }

        for (key, current) in running where wanted[key] !== current.session {
            current.session.removeHandler(current.token)
            current.engine.shutDown()
            running.removeValue(forKey: key)
        }

        for (key, session) in wanted where running[key] == nil {
            let engine = TouchEngine(
                deviceKey: key,
                bridge: bridge,
                tracker: tracker,
                snapshot: snapshot,
                surfaceWidthMM: session.surfaceSizeMillimetres?.width ?? 51.5,
                aspectRatio: session.surfaceAspectRatio
            )
            let token = session.addHandler { [engine] contacts in
                engine.process(contacts)
            }
            running[key] = Running(engine: engine, session: session, token: token)
        }

        activeDeviceKeys = Set(running.keys)
    }
}
