//
//  MouseSettings.swift
//  Hamaster
//

import Foundation

/// Six discrete sensitivity steps rather than a continuous slider: a free-running slider
/// on a touch surface this small is impossible to set reproducibly, and the useful range
/// is narrow enough that six well-chosen stops cover it.
enum Sensitivity: Int, Codable, CaseIterable, Identifiable {
    case one = 0, two, three, four, five, six

    var id: Int { rawValue }

    /// Multiplies the base surface-to-screen mapping (see TouchEngine.pointerScale).
    var multiplier: Double {
        switch self {
        case .one: 0.45
        case .two: 0.7
        case .three: 1.0
        case .four: 1.45
        case .five: 2.1
        case .six: 3.0
        }
    }

    var label: String { String(rawValue + 1) }
}

/// How finger movement on the touch surface combines with physically sliding the mouse.
enum MovementMode: String, Codable, CaseIterable, Identifiable {
    /// Both apply at once, with light filtering — the responsive default.
    case merged
    /// Merged, but heavily filtered with a dead zone, so a shaking or resting hand can't
    /// move the pointer. Trades a little responsiveness for steadiness.
    case smoothed
    /// Touch yields: while the mouse is physically moving, finger movement is ignored.
    case separated

    var id: String { rawValue }

    var label: String {
        switch self {
        case .merged: "Merged"
        case .smoothed: "Smoothed"
        case .separated: "Separated"
        }
    }

    var explanation: String {
        switch self {
        case .merged: "Finger and mouse movement both move the pointer."
        case .smoothed: "Merged, with extra filtering for an unsteady hand."
        case .separated: "Finger movement pauses while you slide the mouse."
        }
    }
}

/// How a pinch is delivered to the app under the cursor.
enum ZoomMethod: String, Codable, CaseIterable, Identifiable {
    /// A real magnification gesture event — what a trackpad pinch sends. Reaches Maps,
    /// Photos, Preview and every app with native pinch support.
    case pinchGesture
    /// ⌘ + scroll wheel. Not a real pinch, but understood by browsers, Preview, Finder
    /// and most editors, and built entirely from public API.
    case commandScroll

    var id: String { rawValue }

    var label: String {
        switch self {
        case .pinchGesture: "Pinch gesture"
        case .commandScroll: "⌘ + scroll"
        }
    }
}

/// Everything configurable for one physical Magic Mouse.
struct MouseSettings: Codable, Equatable {
    var deviceKey: String
    var displayName: String

    /// The single safe way to pause every Hamaster feature for this mouse while preserving
    /// the user's pointer and gesture choices underneath it.
    var isEnabled = false

    // MARK: Touch surface as trackpad

    /// One finger moves the pointer, two fingers scroll — the headline feature.
    var touchpadEnabled = true
    var sensitivity: Sensitivity = .three
    var movementMode: MovementMode = .smoothed

    /// Discards the mouse's own movement entirely, so the pointer is driven only by the
    /// touch surface. For people who can reach the surface but not slide the whole mouse.
    var ignorePhysicalMovement = false

    // MARK: Gestures

    /// Clicking with two fingers on the surface produces a secondary (right) click.
    var twoFingerSecondaryClick = true
    /// Three fingers up → Mission Control, three fingers down → App Exposé.
    var threeFingerSwipes = true
    /// Two fingers moving apart / together zooms.
    var pinchToZoom = true
    var zoomMethod: ZoomMethod = .pinchGesture
    /// Double-tapping with one finger sends a smart-zoom gesture. Off by default because
    /// macOS ships the same gesture for Magic Mouse and the two would cancel each other.
    var smartZoom = false

    init(deviceKey: String, displayName: String) {
        self.deviceKey = deviceKey
        self.displayName = displayName
    }

    // MARK: Effective state

    var pointerActive: Bool { isEnabled && touchpadEnabled }
    var secondaryClickActive: Bool { isEnabled && twoFingerSecondaryClick }
    var threeFingerSwipesActive: Bool { isEnabled && threeFingerSwipes }
    var pinchToZoomActive: Bool { isEnabled && pinchToZoom }
    var smartZoomActive: Bool { isEnabled && smartZoom }

    var needsTouchStream: Bool {
        isEnabled && (touchpadEnabled || twoFingerSecondaryClick || threeFingerSwipes || pinchToZoom || smartZoom)
    }

    var needsEventTap: Bool {
        isEnabled && (touchpadEnabled || twoFingerSecondaryClick || pinchToZoom || smartZoom)
    }

    /// Whether the mouse's own movement is actually being discarded.
    ///
    /// Deliberately gated on the touch surface also driving the pointer. Without that
    /// coupling, switching the trackpad off while this was on would leave a mouse that
    /// cannot move the pointer at all and no visible control to undo it — the setting is
    /// only offered alongside the trackpad switch, so it must not outlive it.
    var blocksPhysicalMovement: Bool {
        pointerActive && ignorePhysicalMovement
    }

    // MARK: Resilient persistence

    /// Decode each preference independently so adding a setting in a future release cannot
    /// invalidate the entire per-mouse settings blob. `isEnabled` intentionally migrates
    /// from the old meaning of `touchpadEnabled`, which used to be the master switch.
    private enum CodingKeys: String, CodingKey {
        case deviceKey, displayName, isEnabled, touchpadEnabled, sensitivity, movementMode
        case ignorePhysicalMovement, twoFingerSecondaryClick, threeFingerSwipes
        case pinchToZoom, zoomMethod, smartZoom
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        deviceKey = try values.decode(String.self, forKey: .deviceKey)
        displayName = try values.decodeIfPresent(String.self, forKey: .displayName) ?? "Magic Mouse"

        let legacyTouchpadEnabled = try values.decodeIfPresent(Bool.self, forKey: .touchpadEnabled)
        isEnabled = try values.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? legacyTouchpadEnabled ?? false
        touchpadEnabled = legacyTouchpadEnabled ?? true
        sensitivity = try values.decodeIfPresent(Sensitivity.self, forKey: .sensitivity) ?? .three
        movementMode = try values.decodeIfPresent(MovementMode.self, forKey: .movementMode) ?? .smoothed
        ignorePhysicalMovement = try values.decodeIfPresent(Bool.self, forKey: .ignorePhysicalMovement) ?? false
        twoFingerSecondaryClick = try values.decodeIfPresent(Bool.self, forKey: .twoFingerSecondaryClick) ?? true
        threeFingerSwipes = try values.decodeIfPresent(Bool.self, forKey: .threeFingerSwipes) ?? true
        pinchToZoom = try values.decodeIfPresent(Bool.self, forKey: .pinchToZoom) ?? true
        zoomMethod = try values.decodeIfPresent(ZoomMethod.self, forKey: .zoomMethod) ?? .pinchGesture
        smartZoom = try values.decodeIfPresent(Bool.self, forKey: .smartZoom) ?? false
    }
}
