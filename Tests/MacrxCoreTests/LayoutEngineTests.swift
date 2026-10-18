import Testing
import Foundation
@testable import MacrxCore

func w(_ n: UInt32) -> WindowID { WindowID(pid: 1, cgID: n) }
let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)

@Suite struct LayoutEngineTests {
    @Test func SingleStackFillsRect() {
        let t = Tree(root: Node(stack: [w(1), w(2)], top: 1))
        let tiles = LayoutEngine.tiles(t, in: screen)
        #expect(tiles.count == 1)
        #expect(tiles[0].frame == screen)
        #expect(tiles[0].content == screen)
        #expect(tiles[0].top == w(2))
        #expect(!(tiles[0].hasTabBar))
    }

    @Test func HorizontalSplitWeights() {
        let a = Node(stack: [w(1)]); a.size = .flex(1)
        let b = Node(stack: [w(2)]); b.size = .flex(3)
        let t = Tree(root: Node(split: .horizontal, children: [a, b]))
        let f = LayoutEngine.frames(t, in: screen)
        #expect(f[w(1)] == CGRect(x: 0, y: 0, width: 250, height: 800))
        #expect(f[w(2)] == CGRect(x: 250, y: 0, width: 750, height: 800))
    }

    @Test func FixedChildAndFlexRemainder() {
        let a = Node(stack: [w(1)]); a.size = .fixed(300)
        let b = Node(stack: [w(2)])
        let c = Node(stack: [w(3)])
        let t = Tree(root: Node(split: .horizontal, children: [a, b, c]))
        let f = LayoutEngine.frames(t, in: screen)
        #expect(f[w(1)]!.width == 300)
        #expect(f[w(2)]!.width == 350)
        #expect(f[w(3)]!.width == 350)
    }

    // MARK: size caps (fixed-size apps)

    private func caps(_ m: [UInt32: CGSize]) -> LayoutEngine.MaxSize { { m[$0.cgID] } }

    @Test func CappedChildGivesSlackToSibling() {
        let t = Tree(root: Node(split: .horizontal, children: [Node(stack: [w(1)]), Node(stack: [w(2)])]))
        let f = LayoutEngine.frames(t, in: screen, maxSize: caps([2: CGSize(width: 300, height: CGFloat.infinity)]))
        #expect(f[w(1)] == CGRect(x: 0, y: 0, width: 700, height: 800))
        #expect(f[w(2)] == CGRect(x: 700, y: 0, width: 300, height: 800))
    }

    @Test func CapOnlyAlongConstrainedAxis() {
        let t = Tree(root: Node(split: .vertical, children: [Node(stack: [w(1)]), Node(stack: [w(2)])]))
        let f = LayoutEngine.frames(t, in: screen, maxSize: caps([2: CGSize(width: 300, height: CGFloat.infinity)]))
        #expect(f[w(2)]!.height == 400)
    }

    @Test func AllChildrenCappedLeavesSpaceEmpty() {
        let t = Tree(root: Node(split: .horizontal, children: [Node(stack: [w(1)]), Node(stack: [w(2)])]))
        let f = LayoutEngine.frames(t, in: screen, maxSize: caps([1: CGSize(width: 300, height: 300), 2: CGSize(width: 200, height: 200)]))
        #expect(f[w(1)]!.width == 300)
        #expect(f[w(2)]!.width == 200)
    }

    @Test func StackCappedOnlyWhenAllMembersAre() {
        // [Calculator, Settings] stacked: width cap = max(300, 723); height free (Settings fills).
        let wide = CGRect(x: 0, y: 0, width: 2000, height: 800)
        let stack = Node(stack: [w(1), w(2)])
        let t = Tree(root: Node(split: .horizontal, children: [Node(stack: [w(3)]), stack]))
        let m: [UInt32: CGSize] = [1: CGSize(width: 300, height: 400), 2: CGSize(width: 723, height: CGFloat.infinity)]
        let f = LayoutEngine.frames(t, in: wide, tabBarHeight: { $0 > 1 ? 26 : 0 }, maxSize: caps(m))
        #expect(f[w(2)]!.width == 723)
        #expect(f[w(2)]!.height == 774)   // full height minus the tab bar
        #expect(f[w(3)]!.width == 1277)
        // Add an unmeasured window (Chrome) to the stack → no cap at all.
        stack.windows.append(w(4))
        let f2 = LayoutEngine.frames(t, in: wide, tabBarHeight: { $0 > 1 ? 26 : 0 }, maxSize: caps(m))
        #expect(f2[w(4)]!.width == 1000)
    }

    @Test func CapIncludesTabBar() {
        let stack = Node(stack: [w(1), w(2)])
        let t = Tree(root: Node(split: .vertical, children: [stack, Node(stack: [w(3)])]))
        let m: [UInt32: CGSize] = [1: CGSize(width: CGFloat.infinity, height: 300), 2: CGSize(width: CGFloat.infinity, height: 200)]
        let tiles = LayoutEngine.tiles(t, in: screen, tabBarHeight: { $0 > 1 ? 26 : 0 }, maxSize: caps(m))
        #expect(tiles[0].frame.height == 326)
        #expect(tiles[0].content.height == 300)
        #expect(tiles[1].frame.height == 474)
    }

    @Test func NestedSplitFlexibleIfAnyLeafFlexible() {
        let col = Node(split: .vertical, children: [Node(stack: [w(2)]), Node(stack: [w(3)])])
        let t = Tree(root: Node(split: .horizontal, children: [Node(stack: [w(1)]), col]))
        let f = LayoutEngine.frames(t, in: screen, maxSize: caps([2: CGSize(width: 200, height: 200)]))
        #expect(f[w(1)]!.width == 500)
        #expect(f[w(3)]!.width == 500)
    }
    @Test func NestedSplit() {
        let a = Node(stack: [w(1)])
        let b = Node(stack: [w(2)])
        let c = Node(stack: [w(3)])
        let col = Node(split: .vertical, children: [b, c])
        let t = Tree(root: Node(split: .horizontal, children: [a, col]))
        let f = LayoutEngine.frames(t, in: screen)
        #expect(f[w(1)] == CGRect(x: 0, y: 0, width: 500, height: 800))
        #expect(f[w(2)] == CGRect(x: 500, y: 0, width: 500, height: 400))
        #expect(f[w(3)] == CGRect(x: 500, y: 400, width: 500, height: 400))
    }

    @Test func TabBarOnlyForMultipleWindows() {
        let a = Node(stack: [w(1)])
        let b = Node(stack: [w(2), w(3)])
        let t = Tree(root: Node(split: .horizontal, children: [a, b]))
        let cfg = TabBarConfig()
        let tiles = LayoutEngine.tiles(t, in: screen, tabBarHeight: cfg.height(forWindowCount:))
        #expect(!(tiles[0].hasTabBar))
        #expect(tiles[0].content == CGRect(x: 0, y: 0, width: 500, height: 800))
        #expect(tiles[1].hasTabBar)
        #expect(tiles[1].tabBar == CGRect(x: 500, y: 0, width: 500, height: 26))
        #expect(tiles[1].content == CGRect(x: 500, y: 26, width: 500, height: 774))
    }

    @Test func TabBarNever() {
        var cfg = TabBarConfig(); cfg.show = .never
        #expect(cfg.height(forWindowCount: 5) == 0)
        cfg.show = .always
        #expect(cfg.height(forWindowCount: 1) == 26)
    }
}

@Suite struct SizeResolveTests {
    @Test func equalFlex() {
        #expect(LayoutEngine.resolve(total: 900, specs: [.flex(1), .flex(1), .flex(1)], caps: [nil, nil, nil]) == [300, 300, 300])
    }
    @Test func fixedThenFlexShareRemainder() {
        #expect(LayoutEngine.resolve(total: 1000, specs: [.fixed(400), .flex(1), .flex(1)], caps: [nil, nil, nil]) == [400, 300, 300])
    }
    @Test func allFixedUnderCommittedScalesUp() {
        #expect(LayoutEngine.resolve(total: 1000, specs: [.fixed(200), .fixed(300)], caps: [nil, nil]) == [400, 600])
    }
    @Test func overCommittedScalesFixedDownAndStarvesFlex() {
        let r = LayoutEngine.resolve(total: 500, specs: [.fixed(600), .fixed(400), .flex(1)], caps: [nil, nil, nil])
        #expect(r == [300, 200, 0])
    }
    @Test func capBelowFlexShareGivesSlackToFlex() {
        #expect(LayoutEngine.resolve(total: 1000, specs: [.flex(1), .flex(1)], caps: [nil, 300]) == [700, 300])
    }
    @Test func capWithFixedSiblingScalesFixedUp() {
        // No flex sibling to absorb the slack: the fixed one grows so no hole is left.
        let r = LayoutEngine.resolve(total: 1000, specs: [.fixed(400), .flex(1)], caps: [nil, 300])
        #expect(r == [700, 300])
    }
    @Test func allCappedLeavesHole() {
        let r = LayoutEngine.resolve(total: 1000, specs: [.flex(1), .flex(1)], caps: [300, 200])
        #expect(r == [300, 200])
    }
    @Test func chainedCaps() {
        // Giving slack to a flex sibling can push *it* over its cap; iterate.
        let r = LayoutEngine.resolve(total: 1000, specs: [.flex(1), .flex(1), .flex(1)], caps: [200, 350, nil])
        #expect(r == [200, 350, 450])
    }
}
