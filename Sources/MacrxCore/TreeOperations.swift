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
            let avg = 1 / CGFloat(old.children.count + 1)
            newStack.weight = avg
            old.insertChild(newStack, at: edge.isForward ? old.children.count : 0)
        } else {
            let split = Node(split: edge.orientation)
            root = split
            if edge.isForward {
                split.appendChild(old); split.appendChild(newStack)
            } else {
                split.appendChild(newStack); split.appendChild(old)
            }
            old.weight = 1; newStack.weight = 1
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
            let half = liveTarget.weight / 2
            liveTarget.weight = half
            newStack.weight = half
            parent.insertChild(newStack, at: edge.isForward ? idx + 1 : idx)
        } else {
            let split = Node(split: edge.orientation)
            if let parent = liveTarget.parent {
                parent.replaceChild(liveTarget, with: split)
            } else {
                root = split
            }
            liveTarget.weight = 0.5
            newStack.weight = 0.5
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
            newStack.weight = child.weight
            a.insertChild(newStack, at: dir.isForward ? idx + 1 : idx)
        } else if let old = root {
            let split = Node(split: dir.orientation)
            root = split
            if dir.isForward {
                split.appendChild(old); split.appendChild(newStack)
            } else {
                split.appendChild(newStack); split.appendChild(old)
            }
            old.weight = 1; newStack.weight = 1
        }
        normalize()
    }

    // MARK: Resize

    /// Resizes the tile containing `w` along `dir.orientation` by `step` (fraction of the
    /// parent split). `.right`/`.down` grow, `.left`/`.up` shrink. Space is exchanged with
    /// the following sibling, or the preceding one at the end of the split.
    /// Returns `false` if there is nothing to resize against.
    @discardableResult
    public mutating func resize(_ w: WindowID, _ dir: Direction, step: CGFloat, minimum: CGFloat = 0.1) -> Bool {
        guard let s = stack(containing: w) else { return false }
        var child: Node = s
        var anc: Node? = s.parent
        while let a = anc, a.orientation != dir.orientation {
            child = a
            anc = a.parent
        }
        guard let split = anc, let idx = split.index(of: child), split.children.count > 1 else { return false }
        let partnerIdx = idx + 1 < split.children.count ? idx + 1 : idx - 1
        let partner = split.children[partnerIdx]
        let delta = dir.isForward ? step : -step
        let newChild = child.weight + delta
        let newPartner = partner.weight - delta
        guard newChild >= minimum, newPartner >= minimum else { return false }
        child.weight = newChild
        partner.weight = newPartner
        return true
    }

    /// Moves the `edge` of the tile containing `w` by `pixels` (positive = towards increasing
    /// coordinate, i.e. right/down), by re-weighting the nearest ancestor split that shares that
    /// edge with a sibling. Returns `false` if the edge is on the display boundary.
    @discardableResult
    public mutating func resizeEdge(_ w: WindowID, edge: Direction, by pixels: CGFloat, in displayFrame: CGRect, minimum: CGFloat = 0.1) -> Bool {
        guard abs(pixels) >= 1, let s = stack(containing: w) else { return false }
        var child: Node = s
        var anc: Node? = s.parent
        while let a = anc {
            if a.orientation == edge.orientation, let idx = a.index(of: child) {
                let hasNeighbor = edge.isForward ? idx < a.children.count - 1 : idx > 0
                if hasNeighbor {
                    let frames = LayoutEngine.nodeFrames(self, in: displayFrame)
                    guard let rect = frames[a.id] else { return false }
                    let extent = edge.orientation == .horizontal ? rect.width : rect.height
                    guard extent > 0 else { return false }
                    // Moving the right/bottom edge outward grows this child; moving the
                    // left/top edge outward (negative pixels) also grows it.
                    var delta = pixels / extent
                    if !edge.isForward { delta = -delta }
                    let partner = a.children[edge.isForward ? idx + 1 : idx - 1]
                    delta = min(delta, partner.weight - minimum)
                    delta = max(delta, minimum - child.weight)
                    child.weight += delta
                    partner.weight -= delta
                    return true
                }
            }
            child = a
            anc = a.parent
        }
        return false
    }

    // MARK: Orientation

    /// Toggles the orientation of the split directly containing `w`'s stack.
    /// If the stack is the root (no split), does nothing and returns `false`.
    @discardableResult
    public mutating func toggleParentOrientation(_ w: WindowID) -> Bool {
        guard let s = stack(containing: w), let p = s.parent, let o = p.orientation else { return false }
        p.orientation = o.toggled
        normalize()
        return true
    }
}
