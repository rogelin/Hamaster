//
//  MomentumScroller.swift
//  Hamaster
//

import Foundation

/// Keeps scrolling after the fingers lift, decaying to a stop.
///
/// A trackpad's glide isn't produced by the hardware — the system generates it, tagged with
/// a momentum phase, once the gesture ends. Apps use that tag to decide when to rubber-band
/// at the end of a document, so scrolling without it stops dead and never bounces. This
/// reproduces both: the decaying glide, and the phases that make apps treat it as one.
final class MomentumScroller: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.hamaster.Hamaster.momentum", qos: .userInteractive)
    private let lock = NSLock()
    private let accumulator = ScrollAccumulator()
    private var timer: DispatchSourceTimer?
    private let output: any TouchEventOutput

    /// Current glide velocity in points per second.
    private var velocityX: Double = 0
    private var velocityY: Double = 0
    private var hasEmittedBegin = false

    private let tickInterval = 1.0 / 120.0
    /// Per-tick decay. At 120Hz this bleeds off over roughly a second and a half, which is
    /// about how long a trackpad flick coasts.
    private let decay = 0.968
    /// Below this the glide is no longer visible, so it ends rather than trickling on.
    private let stopSpeed = 8.0
    /// A flick slower than this was a deliberate stop, not a throw — no glide at all.
    private let minimumLaunchSpeed = 90.0

    init(output: any TouchEventOutput = SystemTouchEventOutput()) {
        self.output = output
    }

    /// Begins a glide from the velocity the fingers had when they left the surface.
    func launch(velocityX: Double, velocityY: Double) {
        let speed = (velocityX * velocityX + velocityY * velocityY).squareRoot()
        guard speed >= minimumLaunchSpeed else {
            cancel()
            return
        }

        lock.lock()
        self.velocityX = velocityX
        self.velocityY = velocityY
        hasEmittedBegin = false
        accumulator.reset()
        lock.unlock()

        startTimer()
    }

    /// Stops any glide in progress, closing it out properly so apps don't stay stuck in a
    /// momentum phase. Called when new fingers land, which is what makes tapping the surface
    /// halt a coasting scroll the way it does on a trackpad.
    func cancel() {
        lock.lock()
        let wasRunning = timer != nil
        timer?.cancel()
        timer = nil
        velocityX = 0
        velocityY = 0
        let needsEnd = hasEmittedBegin
        hasEmittedBegin = false
        lock.unlock()

        if wasRunning, needsEnd {
            output.scroll(dx: 0, dy: 0, phase: .momentumEnded, flags: [])
        }
    }

    private func startTimer() {
        lock.lock()
        timer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + tickInterval, repeating: tickInterval)
        timer.setEventHandler { [weak self] in self?.tick() }
        self.timer = timer
        lock.unlock()
        timer.resume()
    }

    private func tick() {
        lock.lock()
        velocityX *= decay
        velocityY *= decay
        let vx = velocityX
        let vy = velocityY
        let speed = (vx * vx + vy * vy).squareRoot()
        let isFirst = !hasEmittedBegin
        if speed < stopSpeed {
            timer?.cancel()
            timer = nil
            let needsEnd = hasEmittedBegin
            hasEmittedBegin = false
            lock.unlock()
            // Only close a momentum phase that actually opened. A glide too slow to ever
            // produce a whole pixel emits nothing, and an unmatched end would leave apps
            // reacting to a gesture they never saw start.
            if needsEnd {
                output.scroll(dx: 0, dy: 0, phase: .momentumEnded, flags: [])
            }
            return
        }
        let step = accumulator.take(dx: vx * tickInterval, dy: vy * tickInterval)
        if step != nil { hasEmittedBegin = true }
        lock.unlock()

        guard let step else { return }
        output.scroll(
            dx: step.dx,
            dy: step.dy,
            phase: isFirst ? .momentumBegan : .momentumChanged,
            flags: []
        )
    }
}
