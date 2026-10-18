import Testing
import Foundation
@testable import MacrxCore

@Suite struct TreeOperationsTests {
    /// Helper: left→right order of top windows of horizontal root split.
    private func columns(_ t: Tree) -> [[WindowID]] {
        guard let r = t.root else { return [] }
        if r.isStack { return [r.windows] }
        return r.children.map { $0.isStack ? $0.windows : $0.allWindows }
    }

    @Test func InsertIntoFocusedStackOnTop() {
        var t = Tree()
        t.insert(w(1), near: nil)
        t.insert(w(2), near: w(1))
        t.insert(w(3), near: w(1))  // focused is w1 again? no: near w1 → after top
        let s = t.root!
        #expect(s.isStack)
        #expect(s.windows.count == 3)
        #expect(s.topWindow == w(3))
    }

    @Test func RemoveCollapsesSplit() {
        var t = Tree(root: Node(split: .horizontal, children: [Node(stack: [w(1)]), Node(stack: [w(2)])]))
        t.remove(w(2))
        #expect(t.root!.isStack)
        #expect(t.root!.windows == [w(1)])
        #expect(t.root!.size == .default)
    }

    @Test func RemoveFromStackReturnsNewTop() {
        var t = Tree(root: Node(stack: [w(1), w(2), w(3)], top: 2))
        let r3 = t.remove(w(3))
        #expect(r3 == w(2))
        let r4 = t.remove(w(1))
        #expect(r4 == w(2))
        let r5 = t.remove(w(2))
        #expect(r5 == nil)
        #expect(t.isEmpty)
    }

    @Test func NormalizeFlattensSameOrientation() {
        let inner = Node(split: .horizontal, children: [Node(stack: [w(2)]), Node(stack: [w(3)])])
        var t = Tree(root: Node(split: .horizontal, children: [Node(stack: [w(1)]), inner]))
        t.normalize()
        #expect(t.root!.children.count == 3)
        #expect(t.root!.children.allSatisfy { $0.size == .default })
        let f = LayoutEngine.frames(t, in: CGRect(x: 0, y: 0, width: 900, height: 600))
        #expect(f[w(2)]!.width == 300)
    }

    @Test func NormalizeFlatteningFixedGroupHandsOutItsLength() {
        // A fixed(400) inner group with one fixed(100) + one flex child → flex child becomes fixed(300).
        let a = Node(stack: [w(2)]); a.size = .fixed(100)
        let b = Node(stack: [w(3)])
        let inner = Node(split: .horizontal, children: [a, b]); inner.size = .fixed(400)
        var t = Tree(root: Node(split: .horizontal, children: [Node(stack: [w(1)]), inner]))
        t.normalize()
        #expect(t.root!.children.count == 3)
        #expect(t.root!.children[1].size == .fixed(100))
        #expect(t.root!.children[2].size == .fixed(300))
    }

    // MARK: move — leave stack

    @Test func MoveOutOfRootStackCreatesSplit() {
        var t = Tree(root: Node(stack: [w(1), w(2)], top: 1))
        let r6 = t.move(w(2), .right, in: screen)
        #expect(r6 == .moved)
        #expect(t.root!.orientation == .horizontal)
        #expect(columns(t) == [[w(1)], [w(2)]])
        #expect(t.root!.children.allSatisfy { $0.size == .default })
    }

    @Test func MoveOutOfStackToLeftPrepends() {
        var t = Tree(root: Node(stack: [w(1), w(2)], top: 1))
        let r7 = t.move(w(2), .left, in: screen)
        #expect(r7 == .moved)
        #expect(columns(t) == [[w(2)], [w(1)]])
    }

    @Test func MoveOutOfStackVerticallyWrapsRoot() {
        var t = Tree(root: Node(split: .horizontal, children: [Node(stack: [w(1), w(2)], top: 1), Node(stack: [w(3)])]))
        let r8 = t.move(w(2), .down, in: screen)
        #expect(r8 == .moved)
        #expect(t.root!.orientation == .vertical)
        #expect(t.root!.children.count == 2)
        #expect(t.root!.children[0].orientation == .horizontal)
        #expect(t.root!.children[1].windows == [w(2)])
    }

    @Test func MoveOutOfStackUsesExistingAncestorSplit() {
        var t = Tree(root: Node(split: .horizontal, children: [Node(stack: [w(1), w(2)], top: 1), Node(stack: [w(3)])]))
        let r9 = t.move(w(2), .right, in: screen)
        #expect(r9 == .moved)
        #expect(columns(t) == [[w(1)], [w(2)], [w(3)]])
    }

    // MARK: move — join neighbor

    @Test func MoveAloneJoinsNeighbor() {
        var t = Tree(root: Node(split: .horizontal, children: [Node(stack: [w(1)]), Node(stack: [w(2)])]))
        let r10 = t.move(w(2), .left, in: screen)
        #expect(r10 == .moved)
        #expect(t.root!.isStack)
        #expect(t.root!.windows == [w(1), w(2)])
        #expect(t.root!.topWindow == w(2))
    }

    @Test func MoveAloneAtEdgeNeedsDisplayMove() {
        var t = Tree(root: Node(split: .horizontal, children: [Node(stack: [w(1)]), Node(stack: [w(2)])]))
        let r11 = t.move(w(2), .right, in: screen)
        #expect(r11 == .needsDisplayMove)
        let r12 = t.move(w(2), .up, in: screen)
        #expect(r12 == .needsDisplayMove)
        var single = Tree(root: Node(stack: [w(1)]))
        let r13 = single.move(w(1), .left, in: screen)
        #expect(r13 == .needsDisplayMove)
    }

    @Test func PassThroughReordersInTwoPresses() {
        // [A][B][C] → move B left twice → [B][A][C]
        var t = Tree(root: Node(split: .horizontal, children: [Node(stack: [w(1)]), Node(stack: [w(2)]), Node(stack: [w(3)])]))
        let r14 = t.move(w(2), .left, in: screen)
        #expect(r14 == .moved)
        #expect(columns(t) == [[w(1), w(2)], [w(3)]])
        let r15 = t.move(w(2), .left, in: screen)
        #expect(r15 == .moved)
        #expect(columns(t) == [[w(2)], [w(1)], [w(3)]])
    }

    @Test func JoinIntoNestedColumnPicksOverlappingTile() {
        // left column: w1 (top half), w2 (bottom half); right: w3 — move w3 left should join w1 or w2
        // by overlap; w3 spans full height so both overlap equally → nearest by distance tie → first (w1).
        let col = Node(split: .vertical, children: [Node(stack: [w(1)]), Node(stack: [w(2)])])
        var t = Tree(root: Node(split: .horizontal, children: [col, Node(stack: [w(3)])]))
        let r16 = t.move(w(3), .left, in: screen)
        #expect(r16 == .moved)
        #expect(t.root!.orientation == .vertical)
        #expect(t.root!.children[0].windows == [w(1), w(3)])
    }

    // MARK: resize

    @Test func ResizeFixesChildAndFlexPartnerAbsorbs() {
        var t = Tree(root: Node(split: .horizontal, children: [Node(stack: [w(1)]), Node(stack: [w(2)])]))
        let r17 = t.resize(w(1), .right, step: 0.1, in: screen)
        #expect(r17)
        #expect(t.root!.children[0].size == .fixed(600))
        #expect(t.root!.children[1].size == .default)
        let f = LayoutEngine.frames(t, in: screen)
        #expect(f[w(2)]!.width == 400)
        // Keeps going until the partner hits the minimum, then refuses.
        for _ in 0..<10 { _ = t.resize(w(1), .right, step: 0.1, in: screen) }
        #expect(LayoutEngine.frames(t, in: screen)[w(2)]!.width == Tree.minimumLength)
        let r18 = t.resize(w(1), .right, step: 0.1, in: screen)
        #expect(!r18)
        let r19 = t.resize(w(1), .left, step: 0.1, in: screen)
        #expect(r19)
        #expect(t.root!.children[0].size == .fixed(850))
    }

    @Test func ResizeAgainstFixedPartnerMovesBoth() {
        let a = Node(stack: [w(1)]); a.size = .fixed(500)
        let b = Node(stack: [w(2)]); b.size = .fixed(500)
        var t = Tree(root: Node(split: .horizontal, children: [a, b]))
        let ok = t.resize(w(1), .right, step: 0.1, in: screen)
        #expect(ok)
        #expect(a.size == .fixed(600))
        #expect(b.size == .fixed(400))
    }

    @Test func ResizeWithoutMatchingSplitFails() {
        var t = Tree(root: Node(split: .horizontal, children: [Node(stack: [w(1)]), Node(stack: [w(2)])]))
        let r20 = t.resize(w(1), .down, step: 0.1, in: screen)
        #expect(!r20)
    }

    @Test func ResizeLastChildUsesPreviousSibling() {
        var t = Tree(root: Node(split: .horizontal, children: [Node(stack: [w(1)]), Node(stack: [w(2)])]))
        let r21 = t.resize(w(2), .right, step: 0.1, in: screen)
        #expect(r21)
        #expect(t.root!.children[1].size == .fixed(600))
        #expect(LayoutEngine.frames(t, in: screen)[w(1)]!.width == 400)
    }

    @Test func ResizeThatCannotChangeTheLayoutIsANoop() {
        // [A | B], B app-capped at 300 → A is already 700 and B cannot take more.
        let a = Node(stack: [w(1)]), b = Node(stack: [w(2)])
        var t = Tree(root: Node(split: .horizontal, children: [a, b]))
        let caps: LayoutEngine.MaxSize = { $0 == w(2) ? CGSize(width: 300, height: CGFloat.infinity) : nil }
        // Growing A: the slack B can't take flows straight back to A — nothing changes.
        let grow = t.resize(w(1), .right, step: 0.1, in: screen, maxSize: caps)
        #expect(!grow)
        #expect(a.size == .default)
        // Resizing the capped B itself: nothing can change either.
        let capped = t.resize(w(2), .left, step: 0.1, in: screen, maxSize: caps)
        #expect(!capped)
        #expect(b.size == .default)
        // Shrinking A: B can't grow, so refused as well.
        let shrink = t.resize(w(1), .left, step: 0.1, in: screen, maxSize: caps)
        #expect(!shrink)
        #expect(a.size == .default)
        // …but against a flex sibling the resize is real.
        t.insert(w(3), atEdge: .left)
        let real = t.resize(w(1), .left, step: 0.1, in: screen, maxSize: caps)
        #expect(real)
        #expect(a.size.isFixed)
    }

    @Test func ResizeThatScalesBackIsANoop() {
        // Both fixed and no flex sibling: shrinking A just scales it back up → refused, no change.
        let a = Node(stack: [w(1)]); a.size = .fixed(600)
        let b = Node(stack: [w(2)]); b.size = .fixed(400)
        var t = Tree(root: Node(split: .horizontal, children: [a, b]))
        // Here the partner is fixed, so it *does* absorb: real change.
        let r = t.resize(w(1), .left, step: 0.1, in: screen)
        #expect(r)
        #expect(a.size == .fixed(500))
        #expect(b.size == .fixed(500))
    }

    @Test func ResetSizeReturnsToFlex() {
        var t = Tree(root: Node(split: .horizontal, children: [Node(stack: [w(1)]), Node(stack: [w(2)])]))
        _ = t.resize(w(1), .right, step: 0.2, in: screen)
        #expect(t.root!.children[0].size.isFixed)
        let r = t.resetSize(w(1))
        #expect(r)
        #expect(t.root!.children[0].size == .default)
        #expect(LayoutEngine.frames(t, in: screen)[w(1)]!.width == 500)
    }

    @Test func NewWindowsAreFlexAndShareTheRemainder() {
        var t = Tree(root: Node(split: .horizontal, children: [Node(stack: [w(1)]), Node(stack: [w(2)])]))
        _ = t.resize(w(1), .right, step: 0.3, in: screen)      // w1 fixed(800)
        t.insert(w(3), atEdge: .right)
        let f = LayoutEngine.frames(t, in: screen)
        #expect(f[w(1)]!.width == 800)
        #expect(f[w(2)]!.width == 100)
        #expect(f[w(3)]!.width == 100)
    }

    // MARK: misc

    @Test func CycleStack() {
        var t = Tree(root: Node(stack: [w(1), w(2), w(3)], top: 0))
        let r22 = t.cycleStack(w(1), by: 1)
        #expect(r22 == w(2))
        let r23 = t.cycleStack(w(1), by: -2)
        #expect(r23 == w(3))
    }

    @Test func ToggleOrientation() {
        let a = Node(stack: [w(1)]); a.size = .fixed(300)
        var t = Tree(root: Node(split: .horizontal, children: [a, Node(stack: [w(2)])]))
        let r24 = t.toggleParentOrientation(w(1))
        #expect(r24)
        #expect(t.root!.orientation == .vertical)
        #expect(a.size == .default)   // a fixed width makes no sense as a height
        var single = Tree(root: Node(stack: [w(1)]))
        let r25 = single.toggleParentOrientation(w(1))
        #expect(!r25)
    }

    @Test func InsertAtEdge() {
        var t = Tree(root: Node(split: .horizontal, children: [Node(stack: [w(1)]), Node(stack: [w(2)])]))
        t.insert(w(3), atEdge: .left)
        #expect(columns(t) == [[w(3)], [w(1)], [w(2)]])
        t.insert(w(4), atEdge: .down)
        #expect(t.root!.orientation == .vertical)
        #expect(t.root!.children[1].windows == [w(4)])
    }

    @Test func ReorderInStackPreservesTopWindow() {
        var t = Tree(root: Node(stack: [w(1), w(2), w(3)], top: 1))
        let ok = t.reorder(w(3), to: 0)
        #expect(ok)
        #expect(t.root!.windows == [w(3), w(1), w(2)])
        #expect(t.root!.topWindow == w(2))
        let noop = t.reorder(w(3), to: 0)
        #expect(!noop)
    }

    @Test func MoveToStackAndSplitTile() {
        let s1 = Node(stack: [w(1), w(2)], top: 0)
        let s2 = Node(stack: [w(3)], top: 0)
        var t = Tree(root: Node(split: .horizontal, children: [s1, s2]))
        t.normalize()

        // Join w2 into s2 at index 0.
        let joined = t.move(w(2), toStack: s2.id, at: 0)
        #expect(joined)
        #expect(s1.windows == [w(1)])
        #expect(s2.windows == [w(2), w(3)])
        #expect(s2.topWindow == w(2))

        // Split s2 along .down with w3 → right column becomes vertical split [w2] / [w3].
        let split = t.move(w(3), splitting: s2.id, edge: .down)
        #expect(split)
        #expect(t.root!.orientation == .horizontal)
        #expect(t.root!.children[0].windows == [w(1)])
        let rightCol = t.root!.children[1]
        #expect(rightCol.orientation == .vertical)
        #expect(rightCol.children[0].windows == [w(2)])
        #expect(rightCol.children[1].windows == [w(3)])
    }
}

@Suite struct ResizeEdgeTests {
    @Test func draggingSharedEdgeFixesTheDraggedTile() {
        var t = Tree(root: Node(split: .horizontal, children: [Node(stack: [w(1)]), Node(stack: [w(2)])]))
        // Drag w1's right edge 100px right on a 1000px-wide display → w1 fixed(600), w2 flex → 400.
        let r = t.resizeEdge(w(1), edge: .right, by: 100, in: screen)
        #expect(r)
        #expect(t.root!.children[0].size == .fixed(600))
        #expect(t.root!.children[1].size == .default)
        #expect(LayoutEngine.frames(t, in: screen)[w(2)]!.width == 400)
        // Drag w2's left edge 100px left → w2 fixed(500); w1 (fixed) gives the 100 back.
        let r2 = t.resizeEdge(w(2), edge: .left, by: -100, in: screen)
        #expect(r2)
        #expect(t.root!.children[1].size == .fixed(500))
        #expect(t.root!.children[0].size == .fixed(500))
    }
    @Test func displayBoundaryEdgeIsRejected() {
        var t = Tree(root: Node(split: .horizontal, children: [Node(stack: [w(1)]), Node(stack: [w(2)])]))
        let r = t.resizeEdge(w(1), edge: .left, by: -50, in: screen)
        #expect(!r)
        let r2 = t.resizeEdge(w(1), edge: .down, by: 50, in: screen)
        #expect(!r2)
    }
    @Test func nestedEdgeFindsOuterSplit() {
        // [ v[A, B] | C ]: dragging A's right edge resizes the outer horizontal split.
        let col = Node(split: .vertical, children: [Node(stack: [w(1)]), Node(stack: [w(2)])])
        var t = Tree(root: Node(split: .horizontal, children: [col, Node(stack: [w(3)])]))
        let r = t.resizeEdge(w(1), edge: .right, by: 200, in: screen)
        #expect(r)
        #expect(col.size == .fixed(700))
        let f = LayoutEngine.frames(t, in: screen)
        #expect(f[w(1)]!.width == 700)
        #expect(f[w(2)]!.width == 700)
        #expect(f[w(3)]!.width == 300)
    }
    @Test func clampsToMinimum() {
        var t = Tree(root: Node(split: .horizontal, children: [Node(stack: [w(1)]), Node(stack: [w(2)])]))
        _ = t.resizeEdge(w(1), edge: .right, by: 900, in: screen)
        #expect(LayoutEngine.frames(t, in: screen)[w(2)]!.width == Tree.minimumLength)
    }
}
