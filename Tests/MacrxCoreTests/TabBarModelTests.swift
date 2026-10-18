import Testing
import Foundation
@testable import MacrxCore

@Suite struct TitleCleanerTests {
    @Test func stripsChromeProfileAndApp() {
        #expect(TitleCleaner.clean("macross - Google Search - Google Chrome - Wes (google.com)", appName: "Google Chrome") == "macross - Google Search")
        #expect(TitleCleaner.clean("New Tab - Google Chrome - Wes (google.com)", appName: "Google Chrome") == "New Tab")
    }
    @Test func stripsPlainAppSuffixWithVariousDashes() {
        #expect(TitleCleaner.clean("README.md — Code", appName: "Code") == "README.md")
        #expect(TitleCleaner.clean("general | Slack", appName: "Slack") == "general")
        #expect(TitleCleaner.clean("Inbox - Mail", appName: "Mail") == "Inbox")
    }
    @Test func keepsTitlesThatMerelyContainTheAppName() {
        #expect(TitleCleaner.clean("Google Chrome Help", appName: "Google Chrome") == "Google Chrome Help")
        #expect(TitleCleaner.clean("Screen & System Audio Recording", appName: "System Settings") == "Screen & System Audio Recording")
    }
    @Test func fallsBackToAppName() {
        #expect(TitleCleaner.clean("", appName: "Calculator") == "Calculator")
        #expect(TitleCleaner.clean(" - Calculator", appName: "Calculator") == "Calculator")
        #expect(TitleCleaner.clean("", appName: nil) == "Untitled")
    }
}

@Suite struct TabLayoutTests {
    @Test func equalWidthsSplitTheBar() {
        #expect(TabLayout.equalWidths(count: 4, available: 1000) == [250, 250, 250, 250])
        #expect(TabLayout.equalWidths(count: 0, available: 1000).isEmpty)
    }
    @Test func rectsAreContiguous() {
        let r = TabLayout.rects(widths: [100, 50], in: CGRect(x: 10, y: 0, width: 150, height: 26))
        #expect(r[0] == CGRect(x: 10, y: 0, width: 100, height: 26))
        #expect(r[1] == CGRect(x: 110, y: 0, width: 50, height: 26))
    }
    @Test func reorderIndexHasHysteresisAcrossVariableWidths() {
        // Tab 0 is 80pt (0..80), Tab 1 is 200pt (80..280, midX=180).
        let before = TabLayout.rects(widths: [80, 200], in: CGRect(x: 0, y: 0, width: 280, height: 28))
        #expect(TabLayout.reorderIndex(atX: 170, currentIndex: 0, in: before) == 0)
        #expect(TabLayout.reorderIndex(atX: 185, currentIndex: 0, in: before) == 1)
        // After swapping: Tab 1 is 200pt (0..200, midX=100), Tab 0 is 80pt (200..280).
        // At the same x=185, currentIndex=1 must NOT swap back to 0.
        let after = TabLayout.rects(widths: [200, 80], in: CGRect(x: 0, y: 0, width: 280, height: 28))
        #expect(TabLayout.reorderIndex(atX: 185, currentIndex: 1, in: after) == 1)
        #expect(TabLayout.reorderIndex(atX: 95, currentIndex: 1, in: after) == 0)
    }
    @Test func dropTargetClassifiesBarEdgesAndCenter() {
        let s1 = Node(stack: [w(1), w(2)], top: 0)
        let s2 = Node(stack: [w(3), w(4)], top: 0)
        let tree = Tree(root: Node(split: .horizontal, children: [s1, s2]))
        let tiles = LayoutEngine.tiles(tree, in: CGRect(x: 0, y: 0, width: 1000, height: 500), tabBarHeight: { _ in 28 })
        let rects: [ObjectIdentifier: [CGRect]] = [
            s1.id: [CGRect(x: 0, y: 0, width: 100, height: 28), CGRect(x: 100, y: 0, width: 100, height: 28)],
            s2.id: [CGRect(x: 500, y: 0, width: 100, height: 28), CGRect(x: 600, y: 0, width: 100, height: 28)],
        ]
        // Drag w1 across its own bar past tab 2's midX (150) → reorder(index: 1).
        let r1 = TabLayout.dropTarget(at: CGPoint(x: 160, y: 14), draggedWindow: w(1), sourceStack: s1.id, tiles: tiles, tabRects: rects)
        #expect(r1 == .reorder(index: 1))
        // Drag w1 to right edge of its own tile (x=450, y=250) → splitTile(.right).
        let r2 = TabLayout.dropTarget(at: CGPoint(x: 450, y: 250), draggedWindow: w(1), sourceStack: s1.id, tiles: tiles, tabRects: rects)
        #expect(r2 == .splitTile(stack: s1.id, edge: .right, preview: CGRect(x: 250, y: 0, width: 250, height: 500)))
        // Drag w1 to center of s2 (x=750, y=250) → joinStack(s2).
        let r3 = TabLayout.dropTarget(at: CGPoint(x: 750, y: 250), draggedWindow: w(1), sourceStack: s1.id, tiles: tiles, tabRects: rects)
        #expect(r3 == .joinStack(stack: s2.id, index: nil, preview: CGRect(x: 500, y: 0, width: 500, height: 500)))
    }
}
