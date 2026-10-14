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
        let a = Node(stack: [w(1)]); a.weight = 0.25
        let b = Node(stack: [w(2)]); b.weight = 0.75
        let t = Tree(root: Node(split: .horizontal, children: [a, b]))
        let f = LayoutEngine.frames(t, in: screen)
        #expect(f[w(1)] == CGRect(x: 0, y: 0, width: 250, height: 800))
        #expect(f[w(2)] == CGRect(x: 250, y: 0, width: 750, height: 800))
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
