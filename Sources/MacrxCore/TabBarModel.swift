import Foundation
import CoreGraphics

/// Turns verbose window titles into tab labels.
public enum TitleCleaner {
    /// Removes trailing app-name suffixes such as `" - Google Chrome"`, `" — Safari"`,
    /// `" | Slack"` and Chrome's profile tail `" - Wes (me@example.com)"`.
    /// Falls back to `appName` when nothing meaningful is left.
    public static func clean(_ title: String, appName: String?) -> String {
        var t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let app = appName?.trimmingCharacters(in: .whitespaces), !app.isEmpty {
            let esc = NSRegularExpression.escapedPattern(for: app)
            // "<title> - <App> - <Profile> (<email>)"  (Chrome)
            // "<title> - <App>" / "<title> — <App>" / "<title> | <App>"
            let patterns = [
                #"(?:^|\s+)[-–—|]\s+"# + esc + #"\s+[-–—]\s+[^-–—|]*\([^)]*\)\s*$"#,
                #"(?:^|\s+)[-–—|]\s+"# + esc + #"\s*$"#,
            ]
            for p in patterns {
                if let re = try? NSRegularExpression(pattern: p, options: [.caseInsensitive]) {
                    let range = NSRange(t.startIndex..., in: t)
                    t = re.stringByReplacingMatches(in: t, options: [], range: range, withTemplate: "")
                }
            }
            t = t.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { return app }
        }
        return t.isEmpty ? "Untitled" : t
    }
}

/// Distributes tab widths across a bar.
public enum TabLayout {
    /// Converts widths into x-offsets/rects laid out left to right from `origin`.
    public static func rects(widths: [CGFloat], in bar: CGRect) -> [CGRect] {
        var x = bar.minX
        return widths.map { w in
            defer { x += w }
            return CGRect(x: x, y: bar.minY, width: w, height: bar.height)
        }
    }

    /// Tabs share the bar equally.
    public static func equalWidths(count: Int, available: CGFloat) -> [CGFloat] {
        guard count > 0 else { return [] }
        return Array(repeating: available / CGFloat(count), count: count)
    }

    /// Target index when dragging the tab currently at `currentIndex` to `x` within `rects`.
    /// Swaps only once `x` crosses a neighbour's midpoint, which gives `w_dragged` of hysteresis
    /// and prevents oscillation when variable-width tabs swap places.
    public static func reorderIndex(atX x: CGFloat, currentIndex: Int, in rects: [CGRect]) -> Int {
        guard rects.indices.contains(currentIndex) else { return currentIndex }
        var idx = currentIndex
        while idx + 1 < rects.count, x > rects[idx + 1].midX { idx += 1 }
        while idx - 1 >= 0, x < rects[idx - 1].midX { idx -= 1 }
        return idx
    }

    /// Insertion index `[0...rects.count]` when dropping a tab from another stack at `x`.
    public static func insertionIndex(atX x: CGFloat, in rects: [CGRect]) -> Int {
        rects.firstIndex { x < $0.midX } ?? rects.count
    }

    /// Computes what dropping a dragged tab at `p` (AX coordinates) should do.
    public static func dropTarget(
        at p: CGPoint,
        draggedWindow: WindowID,
        sourceStack: ObjectIdentifier,
        tiles: [Tile],
        tabRects: [ObjectIdentifier: [CGRect]]
    ) -> TabDropTarget? {
        // 1. Tab bars first (with a small vertical band around the source bar for smooth reordering).
        for tile in tiles where tile.hasTabBar {
            let bar = tile.stackID == sourceStack ? tile.tabBar.insetBy(dx: 0, dy: -8) : tile.tabBar
            guard bar.contains(p) else { continue }
            let rects = tabRects[tile.stackID] ?? []
            if tile.stackID == sourceStack {
                let cur = tile.windows.firstIndex(of: draggedWindow) ?? 0
                return .reorder(index: reorderIndex(atX: p.x, currentIndex: cur, in: rects))
            } else {
                return .joinStack(stack: tile.stackID, index: insertionIndex(atX: p.x, in: rects), preview: tile.frame)
            }
        }

        // 2. Tile body: outer 25% splits that tile along the nearest edge; inner 50% joins another tile's stack.
        guard let tile = tiles.first(where: { $0.frame.contains(p) }) else { return nil }
        let c = tile.content
        guard c.width > 0, c.height > 0 else { return nil }
        let rx = max(0, min(1, (p.x - c.minX) / c.width))
        let ry = max(0, min(1, (p.y - c.minY) / c.height))
        let edges: [(Direction, CGFloat)] = [(.left, rx), (.right, 1 - rx), (.up, ry), (.down, 1 - ry)]
        if let (edge, dist) = edges.min(by: { $0.1 < $1.1 }), dist < 0.25 {
            if tile.stackID == sourceStack && tile.windows.count <= 1 { return nil }
            return .splitTile(stack: tile.stackID, edge: edge, preview: splitPreview(of: tile.frame, edge: edge))
        }
        if tile.stackID != sourceStack {
            return .joinStack(stack: tile.stackID, index: nil, preview: tile.frame)
        }
        return nil
    }

    private static func splitPreview(of frame: CGRect, edge: Direction) -> CGRect {
        switch edge {
        case .left:  return CGRect(x: frame.minX, y: frame.minY, width: frame.width / 2, height: frame.height)
        case .right: return CGRect(x: frame.midX, y: frame.minY, width: frame.width / 2, height: frame.height)
        case .up:    return CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height / 2)
        case .down:  return CGRect(x: frame.minX, y: frame.midY, width: frame.width, height: frame.height / 2)
        }
    }
}

/// Destination when dragging a tab.
public enum TabDropTarget: Equatable {
    case reorder(index: Int)
    case joinStack(stack: ObjectIdentifier, index: Int?, preview: CGRect)
    case splitTile(stack: ObjectIdentifier, edge: Direction, preview: CGRect)
}
