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
    public var id: Int
    public var tree = Tree()
    /// The display that owns this workspace.
    public var displayID: DisplayID
    /// Frame size of the display this workspace lived on when multiple displays were connected,
    /// so undocking to a single display and re-docking restores the workspace to its monitor
    /// even if displays wake up seconds apart or macOS swaps their `CGDirectDisplayID`s.
    public var preferredDisplaySize: CGSize?
    /// Last focused window on this workspace.
    public var focused: WindowID?
    public var floating: Set<WindowID> = []
    public var fullscreen: WindowID?

    public init(id: Int, displayID: DisplayID, preferredDisplaySize: CGSize? = nil) {
        self.id = id
        self.displayID = displayID
        self.preferredDisplaySize = preferredDisplaySize
    }

    public var allWindows: [WindowID] { tree.allWindows + Array(floating) }
    public func contains(_ w: WindowID) -> Bool { tree.contains(w) || floating.contains(w) }
    public var isEmpty: Bool { tree.isEmpty && floating.isEmpty }

    /// Windows in the foreground layer of this workspace (stack tops, or the fullscreen window,
    /// plus floating windows). Non-top stack members and tiled windows behind a fullscreen
    /// window are excluded.
    public var foregroundWindows: [WindowID] {
        var out: [WindowID] = []
        if let fs = fullscreen, contains(fs) {
            out.append(fs)
        } else {
            out.append(contentsOf: tree.allStacks.compactMap(\.topWindow))
        }
        for w in floating.sorted(by: { $0.cgID < $1.cgID }) where !out.contains(w) {
            out.append(w)
        }
        return out
    }
}

/// Owns all workspaces and tracks which one is visible on each display.
///
/// Workspaces are global (numbered `firstWorkspaceID`…n), each lives on exactly one display
/// at a time, and each display shows exactly one workspace.
public struct WorkspaceModel {
    /// Lowest workspace number; the one auto-created for a display when nothing else is
    /// available. Only affects workspaces created from here on (`first-workspace` in config).
    public var firstWorkspaceID: Int
    public private(set) var displays: [Display] = []
    public private(set) var workspaces: [Int: Workspace] = [:]
    /// Visible workspace id per display.
    public private(set) var visible: [DisplayID: Int] = [:]
    /// Display holding keyboard focus.
    public private(set) var focusedDisplay: DisplayID?
    /// Globally focused window (if any).
    public private(set) var focused: WindowID?

    public init(displays: [Display] = [], firstWorkspaceID: Int = 0) {
        self.firstWorkspaceID = firstWorkspaceID
        setDisplays(displays)
    }

    // MARK: Displays

    public func display(_ id: DisplayID) -> Display? { displays.first { $0.id == id } }

    public var primaryDisplay: Display? { displays.first }

    /// Updates the display list. Workspaces on vanished displays migrate to the primary display,
    /// and every display is guaranteed a visible workspace. When returning to a multi-display
    /// setup, workspaces return to the display matching their `preferredDisplaySize`.
    public mutating func setDisplays(_ new: [Display]) {
        displays = new
        guard let primary = new.first else {
            visible.removeAll()
            pruneEmptyWorkspaces()
            return
        }
        let ids = Set(new.map(\.id))

        if new.count > 1 {
            for (id, ws) in workspaces {
                let current = display(ws.displayID)
                if let pref = ws.preferredDisplaySize {
                    func dist(_ d: Display) -> CGFloat {
                        abs(d.frame.width - pref.width) + abs(d.frame.height - pref.height)
                    }
                    // Keep the workspace on its current display unless that display vanished or
                    // another display is a closer size match to `pref`.
                    let best: Display
                    if let current, let candidate = new.min(by: { dist($0) < dist($1) }), dist(candidate) + 1 < dist(current) {
                        best = candidate
                    } else if let current {
                        best = current
                    } else if let candidate = new.min(by: { dist($0) < dist($1) }) {
                        best = candidate
                    } else {
                        best = primary
                    }
                    workspaces[id]!.displayID = best.id
                    workspaces[id]!.preferredDisplaySize = best.frame.size
                } else if let current {
                    workspaces[id]!.preferredDisplaySize = current.frame.size
                } else {
                    workspaces[id]!.displayID = primary.id
                    workspaces[id]!.preferredDisplaySize = primary.frame.size
                }
            }
        } else {
            for (id, ws) in workspaces where !ids.contains(ws.displayID) {
                workspaces[id]!.displayID = primary.id
            }
        }

        var nextVisible: [DisplayID: Int] = [:]
        for (dID, wsID) in visible {
            guard let ws = workspaces[wsID], ids.contains(ws.displayID) else { continue }
            if ws.displayID == dID {
                nextVisible[dID] = wsID
            } else if nextVisible[ws.displayID] == nil {
                nextVisible[ws.displayID] = wsID
            }
        }
        visible = nextVisible
        pruneEmptyWorkspaces()

        for d in new where visible[d.id] == nil {
            if let existing = workspaces.values.filter({ $0.displayID == d.id }).min(by: { $0.id < $1.id }) {
                visible[d.id] = existing.id
            } else {
                let id = lowestFreeWorkspaceID()
                let pref = new.count > 1 ? d.frame.size : nil
                workspaces[id] = Workspace(id: id, displayID: d.id, preferredDisplaySize: pref)
                visible[d.id] = id
            }
        }

        if let f = focused, let ws = workspace(containing: f), ids.contains(ws.displayID) {
            focusedDisplay = ws.displayID
        } else if focusedDisplay.map({ !ids.contains($0) }) ?? true {
            focusedDisplay = primary.id
        }
        if let f = focused, workspace(containing: f) == nil { focused = nil }
    }

    private func lowestFreeWorkspaceID() -> Int {
        var id = firstWorkspaceID
        while workspaces[id] != nil { id += 1 }
        return id
    }

    /// Removes empty workspaces that are not currently visible on any display, so an empty
    /// workspace is unpinned from its display as soon as it moves to the background.
    private mutating func pruneEmptyWorkspaces() {
        let visibleIDs = Set(visible.values)
        for (id, ws) in workspaces where ws.isEmpty && !visibleIDs.contains(id) {
            workspaces[id] = nil
        }
    }

    /// Replaces all workspaces and the visible map wholesale (used when restoring a snapshot;
    /// call `setDisplays` afterwards to re-establish the invariants).
    mutating func restore(workspaces: [Int: Workspace], visible: [DisplayID: Int]) {
        self.workspaces = workspaces
        self.visible = visible
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

    /// Whether `w` is a foreground window on a currently visible workspace (eligible to sit
    /// above the workspace scrim and to receive mouse-hover focus).
    public func isVisibleForeground(_ w: WindowID) -> Bool {
        guard let ws = workspace(containing: w), isVisible(ws.id) else { return false }
        return ws.foregroundWindows.contains(w)
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
        pruneEmptyWorkspaces()
    }

    // MARK: Focus

    public mutating func setFocused(_ w: WindowID?) {
        focused = w
        guard let w, let ws = workspace(containing: w) else { return }
        workspaces[ws.id]!.focused = w
        focusedDisplay = ws.displayID
        visible[ws.displayID] = ws.id
        pruneEmptyWorkspaces()
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
            let pref = displays.count > 1 ? display(d)?.frame.size : nil
            workspaces[id] = Workspace(id: id, displayID: d, preferredDisplaySize: pref)
        }
        let ws = workspaces[id]!
        visible[ws.displayID] = id
        focusedDisplay = ws.displayID
        focused = ws.focused.flatMap { ws.contains($0) ? $0 : nil } ?? ws.tree.allStacks.first?.topWindow
        pruneEmptyWorkspaces()
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

    /// Adds `w` to workspace `id` (creating it on the focused display if needed), stacked on
    /// `near` when that window is still there, else on the workspace's focused window.
    /// Does not change focus or visibility — used to put a returning window back in place.
    public mutating func add(_ w: WindowID, toWorkspace id: Int, near: WindowID? = nil, floating: Bool = false) {
        guard workspace(containing: w) == nil else { return }
        if workspaces[id] == nil {
            guard let d = focusedDisplay ?? primaryDisplay?.id else { return }
            let pref = displays.count > 1 ? display(d)?.frame.size : nil
            workspaces[id] = Workspace(id: id, displayID: d, preferredDisplaySize: pref)
        }
        if floating {
            workspaces[id]!.floating.insert(w)
            return
        }
        let anchor = near.flatMap { workspaces[id]!.tree.contains($0) ? $0 : nil } ?? workspaces[id]!.focused
        workspaces[id]!.tree.insert(w, near: anchor)
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
        pruneEmptyWorkspaces()
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
            let pref = displays.count > 1 ? display(src.displayID)?.frame.size : src.preferredDisplaySize
            workspaces[id] = Workspace(id: id, displayID: src.displayID, preferredDisplaySize: pref)
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

    /// Moves the focused workspace to the display in `dir`, swapping it with the workspace
    /// that display is currently showing. Returns `false` if there is no display that way.
    @discardableResult
    public mutating func moveFocusedWorkspace(toDisplay dir: Direction) -> Bool {
        guard let ws = focusedWorkspace, let target = display(in: dir, from: ws.displayID), target.id != ws.displayID else { return false }
        let source = ws.displayID
        if let otherID = visible[target.id] {
            workspaces[otherID]!.displayID = source
            if displays.count > 1 { workspaces[otherID]!.preferredDisplaySize = display(source)?.frame.size }
            visible[source] = otherID
        }
        workspaces[ws.id]!.displayID = target.id
        if displays.count > 1 { workspaces[ws.id]!.preferredDisplaySize = target.frame.size }
        visible[target.id] = ws.id
        focusedDisplay = target.id
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
