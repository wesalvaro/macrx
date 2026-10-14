import AppKit
import MacrxCore

/// Owns the workspace model and applies it to real windows. All state changes go through here.
@MainActor
final class WindowManager {
    private(set) var config: Config
    private var model: WorkspaceModel

    private let displays: DisplayManager
    private let watcher: WindowWatcher
    private let mouse: MouseController
    private let tabBars: TabBarController

    private var axWindows: [WindowID: AXWindow] = [:]
    private var titles: [WindowID: String] = [:]
    private var ignored: Set<WindowID> = []
    /// Last frame we applied to each window (nil for parked windows).
    private var lastApplied: [WindowID: CGRect] = [:]
    private var parked: Set<WindowID> = []
    /// Currently visible tiles, with the display each belongs to.
    private var tiles: [(tile: Tile, display: DisplayID)] = []
    private var desiredFrames: [WindowID: CGRect] = [:]
    /// Frames actually achieved for windows that refused their tile size (centered in the tile).
    private var effectiveFrames: [WindowID: CGRect] = [:]
    private var verifyScheduled = false
    private var lastCorrection: [WindowID: Date] = [:]

    var onQuit: (() -> Void)?
    var onReload: (() -> Void)?

    init(config: Config, displays: DisplayManager, watcher: WindowWatcher, mouse: MouseController, tabBars: TabBarController) {
        self.config = config
        self.displays = displays
        self.watcher = watcher
        self.mouse = mouse
        self.tabBars = tabBars
        self.model = WorkspaceModel(displays: displays.displays)

        displays.onChange = { [weak self] d in self?.displaysChanged(d) }
        watcher.onEvent = { [weak self] e in self?.handle(e) }
        mouse.onPointerMoved = { [weak self] p in self?.pointerMoved(to: p) }
        tabBars.onTabClicked = { [weak self] w in self?.focus(w, warp: false) }
        applyConfig(config)
    }

    func start() {
        watcher.start()
        if let p = displays.display(containing: mouse.location) { model.setFocusedDisplay(p.id) }
    }

    func applyConfig(_ cfg: Config) {
        config = cfg
        tabBars.fontSize = CGFloat(cfg.tabBar.fontSize)
        if cfg.focusFollowsMouse { mouse.startFollowing() } else { mouse.stopFollowing() }
        applyLayout()
    }

    private var rules: WindowRules { WindowRules(rules: config.rules) }

    // MARK: - Events

    private func handle(_ event: WindowEvent) {
        switch event {
        case .created(let w, let app):
            windowCreated(w, app: app)
        case .destroyed(let id):
            windowDestroyed(id)
        case .focused(let id):
            externalFocus(id)
        case .titleChanged(let id):
            guard let w = axWindows[id] else { return }
            titles[id] = w.title
            syncTabBars()
        case .frameChanged(let id):
            guard axWindows[id] != nil, !parked.contains(id) else { return }
            scheduleVerify()
        }
    }

    private func windowCreated(_ w: AXWindow, app: AXApp) {
        guard axWindows[w.id] == nil, !ignored.contains(w.id) else { return }
        switch rules.disposition(for: w, bundleID: app.bundleID) {
        case .ignore:
            ignored.insert(w.id)
            return
        case .float:
            axWindows[w.id] = w
            titles[w.id] = w.title
            model.add(w.id, floating: true, on: display(of: w))
        case .tile:
            axWindows[w.id] = w
            titles[w.id] = w.title
            model.add(w.id, on: display(of: w))
            applyLayout()
            focus(w.id)
        }
        log("+ \(app.name) '\(w.title)' \(w.id)")
    }

    private func windowDestroyed(_ id: WindowID) {
        ignored.remove(id)
        guard axWindows[id] != nil else { return }
        let wasFocused = model.focused == id
        let replacement = model.remove(id)
        axWindows[id] = nil
        titles[id] = nil
        lastApplied[id] = nil
        effectiveFrames[id] = nil
        parked.remove(id)
        applyLayout()
        if wasFocused, let r = replacement { focus(r) }
        log("- \(id)")
    }

    /// The system says `id` is focused (click, ⌘-Tab, app activation…). Fold it into the model.
    private func externalFocus(_ id: WindowID) {
        guard axWindows[id] != nil, model.focused != id, let ws = model.workspace(containing: id) else { return }
        // AX focus notifications echo our own raise/activate calls, sometimes late. Only trust
        // a report that matches reality: the app is frontmost and this is its focused window.
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == id.pid,
              watcher.app(for: id.pid)?.focusedWindow?.id == id else { return }
        log("external focus \(id)")
        if !model.isVisible(ws.id) { model.focusWorkspace(ws.id) }
        model.setFocused(id)
        model.update(ws.id) { $0.tree.makeTop(id) }
        applyLayout()
        mouse.suppress()
    }

    private func displaysChanged(_ d: [Display]) {
        model.setDisplays(d)
        lastApplied.removeAll()
        applyLayout()
    }

    /// Display under the window's current center, falling back to the focused display.
    private func display(of w: AXWindow) -> DisplayID? {
        guard let f = w.frame, f.width > 0 else { return nil }
        return displays.display(containing: f.center)?.id
    }

    // MARK: - Focus

    func focus(_ id: WindowID, warp: Bool = true) {
        guard let ax = axWindows[id], let ws = model.workspace(containing: id) else { return }
        if !model.isVisible(ws.id) { model.focusWorkspace(ws.id) }
        model.setFocused(id)
        model.update(ws.id) { $0.tree.makeTop(id) }
        applyLayout()

        ax.raise()
        watcher.app(for: id.pid)?.activate()
        // Activation reorders all of the app's windows; re-assert ours shortly after.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self, self.model.focused == id else { return }
            ax.raise()
            self.tabBars.bringToFront()
        }

        if warp && config.mouseFollowsFocus, let f = currentFrame(of: id) {
            mouse.warp(to: f.center)
        } else {
            mouse.suppress()
        }
    }

    private func focusDisplay(_ d: Display) {
        model.setFocusedDisplay(d.id)
        if let w = model.focusedWorkspace?.focused, axWindows[w] != nil {
            focus(w)
        } else if config.mouseFollowsFocus {
            mouse.warp(to: d.frame.center)
        }
    }

    private func currentFrame(of id: WindowID) -> CGRect? {
        if let t = tiles.first(where: { $0.tile.top == id }) { return t.tile.content }
        return desiredFrames[id] ?? axWindows[id]?.frame
    }

    private func pointerMoved(to p: CGPoint) {
        guard config.focusFollowsMouse else { return }
        // Respect the real z-order: a floating / dialog / unmanaged window over a tile wins.
        if let topmost = Self.topmostWindow(at: p) {
            guard axWindows[topmost] != nil else { return }  // unmanaged window: don't steal focus
            if topmost != model.focused { focus(topmost, warp: false) }
            return
        }
        // Nothing at the normal window layer (e.g. the pointer is over our tab bar or the desktop).
        guard let hit = tiles.first(where: { $0.tile.frame.contains(p) }) else { return }
        let target = hit.tile.top
        if target != model.focused { focus(target, warp: false) }
    }

    /// The frontmost normal-layer on-screen window containing `p` (CG/AX coordinates).
    private static func topmostWindow(at p: CGPoint) -> WindowID? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return nil }
        for info in list {
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let pid = info[kCGWindowOwnerPID as String] as? Int32,
                  let num = info[kCGWindowNumber as String] as? UInt32,
                  let b = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = b["X"], let y = b["Y"], let w = b["Width"], let h = b["Height"]
            else { continue }
            if CGRect(x: x, y: y, width: w, height: h).contains(p) {
                return WindowID(pid: pid, cgID: num)
            }
        }
        return nil
    }

    // MARK: - Commands

    func perform(_ cmd: Command) {
        log("cmd \(cmd) focused=\(model.focused.map(String.init(describing:)) ?? "nil")")
        switch cmd {
        case .focus(let dir): focusNeighbor(dir)
        case .move(let dir): moveFocused(dir)
        case .resize(let dir):
            guard let w = model.focused, let ws = model.workspace(containing: w) else { return }
            model.update(ws.id) { $0.tree.resize(w, dir, step: CGFloat(config.resizeStep)) }
            applyLayout()
        case .stack(let delta):
            guard let w = model.focused, let ws = model.workspace(containing: w) else { return }
            var next: WindowID?
            model.update(ws.id) { next = $0.tree.cycleStack(w, by: delta) }
            // Same tile, so the pointer is already over the window: don't move it.
            if let next { focus(next, warp: false) }
        case .moveToDisplay(let dir):
            guard let w = model.focused, model.moveWindow(w, toDisplay: dir) else { return }
            applyLayout()
            focus(w)
        case .workspace(let n):
            let before = model.focusedWorkspace?.id
            let target = model.focusWorkspace(n)
            guard before != n || target != model.focused else { return }
            applyLayout()
            if let target { focus(target) } else if let d = model.focusedDisplay.flatMap(model.display) {
                mouse.suppress()
                if config.mouseFollowsFocus { mouse.warp(to: d.frame.center) }
            }
        case .moveToWorkspace(let n):
            guard let w = model.focused else { return }
            let replacement = model.moveWindow(w, toWorkspace: n)
            applyLayout()
            if let replacement { focus(replacement) }
        case .fullscreen:
            guard let w = model.focused else { return }
            model.toggleFullscreen(w)
            applyLayout()
            focus(w)
        case .float:
            guard let w = model.focused else { return }
            model.toggleFloating(w)
            lastApplied[w] = nil
            applyLayout()
            focus(w)
        case .toggleOrientation:
            guard let w = model.focused, let ws = model.workspace(containing: w) else { return }
            model.update(ws.id) { $0.tree.toggleParentOrientation(w) }
            applyLayout()
        case .reload: onReload?()
        case .quit: onQuit?()
        }
    }

    private func focusNeighbor(_ dir: Direction) {
        guard let focused = model.focused, let origin = currentFrame(of: focused) else {
            // Nothing focused: pick something on the focused display.
            if let t = tiles.first(where: { $0.display == model.focusedDisplay }) { focus(t.tile.top) }
            return
        }
        let cands = tiles.filter { $0.tile.top != focused }.map { Navigation.Candidate(id: $0.tile.top, frame: $0.tile.frame) }
        if let n = Navigation.neighbor(from: origin, dir: dir, among: cands) {
            focus(n.id)
        } else if let ws = model.workspace(containing: focused), let d = model.display(in: dir, from: ws.displayID) {
            focusDisplay(d)
        }
    }

    private func moveFocused(_ dir: Direction) {
        guard let w = model.focused, let ws = model.workspace(containing: w), !ws.floating.contains(w),
              let display = model.display(ws.displayID) else { return }
        var result = MoveResult.noop
        model.update(ws.id) { result = $0.tree.move(w, dir, in: display.frame) }
        switch result {
        case .moved: break
        case .needsDisplayMove:
            guard model.moveWindow(w, toDisplay: dir) else { return }
        case .noop: return
        }
        applyLayout()
        focus(w)
    }

    // MARK: - Layout

    private func tabBarHeight(_ count: Int) -> CGFloat {
        config.tabBar.height(forWindowCount: count)
    }

    func applyLayout() {
        var desired: [WindowID: CGRect] = [:]
        var toPark: Set<WindowID> = []
        var newTiles: [(tile: Tile, display: DisplayID)] = []
        var fullscreenDisplays: Set<DisplayID> = []

        for display in model.displays {
            for ws in model.workspaces.values where ws.displayID == display.id {
                let visible = model.isVisible(ws.id)
                guard visible else {
                    ws.allWindows.forEach { toPark.insert($0) }
                    continue
                }
                let ts = LayoutEngine.tiles(ws.tree, in: display.frame, tabBarHeight: tabBarHeight)
                for t in ts {
                    desired[t.top] = t.content
                    for w in t.windows where w != t.top { toPark.insert(w) }
                    newTiles.append((t, display.id))
                }
                if let fs = ws.fullscreen, ws.contains(fs) {
                    desired[fs] = display.frame
                    fullscreenDisplays.insert(display.id)
                }
            }
        }
        tiles = newTiles
        desiredFrames = desired

        for (id, rect) in desired {
            guard let ax = axWindows[id] else { continue }
            if parked.contains(id) || lastApplied[id] != rect {
                place(ax, in: rect)
                lastApplied[id] = rect
                parked.remove(id)
            }
        }
        for id in toPark where !parked.contains(id) {
            guard let ax = axWindows[id], let ws = model.workspace(containing: id),
                  let full = displays.fullFrames[ws.displayID] ?? model.display(ws.displayID)?.frame else { continue }
            ax.setPosition(CGPoint(x: full.maxX - 2, y: full.maxY - 2))
            parked.insert(id)
            lastApplied[id] = nil
        }

        syncTabBars(excluding: fullscreenDisplays)
    }

    private func syncTabBars(excluding fullscreenDisplays: Set<DisplayID> = []) {
        let visibleTiles = tiles.filter { !fullscreenDisplays.contains($0.display) }.map(\.tile)
        tabBars.sync(tiles: visibleTiles, focused: model.focused) { [self] id in
            TabItem(id: id, title: titles[id] ?? "", icon: watcher.app(for: id.pid)?.icon)
        }
    }

    /// Applies `rect`; if the app clamps the size (minimum-size constraints), centers the
    /// window inside the tile instead of leaving it in the corner. Returns the effective frame.
    @discardableResult
    private func place(_ ax: AXWindow, in rect: CGRect) -> CGRect {
        ax.setFrame(rect)
        guard let actual = ax.frame else { return rect }
        if abs(actual.width - rect.width) > 2 || abs(actual.height - rect.height) > 2 {
            let centered = CGRect(
                x: rect.midX - actual.width / 2, y: rect.midY - actual.height / 2,
                width: actual.width, height: actual.height)
            ax.setPosition(centered.origin)
            effectiveFrames[ax.id] = centered
            return centered
        }
        effectiveFrames[ax.id] = nil
        return rect
    }

    /// After an app moves/resizes its own window, put it back where the layout wants it.
    private func scheduleVerify() {
        guard !verifyScheduled else { return }
        verifyScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            self.verifyScheduled = false
            let now = Date()
            for (id, desired) in self.desiredFrames {
                guard let ax = self.axWindows[id], let have = ax.frame else { continue }
                let want = self.effectiveFrames[id] ?? desired
                let off = abs(have.minX - want.minX) + abs(have.minY - want.minY)
                    + abs(have.width - want.width) + abs(have.height - want.height)
                guard off > 2 else { continue }
                // Avoid fighting apps that enforce a minimum size: at most one correction per second.
                if let last = self.lastCorrection[id], now.timeIntervalSince(last) < 1 { continue }
                self.lastCorrection[id] = now
                self.place(ax, in: desired)
            }
        }
    }

    // MARK: - Shutdown

    /// Brings every parked (off-screen) window back on screen so nothing is lost when macrx exits.
    func restoreParkedWindows() {
        for id in parked {
            guard let ax = axWindows[id], let ws = model.workspace(containing: id),
                  let d = model.display(ws.displayID) else { continue }
            ax.setFrame(d.frame)
        }
        parked.removeAll()
    }

    // MARK: - Debug

    private func log(_ s: String) {
        FileHandle.standardError.write(("[macrx] " + s + "\n").data(using: .utf8)!)
    }
}
