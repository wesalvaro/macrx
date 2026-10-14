import AppKit
import MacrxCore

/// Converts between AppKit screen coordinates (bottom-left origin of the primary
/// display, y up) and the Accessibility / CoreGraphics coordinate space used by
/// MacrxCore (top-left origin of the primary display, y down).
enum CoordinateSpace {
    /// Height of the primary display's full frame — the flip axis.
    static var primaryHeight: CGFloat {
        NSScreen.screens.first?.frame.height ?? 0
    }

    static func toAX(_ r: NSRect) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    static func toAX(_ p: NSPoint) -> CGPoint {
        CGPoint(x: p.x, y: primaryHeight - p.y)
    }

    static func toAppKit(_ r: CGRect) -> NSRect {
        NSRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }
}
