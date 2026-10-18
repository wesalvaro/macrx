import Foundation
import CoreGraphics

public enum MoveResult: Equatable {
    /// The tree changed.
    case moved
    /// The window is alone at the display edge; the caller should move it to another display.
    case needsDisplayMove
    case noop
}

extension Tree {
    // MARK: Insert / remove

    /// Inserts `w` into the stack containing `near` (on top of it). Falls back to the
    /// first stack, or creates a root stack if the tree is empty.
    public mutating func insert(_ w: WindowID, near: WindowID?) {
        guard !contains(w) else { return }
        if let near, let s = stack(containing: near) {
            s.windows.insert(w, at: s.top + 1)
            s.top += 1
            return
        }
        if let s = allStacks.first {
            s.windows.insert(w, at: s.top + 1)
            s.top += 1
            return
        }
        root = Node(stack: [w])
    }

    /// Inserts `w` as a new tile at the `edge` of the whole tree
    /// (e.g. `.left` puts it in a new column on the far left).
    public mutating func insert(_ w: WindowID, atEdge edge: Direction) {
        guard !contains(w) else { return }
        let newStack = Node(stack: [w])
        guard let old = root else { root = newStack; return }
        if old.isSplit && old.orientation == edge.orientation {
            old.insertChild(newStack, at: edge.isForward ? old.children.count : 0)
        } else {
            let split = Node(split: edge.orientation)
            root = split
            if edge.isForward {
                split.appendChild(old); split.appendChild(newStack)
            } else {
                split.appendChild(newStack); split.appendChild(old)
            }
            old.size = .default; newStack.size = .default
        }
        normalize()
    }

    /// Removes `w`. Returns the window that should receive focus if `w` was focused:
    /// the new top of the same stack, if any.
    @discardableResult
    public mutating func remove(_ w: WindowID) -> WindowID? {
        guard let s = stack(containing: w), let i = s.windows.firstIndex(of: w) else { return nil }
        s.windows.remove(at: i)
        if s.top >= i && s.top > 0 { s.top -= 1 }
        let next = s.topWindow
        normalize()
        return next
    }

    // MARK: Stack cycling

    /// Cycles the top window of `w`'s stack by `delta`. Returns the new top.
    @discardableResult
    public mutating func cycleStack(_ w: WindowID, by delta: Int) -> WindowID? {
        guard let s = stack(containing: w), s.windows.count > 1 else { return nil }
        let n = s.windows.count
        s.top = ((s.top + delta) % n + n) % n
        return s.topWindow
    }

    public mutating func makeTop(_ w: WindowID) {
        stack(containing: w)?.makeTop(w)
    }

    /// Reorders `w` to `newIndex` within its own stack, preserving the current `topWindow`.
    @discardableResult
    public mutating func reorder(_ w: WindowID, to newIndex: Int) -> Bool {
        guard let s = stack(containing: w), let oldIndex = s.windows.firstIndex(of: w) else { return false }
        let clamped = min(max(0, newIndex), s.windows.count - 1)
        guard clamped != oldIndex else { return false }
        let currentTop = s.topWindow
        s.windows.remove(at: oldIndex)
        s.windows.insert(w, at: clamped)
        if let currentTop, let topIdx = s.windows.firstIndex(of: currentTop) {
            s.top = topIdx
        }
        return true
    }

    /// Moves `w` into the stack with `targetID` (at `index`, or right after its current top)
    /// and makes `w` the top of that stack. If `w` is already in `targetID`, reorders it when `index` is given.
    @discardableResult
    public mutating func move(_ w: WindowID, toStack targetID: ObjectIdentifier, at index: Int? = nil) -> Bool {
        guard allStacks.contains(where: { $0.id == targetID }) else { return false }
        if let src = stack(containing: w), src.id == targetID {
            if let index { return reorder(w, to: index) }
            return false
        }
        remove(w)
        guard let target = allStacks.first(where: { $0.id == targetID }) else { return false }
        let idx = index.map { min(max(0, $0), target.windows.count) } ?? min(target.top + 1, target.windows.count)
        target.windows.insert(w, at: idx)
        target.top = idx
        return true
    }

    /// Removes `w` from its current stack and splits the stack `targetID` along `edge`,
    /// placing `w` in a new tile on the `edge` side of `targetID`.
    @discardableResult
    public mutating func move(_ w: WindowID, splitting targetID: ObjectIdentifier, edge: Direction) -> Bool {
        guard let target = allStacks.first(where: { $0.id == targetID }) else { return false }
        if target.windows == [w] { return false }
        remove(w)
        guard let liveTarget = allStacks.first(where: { $0.id == targetID }) else { return false }
        let newStack = Node(stack: [w])
        if let parent = liveTarget.parent, parent.orientation == edge.orientation, let idx = parent.index(of: liveTarget) {
            parent.insertChild(newStack, at: edge.isForward ? idx + 1 : idx)
        } else {
            let split = Node(split: edge.orientation)
            if let parent = liveTarget.parent {
                parent.replaceChild(liveTarget, with: split)
            } else {
                root = split
            }
            liveTarget.size = .default
            newStack.size = .default
            if edge.isForward {
                split.appendChild(liveTarget)
                split.appendChild(newStack)
            } else {
                split.appendChild(newStack)
                split.appendChild(liveTarget)
            }
        }
        normalize()
        return true
    }

    // MARK: Move (pass-through semantics)

    /// Moves `w` in `dir`:
    /// - if `w` shares its stack with other windows, it leaves the stack and becomes a
    ///   neighboring tile in `dir`;
    /// - if `w` is alone in its tile and a neighbor tile exists in `dir`, it joins that stack;
    /// - otherwise `.needsDisplayMove` is returned.
    /// `displayFrame` is used for geometric neighbor search.
    public mutating func move(_ w: WindowID, _ dir: Direction, in displayFrame: CGRect) -> MoveResult {
        guard let s = stack(containing: w) else { return .noop }
        if s.windows.count > 1 {
            leaveStack(w, from: s, toward: dir)
            return .moved
        }
        // Alone in its tile: join the neighbor stack in `dir`, if any.
        let tiles = LayoutEngine.tiles(self, in: displayFrame)
        guard let mine = tiles.first(where: { $0.stackID == s.id }) else { return .noop }
        let others = tiles.filter { $0.stackID != s.id }.map { Navigation.Candidate(id: $0.stackID, frame: $0.frame) }
        guard let target = Navigation.neighbor(from: mine.frame, dir: dir, among: others),
              let targetStack = allStacks.first(where: { $0.id == target.id })
        else { return .needsDisplayMove }
        remove(w)
        targetStack.windows.insert(w, at: targetStack.top + 1)
        targetStack.top += 1
        return .moved
    }

    private mutating func leaveStack(_ w: WindowID, from s: Node, toward dir: Direction) {
        guard let i = s.windows.firstIndex(of: w) else { return }
        s.windows.remove(at: i)
        if s.top >= i && s.top > 0 { s.top -= 1 }

        let newStack = Node(stack: [w])
        // Nearest ancestor split with matching orientation.
        var child: Node = s
        var anc: Node? = s.parent
        while let a = anc, a.orientation != dir.orientation {
            child = a
            anc = a.parent
        }
        if let a = anc, let idx = a.index(of: child) {
            a.insertChild(newStack, at: dir.isForward ? idx + 1 : idx)
        } else if let old = root {
            let split = Node(split: dir.orientation)
            root = split
            if dir.isForward {
                split.appendChild(old); split.appendChild(newStack)
            } else {
                split.appendChild(newStack); split.appendChild(old)
            }
            old.size = .default; newStack.size = .default
        }
        normalize()
    }

    // MARK: Resize

    /// Smallest length a resized child may be given.
    public static let minimumLength: CGFloat = 50

    /// Resizes the tile containing `w` along `dir.orientation` by `step` (fraction of the
    /// parent split's extent). `.right`/`.down` grow, `.left`/`.up` shrink. The child becomes
    /// `fixed`; a flex partner absorbs the change, a fixed partner is moved by the opposite amount.
    /// Returns `false` if there is nothing to resize against.
    @discardableResult
    public mutating func resize(_ w: WindowID, _ dir: Direction, step: CGFloat, in displayFrame: CGRect,
                                maxSize: @escaping LayoutEngine.MaxSize = { _ in nil }) -> Bool {
        guard let s = stack(containing: w) else { return false }
        var child: Node = s
        var anc: Node? = s.parent
        while let a = anc, a.orientation != dir.orientation {
            child = a
            anc = a.parent
        }
        guard let split = anc, let idx = split.index(of: child), split.children.count > 1 else { return false }
        let frames = LayoutEngine.nodeFrames(self, in: displayFrame, maxSize: maxSize)
        guard let parentRect = frames[split.id], let childRect = frames[child.id] else { return false }
        let extent = dir.orientation == .horizontal ? parentRect.width : parentRect.height
        let delta = (dir.isForward ? step : -step) * extent
        // Exchange space with the following sibling (or the preceding one at the end), skipping
        // a neighbour that is app-capped along this axis since it cannot absorb anything.
        let candidates = [idx + 1, idx - 1].filter { split.children.indices.contains($0) }
        let partnerIdx = candidates.first { LayoutEngine.maxExtent(split.children[$0], dir.orientation, maxSize: maxSize) == nil }
            ?? candidates[0]
        return applyResize(child: child, childRect: childRect, partner: split.children[partnerIdx],
                           partnerRect: frames[split.children[partnerIdx].id], by: delta, along: dir.orientation,
                           in: displayFrame, maxSize: maxSize)
    }

    /// Moves the `edge` of the tile containing `w` by `pixels` (positive = towards increasing
    /// coordinate, i.e. right/down), fixing the size of the nearest ancestor that shares that
    /// edge with a sibling. Returns `false` if the edge is on the display boundary.
    @discardableResult
    public mutating func resizeEdge(_ w: WindowID, edge: Direction, by pixels: CGFloat, in displayFrame: CGRect,
                                    maxSize: @escaping LayoutEngine.MaxSize = { _ in nil }) -> Bool {
        guard abs(pixels) >= 1, let s = stack(containing: w) else { return false }
        var child: Node = s
        var anc: Node? = s.parent
        while let a = anc {
            if a.orientation == edge.orientation, let idx = a.index(of: child) {
                let hasNeighbor = edge.isForward ? idx < a.children.count - 1 : idx > 0
                if hasNeighbor {
                    let frames = LayoutEngine.nodeFrames(self, in: displayFrame, maxSize: maxSize)
                    let partner = a.children[edge.isForward ? idx + 1 : idx - 1]
                    guard let childRect = frames[child.id] else { return false }
                    // Moving the right/bottom edge outward grows this child; moving the
                    // left/top edge outward (negative pixels) also grows it.
                    let delta = edge.isForward ? pixels : -pixels
                    return applyResize(child: child, childRect: childRect, partner: partner,
                                       partnerRect: frames[partner.id], by: delta, along: edge.orientation,
                                       in: displayFrame, maxSize: maxSize)
                }
            }
            child = a
            anc = a.parent
        }
        return false
    }

    /// Applies a resize of `child` by `delta`, but only keeps it if it means something:
    /// - a tile that is app-capped along the axis cannot change size, so resizing it — or
    ///   resizing its neighbour into it — is refused (nothing to lock);
    /// - otherwise the specs are applied tentatively and kept only if the layout actually
    ///   moved (when nothing can absorb the change the tile would end up fixed at the size it
    ///   already had: a lock for nothing).
    private mutating func applyResize(child: Node, childRect: CGRect, partner: Node, partnerRect: CGRect?,
                                      by delta: CGFloat, along o: Orientation,
                                      in displayFrame: CGRect, maxSize: @escaping LayoutEngine.MaxSize) -> Bool {
        if LayoutEngine.maxExtent(child, o, maxSize: maxSize) != nil
            || LayoutEngine.maxExtent(partner, o, maxSize: maxSize) != nil { return false }
        let len = o == .horizontal ? childRect.width : childRect.height
        let partnerLen = partnerRect.map { o == .horizontal ? $0.width : $0.height } ?? .infinity
        // Clamp so neither side drops below the minimum.
        var d = delta
        d = max(d, Self.minimumLength - len)
        d = min(d, partnerLen - Self.minimumLength)
        guard abs(d) >= 0.5 else { return false }
        let before = (child.size, partner.size)
        child.size = .fixed((len + d).rounded())
        if case .fixed(let p) = partner.size { partner.size = .fixed(max(Self.minimumLength, (p - d).rounded())) }
        let after = LayoutEngine.nodeFrames(self, in: displayFrame, maxSize: maxSize)[child.id]
        let newLen = after.map { o == .horizontal ? $0.width : $0.height } ?? len
        if abs(newLen - len) < 1 {
            (child.size, partner.size) = before
            return false
        }
        return true
    }

    /// Returns the tile containing `w` to flexible sizing.
    @discardableResult
    public mutating func resetSize(_ w: WindowID) -> Bool {
        guard let s = stack(containing: w) else { return false }
        var node: Node = s
        var changed = false
        // Reset the stack and every ancestor the user may have fixed via this window.
        while let p = node.parent {
            if node.size != .default { node.size = .default; changed = true }
            node = p
        }
        return changed
    }

    /// Returns exactly one node (identified by `id`) to flexible sizing.
    @discardableResult
    public mutating func resetSize(nodeID id: ObjectIdentifier) -> Bool {
        func find(_ n: Node) -> Node? {
            if n.id == id { return n }
            for c in n.children { if let f = find(c) { return f } }
            return nil
        }
        guard let r = root, let n = find(r), n.size != .default else { return false }
        n.size = .default
        return true
    }

    // MARK: Orientation

    /// Toggles the orientation of the split directly containing `w`'s stack. Fixed sizes along
    /// the old axis rarely make sense along the new one, so the children go back to flex.
    /// If the stack is the root (no split), does nothing and returns `false`.
    @discardableResult
    public mutating func toggleParentOrientation(_ w: WindowID) -> Bool {
        guard let s = stack(containing: w), let p = s.parent, let o = p.orientation else { return false }
        p.orientation = o.toggled
        for c in p.children { c.size = .default }
        normalize()
        return true
    }
}
