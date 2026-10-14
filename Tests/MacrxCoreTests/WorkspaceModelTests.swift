import Testing
import Foundation
@testable import MacrxCore

@Suite struct WorkspaceModelTests {
    let d1 = Display(id: DisplayID(1), frame: CGRect(x: 0, y: 0, width: 1000, height: 800))
    let d2 = Display(id: DisplayID(2), frame: CGRect(x: 1000, y: 0, width: 1000, height: 800))

    @Test func InitialDisplaysGetWorkspaces() {
        let m = WorkspaceModel(displays: [d1, d2])
        #expect(m.visibleWorkspace(on: d1.id)?.id == 1)
        #expect(m.visibleWorkspace(on: d2.id)?.id == 2)
        #expect(m.focusedDisplay == d1.id)
    }

    @Test func AddStacksOnFocused() {
        var m = WorkspaceModel(displays: [d1])
        m.add(w(1)); m.setFocused(w(1))
        m.add(w(2)); m.setFocused(w(2))
        m.add(w(3))
        let ws = m.visibleWorkspace(on: d1.id)!
        #expect(ws.tree.root!.windows == [w(1), w(2), w(3)])
        #expect(ws.tree.root!.topWindow == w(3))
    }

    @Test func FocusWorkspaceCreatesOnFocusedDisplayAndSwitches() {
        var m = WorkspaceModel(displays: [d1, d2])
        m.add(w(1)); m.setFocused(w(1))
        let r26 = m.focusWorkspace(3)
        #expect(r26 == nil)
        #expect(m.visibleWorkspace(on: d1.id)?.id == 3)
        #expect(!(m.isVisible(1)))
        #expect(m.isVisible(2))
        // Switching back restores focus to w1.
        let r27 = m.focusWorkspace(1)
        #expect(r27 == w(1))
        // Focusing workspace 2 (owned by d2) moves focus to d2 without moving the workspace.
        m.focusWorkspace(2)
        #expect(m.focusedDisplay == d2.id)
        #expect(m.workspace(2)?.displayID == d2.id)
        #expect(m.isVisible(1))
    }

    @Test func MoveWindowToWorkspace() {
        var m = WorkspaceModel(displays: [d1])
        m.add(w(1)); m.setFocused(w(1))
        m.add(w(2)); m.setFocused(w(2))
        let replacement = m.moveWindow(w(2), toWorkspace: 5)
        #expect(replacement == w(1))
        #expect(m.workspace(containing: w(2))?.id == 5)
        #expect(m.workspace(5)?.displayID == d1.id)
        #expect(!(m.isVisible(5)))
        #expect(m.workspace(5)?.focused == w(2))
    }

    @Test func MoveWindowToDisplayInsertsAtNearEdge() {
        var m = WorkspaceModel(displays: [d1, d2])
        m.setFocusedDisplay(d2.id)
        m.add(w(9)); m.setFocused(w(9))
        m.setFocusedDisplay(d1.id)
        m.add(w(1)); m.setFocused(w(1))
        let r28 = m.moveWindow(w(1), toDisplay: .right)
        #expect(r28)
        let ws2 = m.visibleWorkspace(on: d2.id)!
        #expect(ws2.tree.root!.orientation == .horizontal)
        #expect(ws2.tree.root!.children[0].windows == [w(1)])   // near (left) edge
        #expect(ws2.tree.root!.children[1].windows == [w(9)])
        #expect(m.visibleWorkspace(on: d1.id)!.isEmpty)
        let r29 = m.moveWindow(w(1), toDisplay: .right)
        #expect(!r29)
    }

    @Test func DisplayRemovalMigratesWorkspaces() {
        var m = WorkspaceModel(displays: [d1, d2])
        m.setFocusedDisplay(d2.id)
        m.add(w(5)); m.setFocused(w(5))
        m.setDisplays([d1])
        #expect(m.workspace(2)?.displayID == d1.id)
        #expect(m.visibleWorkspace(on: d1.id)?.id == 1)
        #expect(m.focusedDisplay == d1.id)
        #expect(m.workspace(containing: w(5))?.id == 2)
        // Re-adding d2 gives it a fresh workspace (2 stays on d1 until focused).
        m.setDisplays([d1, d2])
        #expect(m.visibleWorkspace(on: d2.id)?.id == 3)
        m.focusWorkspace(2)
        #expect(m.visibleWorkspace(on: d1.id)?.id == 2)
    }

    @Test func RemoveFocusedSuggestsReplacement() {
        var m = WorkspaceModel(displays: [d1])
        m.add(w(1)); m.setFocused(w(1))
        m.add(w(2)); m.setFocused(w(2))
        let r30 = m.remove(w(2))
        #expect(r30 == w(1))
        #expect(m.focused == w(1))
        let r31 = m.remove(w(1))
        #expect(r31 == nil)
        #expect(m.focused == nil)
    }

    @Test func FloatingAndFullscreenToggles() {
        var m = WorkspaceModel(displays: [d1])
        m.add(w(1)); m.setFocused(w(1))
        m.add(w(2)); m.setFocused(w(2))
        m.toggleFloating(w(2))
        #expect(m.workspace(1)!.floating.contains(w(2)))
        #expect(m.workspace(1)!.tree.allWindows == [w(1)])
        m.toggleFloating(w(2))
        #expect(m.workspace(1)!.tree.allWindows == [w(1), w(2)])
        m.toggleFullscreen(w(1))
        #expect(m.workspace(1)!.fullscreen == w(1))
        m.remove(w(1))
        #expect(m.workspace(1)!.fullscreen == nil)
    }

    @Test func MoveWorkspaceSwapsDisplays() {
        var m = WorkspaceModel(displays: [d1, d2])
        m.add(w(1)); m.setFocused(w(1))              // ws1 on d1
        let moved = m.moveFocusedWorkspace(toDisplay: .right)
        #expect(moved)
        #expect(m.workspace(1)?.displayID == d2.id)
        #expect(m.workspace(2)?.displayID == d1.id)
        #expect(m.visibleWorkspace(on: d2.id)?.id == 1)
        #expect(m.visibleWorkspace(on: d1.id)?.id == 2)
        #expect(m.focusedDisplay == d2.id)
        let again = m.moveFocusedWorkspace(toDisplay: .right)
        #expect(!again)
    }
}
