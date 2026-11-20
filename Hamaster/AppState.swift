//
//  AppState.swift
//  Hamaster
//

import Combine
import Foundation

/// Owns every long-lived service. Created once at launch and held by the App, so the touch
/// engine and event tap keep running whether or not the menu bar panel is open.
@MainActor
final class AppState: ObservableObject {
    let catalog: MultitouchCatalog
    let registry: MagicMouseRegistry
    let store: SettingsStore
    let accessibility: AccessibilityAccess
    let inputMonitoring: InputMonitoringAccess
    let launchAtLogin: LaunchAtLogin
    let coordinator: TouchEngineCoordinator
    let interceptor: InputInterceptor

    private let bridge = InputBridge()
    private let tracker = PointerActivityTracker()
    private let snapshot = SettingsSnapshot()
    private var cancellables = Set<AnyCancellable>()

    init() {
        let catalog = MultitouchCatalog()
        let registry = MagicMouseRegistry(catalog: catalog)
        let store = SettingsStore()
        let accessibility = AccessibilityAccess()

        self.catalog = catalog
        self.registry = registry
        self.store = store
        self.accessibility = accessibility
        self.inputMonitoring = InputMonitoringAccess()
        self.launchAtLogin = LaunchAtLogin()
        self.coordinator = TouchEngineCoordinator(
            registry: registry,
            store: store,
            accessibility: accessibility,
            bridge: bridge,
            tracker: tracker,
            snapshot: snapshot
        )
        self.interceptor = InputInterceptor(
            registry: registry,
            store: store,
            accessibility: accessibility,
            bridge: bridge,
            tracker: tracker
        )

        // SwiftUI observes AppState's own objectWillChange, not that of nested services, so
        // forward the children's. Without this the menu bar panel — which has no other
        // subscription — never notices a mouse connecting or a setting changing.
        let children: [ObservableObjectPublisher] = [
            registry.objectWillChange,
            store.objectWillChange,
            accessibility.objectWillChange,
            inputMonitoring.objectWillChange,
            launchAtLogin.objectWillChange,
            coordinator.objectWillChange,
            interceptor.objectWillChange,
        ]
        for publisher in children {
            publisher
                .receive(on: RunLoop.main)
                .sink { [weak self] in self?.objectWillChange.send() }
                .store(in: &cancellables)
        }
    }

    /// True when the private multitouch framework couldn't be loaded at all — the one
    /// failure the user can do nothing about, so it's worth saying plainly.
    var isTouchUnavailable: Bool { !catalog.isBridgeAvailable }

    /// Re-scans for touch surfaces. Cheap, and worth doing whenever the panel opens: a
    /// mouse that reconnected while the panel was closed shows up immediately.
    func refresh() {
        registry.refreshTouchSurfaces()
        accessibility.refresh()
        inputMonitoring.refresh()
        launchAtLogin.refresh()
    }
}
