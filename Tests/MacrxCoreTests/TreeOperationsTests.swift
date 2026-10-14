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
        #expect(t.root!.weight == 1)
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
        let total = t.root!.children.map(\.weight).reduce(0, +)
        #expect(abs(total - 1) <= 1e-9)
        #expect(abs((t.root!.children[1].weight) - (0.25)) <= 1e-9)
    }

    // MARK: move — leave stack

    @Test func MoveOutOfRootStackCreatesSplit() {
        var t = Tree(root: Node(stack: [w(1), w(2)], top: 1))
        let r6 = t.move(w(2), .right, in: screen)
        #expect(r6 == .moved)
        #expect(t.root!.orientation == .horizontal)
        #expect(columns(t) == [[w(1)], [w(2)]])
        #expect(abs((t.root!.children[0].weight) - (0.5)) <= 1e-9)
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

    @Test func ResizeExchangesWithNeighborAndClamps() {
        var t = Tree(root: Node(split: .horizontal, children: [Node(stack: [w(1)]), Node(stack: [w(2)])]))
        t.normalize()
        let r17 = t.resize(w(1), .right, step: 0.1)
        #expect(r17)
        #expect(abs((t.root!.children[0].weight) - (0.6)) <= 1e-9)
        #expect(abs((t.root!.children[1].weight) - (0.4)) <= 1e-9)
        for _ in 0..<10 { _ = t.resize(w(1), .right, step: 0.1) }
        #expect(abs((t.root!.children[1].weight) - (0.1)) <= 1e-9)
        let r18 = t.resize(w(1), .right, step: 0.1)
        #expect(!r18)
        let r19 = t.resize(w(1), .left, step: 0.1)
        #expect(r19)
        #expect(abs((t.root!.children[0].weight) - (0.8)) <= 1e-9)
    }

    @Test func ResizeWithoutMatchingSplitFails() {
        var t = Tree(root: Node(split: .horizontal, children: [Node(stack: [w(1)]), Node(stack: [w(2)])]))
        let r20 = t.resize(w(1), .down, step: 0.1)
        #expect(!r20)
    }

    @Test func ResizeLastChildUsesPreviousSibling() {
        var t = Tree(root: Node(split: .horizontal, children: [Node(stack: [w(1)]), Node(stack: [w(2)])]))
        t.normalize()
        let r21 = t.resize(w(2), .right, step: 0.1)
        #expect(r21)
        #expect(abs((t.root!.children[1].weight) - (0.6)) <= 1e-9)
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
        var t = Tree(root: Node(split: .horizontal, children: [Node(stack: [w(1)]), Node(stack: [w(2)])]))
        let r24 = t.toggleParentOrientation(w(1))
        #expect(r24)
        #expect(t.root!.orientation == .vertical)
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
}

@Suite struct ResizeEdgeTests {
    @Test func draggingSharedEdgeReweightsSplit() {
        var t = Tree(root: Node(split: .horizontal, children: [Node(stack: [w(1)]), Node(stack: [w(2)])]))
        t.normalize()
        // Drag w1's right edge 100px right on a 1000px-wide display → 60/40.
        let r = t.resizeEdge(w(1), edge: .right, by: 100, in: screen)
        #expect(r)
        #expect(abs(t.root!.children[0].weight - 0.6) < 1e-9)
        #expect(abs(t.root!.children[1].weight - 0.4) < 1e-9)
        // Drag w2's left edge 100px left → w2 grows back to 50/50.
        let r2 = t.resizeEdge(w(2), edge: .left, by: -100, in: screen)
        #expect(r2)
        #expect(abs(t.root!.children[0].weight - 0.5) < 1e-9)
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
        t.normalize()
        let r = t.resizeEdge(w(1), edge: .right, by: 200, in: screen)
        #expect(r)
        #expect(abs(t.root!.children[0].weight - 0.7) < 1e-9)
        let f = LayoutEngine.frames(t, in: screen)
        #expect(f[w(1)]!.width == 700)
        #expect(f[w(2)]!.width == 700)
    }
    @Test func clampsToMinimum() {
        var t = Tree(root: Node(split: .horizontal, children: [Node(stack: [w(1)]), Node(stack: [w(2)])]))
        t.normalize()
        _ = t.resizeEdge(w(1), edge: .right, by: 900, in: screen)
        #expect(abs(t.root!.children[1].weight - 0.1) < 1e-9)
    }
}
