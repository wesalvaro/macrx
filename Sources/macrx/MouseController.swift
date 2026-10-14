import AppKit
import CoreGraphics
import MacrxCore

/// Mouse warping and focus-follows-mouse.
@MainActor
final class MouseController {
    /// Called with the current pointer location (AX coordinates) when it moves into a
    /// different region than before. The receiver decides whether that changes focus.
    var onPointerMoved: ((CGPoint) -> Void)?

    private var monitor: Any?
    private var suppressUntil = Date.distantPast
    private var lastHandled = Date.distantPast
    private let throttle: TimeInterval = 0.08
    private let suppression: TimeInterval = 0.3

    func startFollowing() {
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            MainActor.assumeIsolated { self?.pointerMoved() }
        }
    }

    func stopFollowing() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    /// Current pointer location in AX coordinates.
    var location: CGPoint { CoordinateSpace.toAX(NSEvent.mouseLocation) }

    /// Moves the pointer to `point` (AX coordinates) and suppresses focus-follows-mouse briefly,
    /// so the warp itself never triggers a focus change.
    func warp(to point: CGPoint) {
        suppress()
        CGWarpMouseCursorPosition(point)
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    /// Ignore pointer motion for a short while (after programmatic focus/layout changes).
    func suppress() {
        suppressUntil = Date().addingTimeInterval(suppression)
    }

    private func pointerMoved() {
        let now = Date()
        if now < suppressUntil {
            // Re-evaluate once the suppression window closes, in case the pointer came to rest
            // over a different window while we were ignoring motion.
            scheduleRecheck(after: suppressUntil.timeIntervalSince(now) + 0.01)
            return
        }
        guard now.timeIntervalSince(lastHandled) >= throttle else {
            scheduleRecheck(after: throttle)
            return
        }
        lastHandled = now
        onPointerMoved?(location)
    }

    private var recheck: DispatchWorkItem?

    private func scheduleRecheck(after delay: TimeInterval) {
        guard recheck == nil else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.recheck = nil
            self.pointerMoved()
        }
        recheck = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }
}
