import Foundation
import CoreGraphics

// MARK: - Codable conformances for the model's value types

extension SizeSpec: Codable {
    private enum Key: String, CodingKey { case flex, fixed }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        if let f = try c.decodeIfPresent(CGFloat.self, forKey: .fixed) { self = .fixed(f) }
        else { self = .flex(try c.decodeIfPresent(CGFloat.self, forKey: .flex) ?? 1) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        switch self {
        case .flex(let w): try c.encode(w, forKey: .flex)
        case .fixed(let p): try c.encode(p, forKey: .fixed)
        }
    }
}

// MARK: - Snapshot

/// A serialisable picture of one layout tree node.
public indirect enum NodeSnapshot: Codable, Equatable {
    case split(orientation: Orientation, size: SizeSpec, children: [NodeSnapshot])
    case stack(windows: [WindowID], top: Int, size: SizeSpec)

    private enum Key: String, CodingKey { case split, size, children, stack, top }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        let size = try c.decodeIfPresent(SizeSpec.self, forKey: .size) ?? .default
        if let o = try c.decodeIfPresent(Orientation.self, forKey: .split) {
            self = .split(orientation: o, size: size, children: try c.decodeIfPresent([NodeSnapshot].self, forKey: .children) ?? [])
        } else {
            self = .stack(windows: try c.decodeIfPresent([WindowID].self, forKey: .stack) ?? [],
                          top: try c.decodeIfPresent(Int.self, forKey: .top) ?? 0, size: size)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        switch self {
        case .split(let o, let size, let children):
            try c.encode(o, forKey: .split); try c.encode(size, forKey: .size); try c.encode(children, forKey: .children)
        case .stack(let windows, let top, let size):
            try c.encode(windows, forKey: .stack); try c.encode(top, forKey: .top); try c.encode(size, forKey: .size)
        }
    }
}

public struct WorkspaceSnapshot: Codable, Equatable {
    public var id: Int
    public var display: UInt32
    public var visible: Bool
    public var focused: WindowID?
    public var floating: [WindowID]
    public var fullscreen: WindowID?
    public var tree: NodeSnapshot?
}

/// Everything needed to bring the layout back after a restart within the same login session.
public struct LayoutSnapshot: Codable, Equatable {
    public static let currentVersion = 1
    public var version = LayoutSnapshot.currentVersion
    /// `kern.boottime` seconds: pids and window numbers are meaningless after a reboot.
    public var bootTime: Int
    public var savedAt: Int
    public var focusedDisplay: UInt32?
    public var focusedWindow: WindowID?
    public var workspaces: [WorkspaceSnapshot]

    public var allWindows: Set<WindowID> {
        var out: Set<WindowID> = []
        for ws in workspaces {
            out.formUnion(ws.floating)
            if let t = ws.tree { out.formUnion(t.allWindows) }
        }
        return out
    }
}

extension NodeSnapshot {
    public var allWindows: [WindowID] {
        switch self {
        case .stack(let w, _, _): return w
        case .split(_, _, let c): return c.flatMap(\.allWindows)
        }
    }
}

// MARK: - Node ⇄ snapshot

extension Node {
    public func snapshot() -> NodeSnapshot {
        if isStack { return .stack(windows: windows, top: top, size: size) }
        return .split(orientation: orientation!, size: size, children: children.map { $0.snapshot() })
    }

    public convenience init(_ s: NodeSnapshot) {
        switch s {
        case .stack(let windows, let top, let size):
            self.init(stack: windows, top: top)
            self.size = size
        case .split(let o, let size, let children):
            self.init(split: o, children: children.map(Node.init))
            self.size = size
        }
    }
}

// MARK: - Model ⇄ snapshot

extension WorkspaceModel {
    public func snapshot(bootTime: Int, now: Date = Date()) -> LayoutSnapshot {
        let wss = workspaces.values.sorted { $0.id < $1.id }.map { ws in
            WorkspaceSnapshot(id: ws.id, display: ws.displayID.raw, visible: isVisible(ws.id),
                              focused: ws.focused, floating: ws.floating.sorted { ($0.pid, $0.cgID) < ($1.pid, $1.cgID) },
                              fullscreen: ws.fullscreen, tree: ws.tree.root?.snapshot())
        }
        return LayoutSnapshot(bootTime: bootTime, savedAt: Int(now.timeIntervalSince1970),
                              focusedDisplay: focusedDisplay?.raw, focusedWindow: focused, workspaces: wss)
    }

    /// Rebuilds the model from `s` on the *current* displays. Workspaces whose display is gone
    /// move to the primary display; every display ends up with exactly one visible workspace.
    public init(restoring s: LayoutSnapshot, displays: [Display], firstWorkspaceID: Int = 0) {
        self.init(displays: [], firstWorkspaceID: firstWorkspaceID)
        let known = Set(displays.map(\.id))
        var restored: [Int: Workspace] = [:]
        var vis: [DisplayID: Int] = [:]
        for w in s.workspaces {
            var ws = Workspace(id: w.id, displayID: DisplayID(w.display))
            ws.tree = Tree(root: w.tree.map(Node.init))
            ws.tree.normalize()
            ws.floating = Set(w.floating)
            ws.fullscreen = w.fullscreen
            ws.focused = w.focused.flatMap { ws.contains($0) ? $0 : nil }
            restored[w.id] = ws
            if w.visible, known.contains(ws.displayID) { vis[ws.displayID] = w.id }
        }
        restore(workspaces: restored, visible: vis)
        // Visible-per-display for displays that were missing from the snapshot, migration of
        // orphaned workspaces, and a valid focused display all come from the normal path.
        setDisplays(displays)
        if let d = s.focusedDisplay.map(DisplayID.init), known.contains(d) { setFocusedDisplay(d) }
        if let f = s.focusedWindow, workspace(containing: f) != nil { setFocused(f) }
    }

    /// Every window the model currently knows about.
    public var allWindows: Set<WindowID> {
        Set(workspaces.values.flatMap(\.allWindows))
    }
}
