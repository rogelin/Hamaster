//
//  TouchContact.swift
//  Hamaster
//

import Foundation

struct TouchVector: Hashable, Codable {
    var x: Double
    var y: Double
}

/// Mirrors the private framework's MTTouchState values exactly (see PrivateMultitouchBridge).
enum TouchContactState: Int, Hashable, Codable, CaseIterable {
    case notTracking = 0
    case starting = 1
    case hovering = 2
    case making = 3
    case touching = 4
    case breaking = 5
    case lingering = 6
    case outOfRange = 7
    case unknown = -1

    init(rawState: Int32) {
        self = TouchContactState(rawValue: Int(rawState)) ?? .unknown
    }
}

/// Full-fidelity decoded multitouch contact, mirroring the framework's MTTouch struct.
struct TouchContact: Identifiable, Hashable, Codable {
    var id: Int32 { identifier }

    let identifier: Int32
    let frame: Int32
    let timestamp: TimeInterval
    let state: TouchContactState
    let normalizedPosition: TouchVector
    let normalizedVelocity: TouchVector
    let majorAxis: Double
    let minorAxis: Double
    let angle: Double
    let totalCapacitance: Double
    let pressure: Double
    let density: Double
}
