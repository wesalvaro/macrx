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
    public typealias TabBarHeight = (Int) -> CGFloat
    /// Largest size a window accepts (`.infinity` on a free axis), or nil if unknown/unconstrained.
    public typealias MaxSize = (WindowID) -> CGSize?

    /// Computes tiles for `tree` laid out inside `rect`.
    /// - Parameters:
    ///   - tabBarHeight: the height of the tab bar for a stack of the given window count (0 hides it).
    ///   - maxSize: per-window size caps; a stack whose windows are *all* capped along an axis is
    ///     laid out no larger than the largest cap, and its siblings take the freed space.
    public static func tiles(
        _ tree: Tree,
        in rect: CGRect,
        tabBarHeight: @escaping TabBarHeight = { _ in 0 },
        maxSize: @escaping MaxSize = { _ in nil }
    ) -> [Tile] {
        guard let root = tree.root else { return [] }
        var out: [Tile] = []
        let ctx = Context(tabBarHeight: tabBarHeight, maxSize: maxSize)
        layout(root, in: rect, ctx: ctx, into: &out)
        return out
    }

    struct Context {
        let tabBarHeight: TabBarHeight
        let maxSize: MaxSize
    }

    private static func layout(_ node: Node, in rect: CGRect, ctx: Context, into out: inout [Tile]) {
        if node.isStack {
            guard let top = node.topWindow else { return }
            let h = min(max(0, ctx.tabBarHeight(node.windows.count)), rect.height)
            let bar = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: h)
            let content = CGRect(x: rect.minX, y: rect.minY + h, width: rect.width, height: rect.height - h)
            out.append(Tile(stackID: node.id, frame: rect, tabBar: bar, content: content, windows: node.windows, top: top))
            return
        }
        for (child, piece) in zip(node.children, pieces(of: node, in: rect, ctx: ctx)) {
            layout(child, in: piece, ctx: ctx, into: &out)
        }
    }

    private static func pieces(of split: Node, in rect: CGRect, ctx: Context) -> [CGRect] {
        let o = split.orientation!
        let total = o == .horizontal ? rect.width : rect.height
        let caps = split.children.map { maxExtent($0, o, ctx: ctx) }
        let lengths = resolve(total: total, specs: split.children.map(\.size), caps: caps)
        return rect.split(o, lengths: lengths)
    }

    /// Largest extent the subtree can use along `o`, or nil when unconstrained.
    /// A stack is constrained only if *every* window in it is (so no member ever has desktop
    /// showing through around it); a split only if every child is.
    static func maxExtent(_ node: Node, _ o: Orientation, ctx: Context) -> CGFloat? {
        if node.isStack {
            var cap: CGFloat = 0
            for w in node.windows {
                guard let s = ctx.maxSize(w) else { return nil }
                let v = o == .horizontal ? s.width : s.height
                guard v.isFinite else { return nil }
                cap = max(cap, v)
            }
            return o == .vertical ? cap + max(0, ctx.tabBarHeight(node.windows.count)) : cap
        }
        var kids: [CGFloat] = []
        for c in node.children {
            guard let k = maxExtent(c, o, ctx: ctx) else { return nil }
            kids.append(k)
        }
        return node.orientation == o ? kids.reduce(0, +) : (kids.max() ?? 0)
    }

    /// Resolves child lengths along one axis.
    /// - fixed children get their size; flex children share the remainder by weight;
    /// - `caps` (auto size caps) bound a child from above, the slack going to flex siblings;
    /// - over-commitment scales fixed children down; with no flex children, fixed ones scale up
    ///   to fill (capped children never grow past their cap, so a split of only capped children
    ///   may leave space empty — that is the whole point).
    public static func resolve(total: CGFloat, specs: [SizeSpec], caps: [CGFloat?]) -> [CGFloat] {
        let n = specs.count
        guard n > 0 else { return [] }
        guard total > 0 else { return Array(repeating: 0, count: n) }
        let caps = caps.count == n ? caps : Array(repeating: nil, count: n)

        // Children pinned to a cap are removed from the flexible pool; iterate until stable.
        var pinned: [CGFloat?] = Array(repeating: nil, count: n)
        for _ in 0...n {
            var out = Array(repeating: CGFloat(0), count: n)
            var remaining = total
            var fixedIdx: [Int] = [], flexIdx: [Int] = []
            var fixedSum: CGFloat = 0, flexSum: CGFloat = 0
            for i in 0..<n {
                if let p = pinned[i] { out[i] = p; remaining -= p; continue }
                switch specs[i] {
                case .fixed(let v): out[i] = max(0, v); fixedSum += out[i]; fixedIdx.append(i)
                case .flex(let w): flexSum += max(0, w); flexIdx.append(i)
                }
            }
            remaining = max(0, remaining)
            if fixedSum > remaining, fixedSum > 0 {
                // Over-committed: shrink fixed proportionally, flex gets nothing.
                let s = remaining / fixedSum
                for i in fixedIdx { out[i] *= s }
            } else {
                var spare = remaining - fixedSum
                if !flexIdx.isEmpty {
                    if flexSum > 0 {
                        for i in flexIdx { out[i] = spare * max(0, flexWeight(specs[i])) / flexSum }
                    } else {
                        for i in flexIdx { out[i] = spare / CGFloat(flexIdx.count) }
                    }
                    spare = 0
                } else if !fixedIdx.isEmpty, spare > 0 {
                    // Nothing flexible: fixed children scale up to fill.
                    let s = (fixedSum + spare) / fixedSum
                    for i in fixedIdx { out[i] *= s }
                    spare = 0
                }
            }
            // Pin anything that exceeds its cap and go again; otherwise done.
            var changed = false
            for i in 0..<n where pinned[i] == nil {
                if let c = caps[i], out[i] > c + 0.5 { pinned[i] = c; changed = true }
            }
            if !changed { return out }
        }
        return Array(repeating: total / CGFloat(n), count: n)
    }

    private static func flexWeight(_ s: SizeSpec) -> CGFloat {
        if case .flex(let w) = s { return w } else { return 0 }
    }

    // MARK: Size markers

    /// Why a node is not simply sharing space: the user fixed it, or its app(s) cap it.
    public enum SizeMarkerKind: Equatable {
        case fixed(axis: Orientation, points: CGFloat)
        case capped(width: CGFloat?, height: CGFloat?)
    }

    public struct SizeMarker: Equatable {
        public let nodeID: ObjectIdentifier
        /// Laid-out frame of the node (for a stack: the whole tile including its tab bar).
        public let frame: CGRect
        public let kind: SizeMarkerKind
    }

    /// Fixed nodes under a split, plus stacks that are auto-capped along at least one axis.
    public static func sizeMarkers(
        _ tree: Tree, in rect: CGRect,
        tabBarHeight: @escaping TabBarHeight = { _ in 0 },
        maxSize: @escaping MaxSize = { _ in nil }
    ) -> [SizeMarker] {
        guard let root = tree.root else { return [] }
        let ctx = Context(tabBarHeight: tabBarHeight, maxSize: maxSize)
        let frames = nodeFrames(tree, in: rect, tabBarHeight: tabBarHeight, maxSize: maxSize)
        var out: [SizeMarker] = []
        func walk(_ node: Node) {
            if let p = node.parent, let o = p.orientation, case .fixed(let pts) = node.size, let f = frames[node.id] {
                out.append(SizeMarker(nodeID: node.id, frame: f, kind: .fixed(axis: o, points: pts)))
            }
            if node.isStack, let f = frames[node.id] {
                let w = maxExtent(node, .horizontal, ctx: ctx)
                let hTotal = maxExtent(node, .vertical, ctx: ctx)
                let h = hTotal.map { $0 - max(0, tabBarHeight(node.windows.count)) }
                if w != nil || h != nil {
                    out.append(SizeMarker(nodeID: node.id, frame: f, kind: .capped(width: w, height: h)))
                }
            }
            for c in node.children { walk(c) }
        }
        walk(root)
        return out
    }

    /// Frame of every node (splits and stacks) when `tree` is laid out in `rect`.
    public static func nodeFrames(
        _ tree: Tree, in rect: CGRect,
        tabBarHeight: @escaping TabBarHeight = { _ in 0 },
        maxSize: @escaping MaxSize = { _ in nil }
    ) -> [ObjectIdentifier: CGRect] {
        var out: [ObjectIdentifier: CGRect] = [:]
        let ctx = Context(tabBarHeight: tabBarHeight, maxSize: maxSize)
        func walk(_ node: Node, _ r: CGRect) {
            out[node.id] = r
            guard node.isSplit else { return }
            for (child, piece) in zip(node.children, pieces(of: node, in: r, ctx: ctx)) {
                walk(child, piece)
            }
        }
        if let root = tree.root { walk(root, rect) }
        return out
    }

    /// Convenience: content frame per window.
    public static func frames(
        _ tree: Tree, in rect: CGRect,
        tabBarHeight: @escaping TabBarHeight = { _ in 0 },
        maxSize: @escaping MaxSize = { _ in nil }
    ) -> [WindowID: CGRect] {
        var map: [WindowID: CGRect] = [:]
        for t in tiles(tree, in: rect, tabBarHeight: tabBarHeight, maxSize: maxSize) {
            for w in t.windows { map[w] = t.content }
        }
        return map
    }
}
