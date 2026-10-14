import Foundation
import CoreGraphics

public struct DisplayID: Hashable, Sendable, CustomStringConvertible {
    public let raw: UInt32
    public init(_ raw: UInt32) { self.raw = raw }
    public var description: String { "display(\(raw))" }
}

public struct Display: Equatable, Sendable {
    public let id: DisplayID
    /// Usable area in AX coordinates (excluding menu bar and Dock).
    public let frame: CGRect
    public init(id: DisplayID, frame: CGRect) { self.id = id; self.frame = frame }
}

public struct Workspace {
    public let id: Int
    public var tree = Tree()
    /// The display that owns this workspace.
    public var displayID: DisplayID
    /// Last focused window on this workspace.
    public var focused: WindowID?
    public var floating: Set<WindowID> = []
    public var fullscreen: WindowID?

    public init(id: Int, displayID: DisplayID) {
        self.id = id
        self.displayID = displayID
    }

    public var allWindows: [WindowID] { tree.allWindows + Array(floating) }
    public func contains(_ w: WindowID) -> Bool { tree.contains(w) || floating.contains(w) }
    public var isEmpty: Bool { tree.isEmpty && floating.isEmpty }
}

/// Owns all workspaces and tracks which one is visible on each display.
///
/// Workspaces are global (numbered 1…n), each lives on exactly one display at a time,
/// and each display shows exactly one workspace.
public struct WorkspaceModel {
    public private(set) var displays: [Display] = []
    public private(set) var workspaces: [Int: Workspace] = [:]
    /// Visible workspace id per display.
    public private(set) var visible: [DisplayID: Int] = [:]
    /// Display holding keyboard focus.
    public private(set) var focusedDisplay: DisplayID?
    /// Globally focused window (if any).
    public private(set) var focused: WindowID?

    public init(displays: [Display] = []) {
        setDisplays(displays)
    }

    // MARK: Displays

    public func display(_ id: DisplayID) -> Display? { displays.first { $0.id == id } }

    public var primaryDisplay: Display? { displays.first }

    /// Updates the display list. Workspaces on vanished displays migrate to the primary display.
    /// Every display is guaranteed a visible workspace.
    public mutating func setDisplays(_ new: [Display]) {
        displays = new
        guard let primary = new.first else { return }
        let ids = Set(new.map(\.id))
        for (id, ws) in workspaces where !ids.contains(ws.displayID) {
            workspaces[id]!.displayID = primary.id
        }
        visible = visible.filter { ids.contains($0.key) }
        for d in new where visible[d.id] == nil {
            // Prefer a workspace already owned by this display, else create a fresh one.
            if let ws = workspaces.values.filter({ $0.displayID == d.id }).sorted(by: { $0.id < $1.id }).first {
                visible[d.id] = ws.id
            } else {
                let id = lowestFreeWorkspaceID()
                workspaces[id] = Workspace(id: id, displayID: d.id)
                visible[d.id] = id
            }
        }
        if focusedDisplay.map({ !ids.contains($0) }) ?? true {
            focusedDisplay = primary.id
        }
        if let f = focused, workspace(containing: f) == nil { focused = nil }
    }

    private func lowestFreeWorkspaceID() -> Int {
        var id = 1
        while workspaces[id] != nil { id += 1 }
        return id
    }

    /// Display geometrically in `dir` from `from`.
    public func display(in dir: Direction, from: DisplayID) -> Display? {
        guard let origin = display(from) else { return nil }
        let cands = displays.filter { $0.id != from }.map { Navigation.Candidate(id: $0.id, frame: $0.frame) }
        guard let c = Navigation.neighbor(from: origin.frame, dir: dir, among: cands) else { return nil }
        return display(c.id)
    }

    // MARK: Workspace lookup

    public func workspace(_ id: Int) -> Workspace? { workspaces[id] }

    public func visibleWorkspace(on display: DisplayID) -> Workspace? {
        visible[display].flatMap { workspaces[$0] }
    }

    public func workspace(containing w: WindowID) -> Workspace? {
        workspaces.values.first { $0.contains(w) }
    }

    public func isVisible(_ wsID: Int) -> Bool {
        guard let ws = workspaces[wsID] else { return false }
        return visible[ws.displayID] == wsID
    }

    public var focusedWorkspace: Workspace? {
        focusedDisplay.flatMap { visibleWorkspace(on: $0) }
    }

    public var visibleWorkspaces: [Workspace] {
        displays.compactMap { visibleWorkspace(on: $0.id) }
    }

    /// Mutates the workspace with `id` in place.
    public mutating func update(_ id: Int, _ body: (inout Workspace) -> Void) {
        guard workspaces[id] != nil else { return }
        body(&workspaces[id]!)
    }

    // MARK: Focus

    public mutating func setFocused(_ w: WindowID?) {
        focused = w
        guard let w, let ws = workspace(containing: w) else { return }
        workspaces[ws.id]!.focused = w
        focusedDisplay = ws.displayID
        visible[ws.displayID] = ws.id
    }

    public mutating func setFocusedDisplay(_ id: DisplayID) {
        guard display(id) != nil else { return }
        focusedDisplay = id
        focused = visibleWorkspace(on: id)?.focused
    }

    /// Makes workspace `id` visible on its display (creating it on the focused display if needed),
    /// and moves focus there. Returns the window that should be focused, if any.
    @discardableResult
    public mutating func focusWorkspace(_ id: Int) -> WindowID? {
        if workspaces[id] == nil {
            guard let d = focusedDisplay ?? primaryDisplay?.id else { return nil }
            workspaces[id] = Workspace(id: id, displayID: d)
        }
        let ws = workspaces[id]!
        visible[ws.displayID] = id
        focusedDisplay = ws.displayID
        focused = ws.focused.flatMap { ws.contains($0) ? $0 : nil } ?? ws.tree.allStacks.first?.topWindow
        return focused
    }

    // MARK: Windows

    /// Adds a window to the workspace visible on `display` (default: the focused display),
    /// stacked on that workspace's focused window.
    public mutating func add(_ w: WindowID, floating: Bool = false, on display: DisplayID? = nil) {
        guard workspace(containing: w) == nil else { return }
        guard let d = display ?? focusedDisplay ?? primaryDisplay?.id, let wsID = visible[d] else { return }
        if floating {
            workspaces[wsID]!.floating.insert(w)
        } else {
            let near = workspaces[wsID]!.focused
            workspaces[wsID]!.tree.insert(w, near: near)
        }
    }

    /// Removes a window from wherever it is. Returns a suggested replacement focus
    /// if the removed window was focused.
    @discardableResult
    public mutating func remove(_ w: WindowID) -> WindowID? {
        guard let ws = workspace(containing: w) else { return nil }
        var replacement: WindowID?
        if ws.floating.contains(w) {
            workspaces[ws.id]!.floating.remove(w)
            replacement = workspaces[ws.id]!.tree.allStacks.first?.topWindow
        } else {
            replacement = workspaces[ws.id]!.tree.remove(w)
            if replacement == nil { replacement = workspaces[ws.id]!.tree.allStacks.first?.topWindow }
        }
        if workspaces[ws.id]!.fullscreen == w { workspaces[ws.id]!.fullscreen = nil }
        if workspaces[ws.id]!.focused == w { workspaces[ws.id]!.focused = replacement }
        if focused == w { focused = replacement }
        return replacement
    }

    /// Moves `w` to workspace `id` (creating it on `w`'s current display if needed).
    /// Returns a suggested replacement focus on the source workspace.
    @discardableResult
    public mutating func moveWindow(_ w: WindowID, toWorkspace id: Int) -> WindowID? {
        guard let src = workspace(containing: w), src.id != id else { return nil }
        let wasFloating = src.floating.contains(w)
        let replacement = remove(w)
        if workspaces[id] == nil {
            workspaces[id] = Workspace(id: id, displayID: src.displayID)
        }
        if wasFloating {
            workspaces[id]!.floating.insert(w)
        } else {
            let near = workspaces[id]!.focused
            workspaces[id]!.tree.insert(w, near: near)
        }
        workspaces[id]!.focused = w
        return replacement
    }

    /// Moves `w` to the display in `dir`, inserting it at the near edge of that display's
    /// visible workspace. Returns `false` if there is no display in that direction.
    @discardableResult
    public mutating func moveWindow(_ w: WindowID, toDisplay dir: Direction) -> Bool {
        guard let src = workspace(containing: w),
              let target = display(in: dir, from: src.displayID),
              let targetWS = visible[target.id]
        else { return false }
        let wasFloating = src.floating.contains(w)
        remove(w)
        if wasFloating {
            workspaces[targetWS]!.floating.insert(w)
        } else {
            workspaces[targetWS]!.tree.insert(w, atEdge: dir.opposite)
        }
        workspaces[targetWS]!.focused = w
        return true
    }

    public mutating func toggleFloating(_ w: WindowID) {
        guard let ws = workspace(containing: w) else { return }
        if ws.floating.contains(w) {
            workspaces[ws.id]!.floating.remove(w)
            let near = ws.tree.allStacks.first?.topWindow
            workspaces[ws.id]!.tree.insert(w, near: near)
        } else {
            workspaces[ws.id]!.tree.remove(w)
            workspaces[ws.id]!.floating.insert(w)
        }
    }

    public mutating func toggleFullscreen(_ w: WindowID) {
        guard let ws = workspace(containing: w) else { return }
        workspaces[ws.id]!.fullscreen = ws.fullscreen == w ? nil : w
    }
}
