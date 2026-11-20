//
//  LaunchAtLogin.swift
//  Hamaster
//

import Combine
import Foundation
import ServiceManagement

@MainActor
final class LaunchAtLogin: ObservableObject {
    @Published private(set) var errorMessage: String?
    @Published var isEnabled: Bool {
        didSet {
            guard !isRefreshing, isEnabled != oldValue else { return }
            apply()
        }
    }

    private var isRefreshing = false

    init() {
        isEnabled = SMAppService.mainApp.status == .enabled
    }

    func refresh() {
        isRefreshing = true
        isEnabled = SMAppService.mainApp.status == .enabled
        isRefreshing = false
        if isEnabled { errorMessage = nil }
    }

    private func apply() {
        errorMessage = nil
        do {
            if isEnabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Revert the toggle if the system refused (e.g. app not in /Applications yet).
            refresh()
            errorMessage = "macOS couldn’t update Open at Login. Move Hamaster to Applications and try again."
        }
    }
}
