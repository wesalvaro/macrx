import AppKit
import MacrxCore

/// Publishes the connected displays as `Display` values in AX coordinates.
@MainActor
final class DisplayManager {
    private(set) var displays: [Display] = []
    /// Full (not just visible) frame per display, in AX coordinates. Used to park hidden windows.
    private(set) var fullFrames: [DisplayID: CGRect] = [:]
    var onChange: (([Display]) -> Void)?
    private var observer: NSObjectProtocol?

    init() {
        refresh()
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let before = self.displays
                self.refresh()
                if before != self.displays { self.onChange?(self.displays) }
            }
        }
    }

    func refresh() {
        var result: [Display] = []
        var full: [DisplayID: CGRect] = [:]
        for screen in NSScreen.screens {
            guard let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
            let id = DisplayID(num.uint32Value)
            result.append(Display(id: id, frame: CoordinateSpace.toAX(screen.visibleFrame)))
            full[id] = CoordinateSpace.toAX(screen.frame)
        }
        displays = result
        fullFrames = full
    }

    func display(containing point: CGPoint) -> Display? {
        displays.first { $0.frame.contains(point) }
            ?? displays.min { a, b in a.frame.center.distance(to: point) < b.frame.center.distance(to: point) }
    }
}

extension CGPoint {
    func distance(to other: CGPoint) -> CGFloat {
        let dx = x - other.x, dy = y - other.y
        return (dx * dx + dy * dy).squareRoot()
    }
}
