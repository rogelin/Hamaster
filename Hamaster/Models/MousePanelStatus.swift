/// Status describes the effective service state, rather than just the saved switch.
enum MousePanelStatus: String {
    case paused = "Paused"
    case unavailable = "Unavailable"
    case needsAccess = "Needs access"
    case active = "Active"
    case idle = "Idle"

    static func resolve(isEnabled: Bool, hasTouchSurface: Bool,
                        hasAccessibility: Bool, isActive: Bool) -> Self {
        guard hasTouchSurface else { return .unavailable }
        guard isEnabled else { return .paused }
        guard hasAccessibility else { return .needsAccess }
        return isActive ? .active : .idle
    }
}
