//
//  OneEuroFilter.swift
//  Hamaster
//

import Foundation

/// One Euro filter (Casiez, Roussel & Vogel, CHI 2012) — an adaptive low-pass filter for
/// noisy interactive signals.
///
/// A fixed low-pass filter forces a choice between jitter at rest and lag while moving.
/// This one adapts its cutoff to the signal's own speed: heavy smoothing when the finger is
/// nearly still, almost none when it's travelling, so a resting finger stops creeping
/// without making a deliberate slide feel like it's dragging behind.
final class OneEuroFilter {
    /// Lower means more smoothing at rest.
    var minCutoff: Double
    /// Higher means the filter gets out of the way faster as the finger speeds up.
    var beta: Double
    private let derivativeCutoff: Double

    private var lastValue: Double?
    private var lastDerivative: Double = 0
    private var lastTimestamp: Double = 0

    init(minCutoff: Double = 1.0, beta: Double = 0.35, derivativeCutoff: Double = 1.0) {
        self.minCutoff = minCutoff
        self.beta = beta
        self.derivativeCutoff = derivativeCutoff
    }

    func reset() {
        lastValue = nil
        lastDerivative = 0
        lastTimestamp = 0
    }

    func filter(_ value: Double, timestamp: Double) -> Double {
        guard let previous = lastValue else {
            lastValue = value
            lastTimestamp = timestamp
            return value
        }

        // Clamped so a stalled or out-of-order frame can't produce an absurd derivative.
        let dt = min(max(timestamp - lastTimestamp, 1.0 / 240.0), 1.0 / 15.0)
        lastTimestamp = timestamp

        let derivative = (value - previous) / dt
        let smoothedDerivative = lerp(lastDerivative, derivative, alpha(dt: dt, cutoff: derivativeCutoff))
        lastDerivative = smoothedDerivative

        let cutoff = minCutoff + beta * abs(smoothedDerivative)
        let filtered = lerp(previous, value, alpha(dt: dt, cutoff: cutoff))
        lastValue = filtered
        return filtered
    }

    private func alpha(dt: Double, cutoff: Double) -> Double {
        let tau = 1.0 / (2.0 * .pi * cutoff)
        return 1.0 / (1.0 + tau / dt)
    }

    private func lerp(_ from: Double, _ to: Double, _ t: Double) -> Double {
        from + t * (to - from)
    }
}

/// Two independent filters sharing one timestamp, for a 2D contact position.
///
/// Filtering is applied to every movement mode, not just the Smoothed one. Raw capacitive
/// positions shimmer by a pixel or two even under a completely still finger, and that noise
/// is what makes an unfiltered touch pointer feel cheap. The modes differ in *how much*.
final class OneEuroPointFilter {
    private let x = OneEuroFilter()
    private let y = OneEuroFilter()

    func configure(minCutoff: Double, beta: Double) {
        x.minCutoff = minCutoff
        x.beta = beta
        y.minCutoff = minCutoff
        y.beta = beta
    }

    func reset() {
        x.reset()
        y.reset()
    }

    func filter(_ point: TouchVector, timestamp: Double) -> TouchVector {
        TouchVector(x: x.filter(point.x, timestamp: timestamp), y: y.filter(point.y, timestamp: timestamp))
    }
}
