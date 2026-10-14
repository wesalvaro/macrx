import Foundation
import CoreGraphics

/// Output of the layout engine for one stack node.
public struct Tile: Equatable {
    /// Identity of the stack node this tile was produced from.
    public let stackID: ObjectIdentifier
    /// Full area of the tile (tab bar + content).
    public let frame: CGRect
    /// Area for the macrx-drawn tab bar (zero height when hidden).
    public let tabBar: CGRect
    /// Area assigned to every window of the stack.
    public let content: CGRect
    public let windows: [WindowID]
    public let top: WindowID

    public var hasTabBar: Bool { tabBar.height > 0 }
}

public enum LayoutEngine {
    /// Computes tiles for `tree` laid out inside `rect`.
    /// - Parameter tabBarHeight: the height of the tab bar for a stack of the given window count
    ///   (return 0 to hide it).
    public static func tiles(
        _ tree: Tree,
        in rect: CGRect,
        tabBarHeight: (Int) -> CGFloat = { _ in 0 }
    ) -> [Tile] {
        guard let root = tree.root else { return [] }
        var out: [Tile] = []
        layout(root, in: rect, tabBarHeight: tabBarHeight, into: &out)
        return out
    }

    private static func layout(
        _ node: Node, in rect: CGRect,
        tabBarHeight: (Int) -> CGFloat, into out: inout [Tile]
    ) {
        if node.isStack {
            guard let top = node.topWindow else { return }
            let h = min(max(0, tabBarHeight(node.windows.count)), rect.height)
            let bar = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: h)
            let content = CGRect(x: rect.minX, y: rect.minY + h, width: rect.width, height: rect.height - h)
            out.append(Tile(stackID: node.id, frame: rect, tabBar: bar, content: content, windows: node.windows, top: top))
            return
        }
        let pieces = rect.split(node.orientation!, weights: node.children.map(\.weight))
        for (child, piece) in zip(node.children, pieces) {
            layout(child, in: piece, tabBarHeight: tabBarHeight, into: &out)
        }
    }

    /// Frame of every node (splits and stacks) when `tree` is laid out in `rect`.
    public static func nodeFrames(_ tree: Tree, in rect: CGRect) -> [ObjectIdentifier: CGRect] {
        var out: [ObjectIdentifier: CGRect] = [:]
        func walk(_ node: Node, _ r: CGRect) {
            out[node.id] = r
            guard node.isSplit else { return }
            for (child, piece) in zip(node.children, r.split(node.orientation!, weights: node.children.map(\.weight))) {
                walk(child, piece)
            }
        }
        if let root = tree.root { walk(root, rect) }
        return out
    }

    /// Convenience: content frame per window.
    public static func frames(
        _ tree: Tree, in rect: CGRect, tabBarHeight: (Int) -> CGFloat = { _ in 0 }
    ) -> [WindowID: CGRect] {
        var map: [WindowID: CGRect] = [:]
        for t in tiles(tree, in: rect, tabBarHeight: tabBarHeight) {
            for w in t.windows { map[w] = t.content }
        }
        return map
    }
}
