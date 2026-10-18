import Testing
import Foundation
@testable import MacrxCore

@Suite struct LayoutSnapshotTests {
    let d1 = Display(id: DisplayID(1), frame: CGRect(x: 0, y: 0, width: 1000, height: 800))
    let d2 = Display(id: DisplayID(2), frame: CGRect(x: 1000, y: 0, width: 1000, height: 800))

    /// Two displays, nested splits, a fixed size, a 3-window stack with top = 2,
    /// a floating and a fullscreen window, and a hidden workspace.
    private func sampleModel() -> WorkspaceModel {
        var m = WorkspaceModel(displays: [d1, d2])
        m.add(w(1)); m.setFocused(w(1))
        m.add(w(2)); m.setFocused(w(2))
        m.add(w(3)); m.setFocused(w(3))                 // ws0: stack [1,2,3] top 3
        m.update(0) { _ = $0.tree.move(w(3), .right, in: d1.frame) }
        m.update(0) { _ = $0.tree.move(w(2), .down, in: d1.frame) }
        m.update(0) { _ = $0.tree.resize(w(3), .right, step: 0.1, in: d1.frame) }
        m.add(w(4), floating: true)
        m.toggleFullscreen(w(1))
        m.focusWorkspace(5)                             // hidden later
        m.add(w(5)); m.setFocused(w(5))
        m.add(w(6)); m.setFocused(w(6))
        m.focusWorkspace(0)
        m.setFocusedDisplay(d2.id)
        m.add(w(7)); m.setFocused(w(7))
        m.setFocused(w(3))
        return m
    }

    @Test func roundTripThroughJSON() throws {
        let m = sampleModel()
        let snap = m.snapshot(bootTime: 42)
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        let data = try enc.encode(snap)
        let decoded = try JSONDecoder().decode(LayoutSnapshot.self, from: data)
        #expect(decoded == snap)

        let restored = WorkspaceModel(restoring: decoded, displays: [d1, d2])
        #expect(restored.snapshot(bootTime: 42, now: Date(timeIntervalSince1970: TimeInterval(snap.savedAt))) == snap)
        #expect(restored.focused == w(3))
        #expect(restored.focusedDisplay == d1.id)
        #expect(restored.visibleWorkspace(on: d1.id)?.id == 0)
        #expect(restored.visibleWorkspace(on: d2.id)?.id == 1)
        #expect(!restored.isVisible(5))
        #expect(restored.workspace(0)!.floating == [w(4)])
        #expect(restored.workspace(0)!.fullscreen == w(1))
        for ws in m.workspaces.values {
            let before = LayoutEngine.frames(ws.tree, in: d1.frame)
            let after = LayoutEngine.frames(restored.workspace(ws.id)!.tree, in: d1.frame)
            #expect(before == after)
        }
    }

    @Test func nodeRoundTripKeepsSizesAndTop() {
        let a = Node(stack: [w(1), w(2), w(3)], top: 2); a.size = .fixed(321)
        let b = Node(stack: [w(4)]); b.size = .flex(2)
        let root = Node(split: .vertical, children: [a, b])
        let copy = Node(root.snapshot())
        #expect(copy.orientation == .vertical)
        #expect(copy.children[0].windows == [w(1), w(2), w(3)])
        #expect(copy.children[0].top == 2)
        #expect(copy.children[0].size == .fixed(321))
        #expect(copy.children[1].size == .flex(2))
        #expect(copy.children[0].parent === copy)
    }

    @Test func restoringOntoFewerDisplaysMigratesWorkspaces() {
        let snap = sampleModel().snapshot(bootTime: 1)
        let restored = WorkspaceModel(restoring: snap, displays: [d1])
        #expect(restored.workspaces.values.allSatisfy { $0.displayID == d1.id })
        #expect(restored.visible.count == 1)
        #expect(restored.visibleWorkspace(on: d1.id)?.id == 0)
        #expect(restored.focusedDisplay == d1.id)
        #expect(restored.workspace(containing: w(7))?.id == 1)
    }

    @Test func restoringOntoMoreDisplaysGivesNewOnesAWorkspace() {
        let snap = WorkspaceModel(displays: [d1]).snapshot(bootTime: 1)
        let restored = WorkspaceModel(restoring: snap, displays: [d1, d2])
        #expect(restored.visibleWorkspace(on: d1.id)?.id == 0)
        #expect(restored.visibleWorkspace(on: d2.id) != nil)
    }

    @Test func allWindowsListsEverything() {
        let snap = sampleModel().snapshot(bootTime: 1)
        #expect(snap.allWindows == Set([w(1), w(2), w(3), w(4), w(5), w(6), w(7)]))
    }

    @Test func sizeSpecJSONShape() throws {
        let data = try JSONEncoder().encode([SizeSpec.fixed(723), .flex(1)])
        let s = String(decoding: data, as: UTF8.self)
        #expect(s.contains("\"fixed\":723"))
        #expect(s.contains("\"flex\":1"))
    }
}
