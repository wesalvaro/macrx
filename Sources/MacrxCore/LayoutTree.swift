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

/// A node in the layout tree. Either a *split* (has `orientation` and `children`)
/// or a *stack* (has `windows`, one of which is on `top`).
///
/// Nodes are reference types so that operations can walk parent pointers.
public final class Node {
    public private(set) weak var parent: Node?
    /// Share of the parent's extent along the parent's axis.
    public var weight: CGFloat = 1

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
        new.weight = old.weight
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
    /// - weights in each split sum to 1
    public mutating func normalize() {
        guard let r = root else { return }
        root = Tree.normalize(r)
        root?.weight = 1
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
        // Flatten same-orientation children.
        for c in Array(node.children) where c.isSplit && c.orientation == node.orientation {
            guard let idx = node.index(of: c) else { continue }
            let total = c.children.map(\.weight).reduce(0, +)
            let grand = Array(c.children)
            node.detach(c)
            for (k, g) in grand.enumerated() {
                let share = total > 0 ? g.weight / total : 1 / CGFloat(grand.count)
                g.weight = c.weight * share
                node.insertChild(g, at: idx + k)
            }
        }
        if node.children.isEmpty { return nil }
        if node.children.count == 1 {
            let only = node.children[0]
            node.detach(only)
            only.weight = node.weight
            return only
        }
        let total = node.children.map(\.weight).reduce(0, +)
        if total > 0 { for c in node.children { c.weight /= total } }
        return node
    }
}
