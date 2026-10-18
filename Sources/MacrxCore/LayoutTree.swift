import Foundation
import CoreGraphics

/// Identifies a window of a managed application.
public struct WindowID: Hashable, Sendable, CustomStringConvertible {
    public let pid: Int32
    public let cgID: UInt32

    public init(pid: Int32, cgID: UInt32) {
        self.pid = pid
        self.cgID = cgID
    }

    public var description: String { "\(pid):\(cgID)" }
}

/// How a split child is sized along its parent's axis.
public enum SizeSpec: Equatable, Sendable {
    /// Shares what is left after fixed siblings, proportionally to the weight (default 1).
    case flex(CGFloat)
    /// Exactly this many points. Set by a manual resize.
    case fixed(CGFloat)

    public static let `default` = SizeSpec.flex(1)

    public var isFixed: Bool { if case .fixed = self { return true } else { return false } }
}

/// A node in the layout tree. Either a *split* (has `orientation` and `children`)
/// or a *stack* (has `windows`, one of which is on `top`).
///
/// Nodes are reference types so that operations can walk parent pointers.
public final class Node {
    public private(set) weak var parent: Node?
    /// Size along the parent's axis.
    public var size: SizeSpec = .default

    /// `nil` for stacks.
    public var orientation: Orientation?
    public private(set) var children: [Node] = []

    public var windows: [WindowID] = []
    public var top: Int = 0

    public init(split orientation: Orientation, children: [Node] = []) {
        self.orientation = orientation
        for c in children { appendChild(c) }
    }

    public init(stack windows: [WindowID], top: Int = 0) {
        self.orientation = nil
        self.windows = windows
        self.top = min(max(0, top), max(0, windows.count - 1))
    }

    public var isStack: Bool { orientation == nil }
    public var isSplit: Bool { orientation != nil }
    public var id: ObjectIdentifier { ObjectIdentifier(self) }

    public var topWindow: WindowID? {
        guard isStack, windows.indices.contains(top) else { return nil }
        return windows[top]
    }

    // MARK: Children management

    public func appendChild(_ child: Node) {
        insertChild(child, at: children.count)
    }

    public func insertChild(_ child: Node, at index: Int) {
        child.parent?.detach(child)
        child.parent = self
        children.insert(child, at: min(max(0, index), children.count))
    }

    public func detach(_ child: Node) {
        if let i = children.firstIndex(where: { $0 === child }) {
            children.remove(at: i)
            child.parent = nil
        }
    }

    public func replaceChild(_ old: Node, with new: Node) {
        guard let i = children.firstIndex(where: { $0 === old }) else { return }
        new.parent?.detach(new)
        old.parent = nil
        new.parent = self
        new.size = old.size
        children[i] = new
    }

    public func index(of child: Node) -> Int? {
        children.firstIndex(where: { $0 === child })
    }

    // MARK: Queries

    public var allWindows: [WindowID] {
        isStack ? windows : children.flatMap(\.allWindows)
    }

    public var allStacks: [Node] {
        isStack ? [self] : children.flatMap(\.allStacks)
    }

    public func stack(containing w: WindowID) -> Node? {
        if isStack { return windows.contains(w) ? self : nil }
        for c in children { if let s = c.stack(containing: w) { return s } }
        return nil
    }

    /// The child of `self` whose subtree contains `node`.
    public func child(containing node: Node) -> Node? {
        var n: Node? = node
        while let cur = n {
            if cur.parent === self { return cur }
            n = cur.parent
        }
        return nil
    }

    public func makeTop(_ w: WindowID) {
        if let i = windows.firstIndex(of: w) { top = i }
    }

    public var isRoot: Bool { parent == nil }
}

/// The layout tree of one workspace.
public struct Tree {
    public var root: Node?

    public init(root: Node? = nil) { self.root = root }

    public var isEmpty: Bool { root == nil }
    public var allWindows: [WindowID] { root?.allWindows ?? [] }
    public var allStacks: [Node] { root?.allStacks ?? [] }

    public func stack(containing w: WindowID) -> Node? { root?.stack(containing: w) }
    public func contains(_ w: WindowID) -> Bool { stack(containing: w) != nil }

    /// Re-establishes the structural invariants:
    /// - no empty stacks, no empty splits
    /// - a split with one child is replaced by that child
    /// - a split nested inside a split of the same orientation is flattened
    public mutating func normalize() {
        guard let r = root else { return }
        root = Tree.normalize(r)
        root?.size = .default
    }

    private static func normalize(_ node: Node) -> Node? {
        if node.isStack {
            if node.windows.isEmpty { return nil }
            node.top = min(max(0, node.top), node.windows.count - 1)
            return node
        }
        // Normalize children first.
        for c in Array(node.children) {
            if let n = normalize(c) {
                if n !== c { node.replaceChild(c, with: n) }
            } else {
                node.detach(c)
            }
        }
        // Flatten same-orientation children. Grandchildren keep their specs, except that a
        // fixed group hands its length out to its flex members so the group still occupies it.
        for c in Array(node.children) where c.isSplit && c.orientation == node.orientation {
            guard let idx = node.index(of: c) else { continue }
            let grand = Array(c.children)
            if case .fixed(let f) = c.size {
                let fixedSum = grand.reduce(CGFloat(0)) { if case .fixed(let v) = $1.size { return $0 + v } else { return $0 } }
                let flexSum = grand.reduce(CGFloat(0)) { if case .flex(let v) = $1.size { return $0 + v } else { return $0 } }
                let spare = max(0, f - fixedSum)
                for g in grand { if case .flex(let v) = g.size { g.size = .fixed(flexSum > 0 ? spare * v / flexSum : spare / CGFloat(grand.count)) } }
            }
            node.detach(c)
            for (k, g) in grand.enumerated() { node.insertChild(g, at: idx + k) }
        }
        if node.children.isEmpty { return nil }
        if node.children.count == 1 {
            let only = node.children[0]
            node.detach(only)
            only.size = node.size
            return only
        }
        return node
    }
}
