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
    private let throttle: TimeInterval = 0.05
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
        guard now >= suppressUntil, now.timeIntervalSince(lastHandled) >= throttle else { return }
        lastHandled = now
        onPointerMoved?(location)
    }
}
