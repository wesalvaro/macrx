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
    private let statusBar = StatusBar()

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
    /// Largest size each window has accepted along an axis it clamps (`.infinity` on a free axis).
    /// Fed to the layout engine so a tile of only size-capped windows shrinks to fit them.
    private var observedMax: [WindowID: CGSize] = [:]
    private var relayoutPending = false
    /// The tab rect of each window in a tab bar; size-constrained windows are anchored under it.
    private var tabAnchors: [WindowID: CGRect] = [:]
    private var verifyScheduled = false
    private var lastCorrection: [WindowID: Date] = [:]
    private var lastFocusAt = Date.distantPast
    /// For `workspace back-and-forth`.
    private var currentWorkspaceID: Int?
    private var previousWorkspaceID: Int?
    /// Tiled windows the user is currently drag-resizing (applied on mouse-up).
    private var userResizing: Set<WindowID> = []
    /// `true` while the user is dragging a tab in a tab bar.
    private var isDraggingTab = false
    /// Where a window lived when it was removed, kept briefly so a window that is "destroyed"
    /// and "created" again with the same ID (AX hiccup after sleep) returns to its place silently.
    private struct Departed { let workspace: Int; let neighbour: WindowID?; let floating: Bool; let at: Date }
    private var departed: [WindowID: Departed] = [:]
    private let departedTTL: TimeInterval = 120

    var onQuit: (() -> Void)?
    var onReload: (() -> Void)?

    init(config: Config, displays: DisplayManager, watcher: WindowWatcher, mouse: MouseController, tabBars: TabBarController) {
        self.config = config
        self.displays = displays
        self.watcher = watcher
        self.mouse = mouse
        self.tabBars = tabBars
        self.model = WorkspaceModel(displays: displays.displays, firstWorkspaceID: config.firstWorkspace)

        displays.onChange = { [weak self] d in self?.displaysChanged(d) }
        watcher.onEvent = { [weak self] e in self?.handle(e) }
        mouse.onPointerMoved = { [weak self] p in self?.pointerMoved(to: p) }
        mouse.onMouseUp = { [weak self] in self?.finishUserResize() }
        mouse.startDragTracking()
        tabBars.onTabClicked = { [weak self] w in self?.focus(w, warp: false) }
        tabBars.onTabClosed = { [weak self] w in self?.closeWindow(w) }
        tabBars.menuForTab = { [weak self] w in self?.buildTabMenu(for: w) }
        tabBars.onDragUpdated = { [weak self] w, p in self?.tabDragUpdated(w, at: p) }
        tabBars.onDragEnded = { [weak self] w, p in self?.tabDragEnded(w, at: p) }
        statusBar.onSelectWorkspace = { [weak self] n in self?.perform(.workspace(n)) }
        statusBar.onReload = { [weak self] in self?.onReload?() }
        statusBar.onQuit = { [weak self] in self?.onQuit?() }
        applyConfig(config)
    }

    func start() {
        watcher.start()
        if let p = displays.display(containing: mouse.location) { model.setFocusedDisplay(p.id) }
    }

    func applyConfig(_ cfg: Config) {
        config = cfg
        model.firstWorkspaceID = cfg.firstWorkspace
        tabBars.fontSize = CGFloat(cfg.tabBar.fontSize)
        tabBars.widthMode = cfg.tabBar.tabWidth
        if cfg.focusFollowsMouse { mouse.startFollowing() } else { mouse.stopFollowing() }
        statusBar.isShown = cfg.menuBar
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
            // A change while the button is held is the user dragging an edge: let it happen and
            // fold it into the layout on mouse-up. Anything else gets snapped back.
            if mouse.isPrimaryButtonDown, desiredFrames[id] != nil, effectiveFrames[id] == nil {
                userResizing.insert(id)
            } else if userResizing.isEmpty {
                scheduleVerify()
            }
        }
    }

    private func windowCreated(_ w: AXWindow, app: AXApp) {
        guard axWindows[w.id] == nil, !ignored.contains(w.id) else { return }
        departed = departed.filter { Date().timeIntervalSince($0.value.at) < departedTTL }
        if let d = departed.removeValue(forKey: w.id) {
            // Returning window: back to its old workspace/stack, no focus change, no pointer warp.
            axWindows[w.id] = w
            titles[w.id] = w.title
            model.add(w.id, toWorkspace: d.workspace, near: d.neighbour, floating: d.floating)
            applyLayout()
            log("↩ \(app.name) '\(w.title)' \(w.id) back to workspace \(d.workspace)")
            return
        }
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
        if let ws = model.workspace(containing: id) {
            let neighbour = ws.tree.stack(containing: id)?.windows.first { $0 != id }
            departed[id] = Departed(workspace: ws.id, neighbour: neighbour, floating: ws.floating.contains(id), at: Date())
        }
        let wasFocused = model.focused == id
        let replacement = model.remove(id)
        axWindows[id] = nil
        titles[id] = nil
        lastApplied[id] = nil
        effectiveFrames[id] = nil
        observedMax[id] = nil
        parked.remove(id)
        applyLayout()
        if wasFocused, let r = replacement { focus(r) }
        log("- \(id)")
    }

    /// The system says `id` is focused (click, ⌘-Tab, app activation…). Fold it into the model.
    private func externalFocus(_ id: WindowID, verified: Bool = false) {
        guard axWindows[id] != nil, model.focused != id, let ws = model.workspace(containing: id) else { return }
        // AX focus notifications echo our own raise/activate calls, sometimes late. Only trust
        // a report that matches reality: the app is frontmost and this is its focused window.
        // NSWorkspace's notion of "frontmost" lags the notification, so check on the next tick.
        guard verified else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.externalFocus(id, verified: true) }
            return
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == id.pid,
              watcher.app(for: id.pid)?.focusedWindow?.id == id else {
            log("ignored stale focus report \(id)")
            return
        }
        // Right after we focused a different window of the same app, a report for the old window
        // is the app lagging (or refusing) the key-window switch, not the user — don't ping-pong.
        if let f = model.focused, f.pid == id.pid, Date().timeIntervalSince(lastFocusAt) < 1.0 {
            log("ignored same-app focus report \(id) shortly after focusing \(f)")
            return
        }
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

    /// Tracks the previously focused workspace for `workspace back-and-forth`.
    private func noteWorkspaceChange() {
        let now = model.focusedWorkspace?.id
        if now != currentWorkspaceID {
            previousWorkspaceID = currentWorkspaceID
            currentWorkspaceID = now
        }
    }

    func focus(_ id: WindowID, warp: Bool = true) {
        defer { noteWorkspaceChange() }
        guard let ax = axWindows[id], let ws = model.workspace(containing: id) else { return }
        log("focus \(id) '\(titles[id] ?? "")' warp=\(warp)")
        lastFocusAt = Date()
        if !model.isVisible(ws.id) { model.focusWorkspace(ws.id) }
        model.setFocused(id)
        model.update(ws.id) { $0.tree.makeTop(id) }
        applyLayout()

        // Window-server level focus (handles apps that ignore AX focus attributes, e.g. kitty),
        // then the AX path which also covers the fallback when SkyLight isn't available.
        let sl = SkyLight.focus(pid: id.pid, windowID: id.cgID)
        if !sl { log("skylight focus unavailable/failed for \(id)") }
        ax.raise()
        watcher.app(for: id.pid)?.activate()
        // Activation reorders all of the app's windows; re-assert ours shortly after.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self, self.model.focused == id else { return }
            ax.raise()
            self.raiseStackTops()
            self.tabBars.bringToFront()
        }
        // Some apps (GLFW-based like kitty) ignore every programmatic key-window switch within
        // the app. For apps opted in via a `click-to-focus` rule, click the title bar if needed.
        if let app = watcher.app(for: id.pid), rules.clickToFocus(bundleID: app.bundleID, title: titles[id] ?? "") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                guard let self, self.model.focused == id else { return }
                let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
                let key = app.focusedWindow?.id
                guard front == id.pid, let key, key != id, let f = ax.frame else { return }
                self.log("app kept \(key) as key window; clicking title bar of \(id)")
                self.mouse.clickAndRestore(at: CGPoint(x: f.midX, y: f.minY + 8))
            }
        }

        if effectiveFrames[id] != nil {
            bringConstrainedWindowToPointer(id, mayWarp: warp && config.mouseFollowsFocus)
        } else if warp && config.mouseFollowsFocus, let f = currentFrame(of: id) {
            mouse.warp(to: f.center)
        } else {
            mouse.suppress()
        }
    }

    /// A size-constrained window can't fill its tile, so focusing it would otherwise leave the
    /// pointer over whatever is behind it. Bring the window to the pointer instead: centred on it,
    /// clamped to the tile (so from the tab bar it hugs the top edge). For keyboard focus
    /// (`mayWarp`), a pointer outside the tile is first warped to the tile's centre.
    private func bringConstrainedWindowToPointer(_ id: WindowID, mayWarp: Bool) {
        guard let eff = effectiveFrames[id], let content = desiredFrames[id], let ax = axWindows[id] else { return }
        var p = mouse.location
        if !content.contains(p) {
            if mayWarp {
                p = content.center
                mouse.warp(to: p)
            } else {
                // e.g. hovering the tab bar: aim at the nearest point inside the tile.
                mouse.suppress()
                p = CGPoint(x: min(max(p.x, content.minX), content.maxX), y: min(max(p.y, content.minY), content.maxY))
            }
        } else {
            mouse.suppress()
        }
        guard !eff.contains(p) else { return }
        let moved = Self.centered(size: eff.size, on: p, within: content)
        ax.setPosition(moved.origin)
        effectiveFrames[id] = moved
    }

    /// A rect of `size` centred on `p`, clamped to stay inside `bounds`.
    private static func centered(size: CGSize, on p: CGPoint, within bounds: CGRect) -> CGRect {
        let x = min(max(p.x - size.width / 2, bounds.minX), max(bounds.minX, bounds.maxX - size.width))
        let y = min(max(p.y - size.height / 2, bounds.minY), max(bounds.minY, bounds.maxY - size.height))
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
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
        guard !isDraggingTab, config.focusFollowsMouse else { return }
        // Tab bars: hovering a tab switches to it (unless hovering its × close button).
        // Never look through the bar at windows beneath.
        if tabBars.frames.values.contains(where: { $0.contains(p) }) {
            let hit = tabBars.tab(at: p)
            tabBars.setHovered(hit?.window, closeHovered: hit?.onClose ?? false)
            if config.tabBar.switchOn == .hover, let hit, !hit.onClose,
               let tile = tiles.first(where: { $0.tile.stackID == hit.stack })?.tile,
               hit.window != tile.top {
                focus(hit.window, warp: false)
            }
            return
        }
        tabBars.setHovered(nil)
        // Respect the real z-order: a floating / dialog / unmanaged window over a tile wins.
        // Only actual window content counts — the desktop does nothing.
        guard let topmost = Self.topmostWindow(at: p), axWindows[topmost] != nil else { return }
        // Parked windows (hidden stack members / other workspaces) only show a sliver; never hover-focus them.
        guard !parked.contains(topmost) else { return }
        if topmost != model.focused {
            log("hover \(p) → \(topmost)")
            focus(topmost, warp: false)
        }
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
        defer { noteWorkspaceChange() }
        switch cmd {
        case .workspaceBack:
            if let prev = previousWorkspaceID, prev != model.focusedWorkspace?.id { perform(.workspace(prev)) }
        case .focus(let dir): focusNeighbor(dir)
        case .move(let dir): moveFocused(dir)
        case .resize(let dir):
            guard let w = model.focused, let ws = model.workspace(containing: w), let d = model.display(ws.displayID) else { return }
            let caps = observedMax
            model.update(ws.id) { $0.tree.resize(w, dir, step: CGFloat(config.resizeStep), in: d.frame, maxSize: { caps[$0] }) }
            applyLayout()
        case .resizeReset:
            guard let w = model.focused, let ws = model.workspace(containing: w) else { return }
            model.update(ws.id) { $0.tree.resetSize(w) }
            applyLayout()
        case .stack(let delta):
            // All visible tabs, across tiles and displays, behave as one long tab strip:
            // stepping past the end of a stack continues into the neighbouring tile.
            guard let w = model.focused else { return }
            let strip = tiles.flatMap { $0.tile.windows }
            guard let i = strip.firstIndex(of: w), strip.count > 1 else { return }
            let next = strip[((i + delta) % strip.count + strip.count) % strip.count]
            let sameTile = tiles.contains { $0.tile.windows.contains(w) && $0.tile.windows.contains(next) }
            // Within a tile the pointer is already over the window; across tiles it should follow.
            focus(next, warp: !sameTile)
        case .moveWorkspaceToDisplay(let dir):
            guard model.moveFocusedWorkspace(toDisplay: dir) else { return }
            applyLayout()
            if let w = model.focused { focus(w) }
            else if config.mouseFollowsFocus, let d = model.focusedDisplay.flatMap(model.display) { mouse.warp(to: d.frame.center) }
        case .moveToDisplay(let dir):
            guard let w = model.focused, model.moveWindow(w, toDisplay: dir) else { return }
            applyLayout()
            focus(w)
        case .workspace(let n):
            let before = model.focusedWorkspace?.id
            let pointerDisplay = displays.display(containing: mouse.location)?.id
            let target = model.focusWorkspace(n)
            guard before != n || target != model.focused else { return }
            applyLayout()
            // Don't yank the pointer around on a workspace switch; only move it when the
            // workspace lives on a different display (otherwise focus-follows-mouse would
            // immediately pull focus back to the display the pointer is on).
            let crossesDisplay = model.focusedDisplay != pointerDisplay
            if let target {
                focus(target, warp: crossesDisplay)
            } else if crossesDisplay, config.mouseFollowsFocus, let d = model.focusedDisplay.flatMap(model.display) {
                mouse.warp(to: d.frame.center)
            } else {
                mouse.suppress()
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
        guard let w = model.focused else { return }
        moveWindow(w, dir, warp: true)
    }

    private func moveWindow(_ w: WindowID, _ dir: Direction, warp: Bool) {
        guard let ws = model.workspace(containing: w), !ws.floating.contains(w),
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
        focus(w, warp: warp)
    }

    // MARK: - Tab bar controls (close, drag, context menu)

    private func closeWindow(_ id: WindowID) {
        guard let ax = axWindows[id] else { return }
        log("close tab \(id)")
        _ = ax.close()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
            guard let self, let ax = self.axWindows[id] else { return }
            if !ax.isAlive || ax.frame == nil {
                self.windowDestroyed(id)
            }
        }
    }

    private func tabDragUpdated(_ w: WindowID, at p: CGPoint) {
        isDraggingTab = true
        guard let ws = model.workspace(containing: w),
              let srcStack = ws.tree.stack(containing: w)?.id else {
            tabBars.showDropPreview(nil)
            return
        }
        let visibleTiles = tiles.map(\.tile)
        switch TabLayout.dropTarget(at: p, draggedWindow: w, sourceStack: srcStack, tiles: visibleTiles, tabRects: tabBars.tabRects) {
        case .reorder(let idx):
            tabBars.showDropPreview(nil)
            var reordered = false
            model.update(ws.id) { reordered = $0.tree.reorder(w, to: idx) }
            if reordered { applyLayout() }
        case .joinStack(_, _, let preview), .splitTile(_, _, let preview):
            tabBars.showDropPreview(preview)
        case nil:
            if let d = displays.display(containing: p), tiles.allSatisfy({ $0.display != d.id }) {
                tabBars.showDropPreview(d.frame)
            } else {
                tabBars.showDropPreview(nil)
            }
        }
    }

    private func tabDragEnded(_ w: WindowID, at p: CGPoint) {
        isDraggingTab = false
        tabBars.showDropPreview(nil)
        guard let srcWS = model.workspace(containing: w),
              let srcStack = srcWS.tree.stack(containing: w)?.id else { return }
        let visibleTiles = tiles.map(\.tile)
        switch TabLayout.dropTarget(at: p, draggedWindow: w, sourceStack: srcStack, tiles: visibleTiles, tabRects: tabBars.tabRects) {
        case .reorder(let idx):
            model.update(srcWS.id) { _ = $0.tree.reorder(w, to: idx) }
            applyLayout()
            focus(w, warp: false)
        case .joinStack(let dstStack, let index, _):
            guard let dstDisplay = tiles.first(where: { $0.tile.stackID == dstStack })?.display,
                  let dstWS = model.visibleWorkspace(on: dstDisplay)?.id else { return }
            if dstWS != srcWS.id { _ = model.moveWindow(w, toWorkspace: dstWS) }
            model.update(dstWS) { _ = $0.tree.move(w, toStack: dstStack, at: index) }
            applyLayout()
            focus(w, warp: false)
        case .splitTile(let dstStack, let edge, _):
            guard let dstDisplay = tiles.first(where: { $0.tile.stackID == dstStack })?.display,
                  let dstWS = model.visibleWorkspace(on: dstDisplay)?.id else { return }
            if dstWS != srcWS.id { _ = model.moveWindow(w, toWorkspace: dstWS) }
            model.update(dstWS) { _ = $0.tree.move(w, splitting: dstStack, edge: edge) }
            applyLayout()
            focus(w, warp: false)
        case nil:
            if let d = displays.display(containing: p),
               tiles.allSatisfy({ $0.display != d.id }),
               let dstWS = model.visibleWorkspace(on: d.id)?.id,
               dstWS != srcWS.id {
                _ = model.moveWindow(w, toWorkspace: dstWS)
                applyLayout()
                focus(w, warp: false)
            }
        }
    }

    private func buildTabMenu(for w: WindowID) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(.action("Move Left") { [weak self] in self?.moveWindow(w, .left, warp: false) })
        menu.addItem(.action("Move Right") { [weak self] in self?.moveWindow(w, .right, warp: false) })
        menu.addItem(.action("Move Up") { [weak self] in self?.moveWindow(w, .up, warp: false) })
        menu.addItem(.action("Move Down") { [weak self] in self?.moveWindow(w, .down, warp: false) })
        if model.displays.count > 1 {
            menu.addItem(.action("Move to Other Display") { [weak self] in
                guard let self else { return }
                let moved = self.model.moveWindow(w, toDisplay: .right) || self.model.moveWindow(w, toDisplay: .left)
                    || self.model.moveWindow(w, toDisplay: .down) || self.model.moveWindow(w, toDisplay: .up)
                guard moved else { return }
                self.applyLayout()
                self.focus(w, warp: false)
            })
        }
        menu.addItem(.separator())

        let wsSub = NSMenu()
        let currentWS = model.workspace(containing: w)?.id
        for n in config.firstWorkspace..<(config.firstWorkspace + 10) {
            let count = model.workspace(n)?.allWindows.count ?? 0
            let label = count > 0 ? "Workspace \(n)  (\(count))" : "Workspace \(n)"
            let item = NSMenuItem.action(label) { [weak self] in
                guard let self else { return }
                let wasFocused = self.model.focused == w
                let replacement = self.model.moveWindow(w, toWorkspace: n)
                self.applyLayout()
                if wasFocused, let replacement { self.focus(replacement, warp: false) }
            }
            if n == currentWS {
                item.state = .on
                item.isEnabled = false
            }
            wsSub.addItem(item)
        }
        let wsItem = NSMenuItem(title: "Move to Workspace", action: nil, keyEquivalent: "")
        wsItem.submenu = wsSub
        menu.addItem(wsItem)

        menu.addItem(.action("Float Window") { [weak self] in
            guard let self else { return }
            self.model.toggleFloating(w)
            self.lastApplied[w] = nil
            self.applyLayout()
            self.focus(w, warp: false)
        })
        menu.addItem(.separator())
        menu.addItem(.action("Close") { [weak self] in self?.closeWindow(w) })
        return menu
    }

    // MARK: - Layout

    private func tabBarHeight(_ count: Int) -> CGFloat {
        config.tabBar.height(forWindowCount: count)
    }

    func applyLayout() {
        relayoutPending = false
        var desired: [WindowID: CGRect] = [:]
        var anchors: [WindowID: CGRect] = [:]
        var toPark: Set<WindowID> = []
        var newTiles: [(tile: Tile, display: DisplayID)] = []
        var fullscreenDisplays: Set<DisplayID> = []
        let caps = observedMax

        let activePid = model.focused?.pid
        for display in model.displays {
            for ws in model.workspaces.values where ws.displayID == display.id {
                let visible = model.isVisible(ws.id)
                guard visible else {
                    ws.allWindows.forEach { toPark.insert($0) }
                    continue
                }
                let ts = LayoutEngine.tiles(ws.tree, in: display.frame, tabBarHeight: tabBarHeight, maxSize: { caps[$0] })
                for t in ts {
                    desired[t.top] = t.content
                    for w in t.windows where w != t.top {
                        // Stack members stay in place; only z-order distinguishes the top.
                        // Exception: macOS keeps *all* windows of the active app above everything
                        // else, so an active-app window behind another app's top would cover it.
                        if w.pid == activePid && t.top.pid != activePid {
                            toPark.insert(w)
                        } else {
                            desired[w] = t.content
                        }
                    }
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
        // Tab bars first: constrained windows are anchored under their (content-sized) tabs.
        syncTabBars(excluding: fullscreenDisplays)
        for id in desired.keys { if let a = tabBars.anchor(for: id) { anchors[id] = a } }
        let previousAnchors = tabAnchors
        tabAnchors = anchors

        for (id, rect) in desired {
            guard let ax = axWindows[id] else { continue }
            // Constrained windows also need re-placing when their tab moved (tabs added/removed).
            let anchorMoved = effectiveFrames[id] != nil && anchors[id] != previousAnchors[id]
            if parked.contains(id) || lastApplied[id] != rect || anchorMoved {
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

        raiseStackTops()
        updateStatusBar()
        // A window just told us (via place) how big it can really get: lay out once more so its
        // tile shrinks to fit and the neighbours take the rest. One extra pass at most.
        if relayoutPending, observedMax != caps {
            log("size caps changed; re-laying out")
            applyLayout()
        }
        relayoutPending = false
    }

    private func updateStatusBar() {
        guard statusBar.isShown else { return }
        let entries = model.displays.map { d -> StatusBar.DisplayEntry in
            let visible = model.visibleWorkspace(on: d.id)?.id
            // Empty workspaces are noise in the menu; keep only populated ones (and the current one).
            let wss = model.workspaces.values
                .filter { $0.displayID == d.id && (!$0.isEmpty || $0.id == visible) }
                .sorted { $0.id < $1.id }
            return StatusBar.DisplayEntry(
                name: displays.names[d.id] ?? "Display",
                visibleWorkspace: model.visibleWorkspace(on: d.id)?.id ?? 0,
                isFocused: model.focusedDisplay == d.id,
                workspaces: wss.map { ($0.id, $0.allWindows.count) })
        }
        statusBar.update(entries)
    }

    /// Brings the top window of every visible multi-window stack to the front of its tile.
    /// (AX raise reorders among inactive apps' windows; the active app is always on top anyway.)
    private func raiseStackTops() {
        // Never touch windows of the active app: they are already above everything else, and
        // raising one of them would move keyboard focus away from the focused window.
        let activePid = model.focused?.pid
        for (tile, _) in tiles where tile.windows.count > 1 && tile.top != model.focused && tile.top.pid != activePid {
            axWindows[tile.top]?.orderFront()
        }
    }

    private func syncTabBars(excluding fullscreenDisplays: Set<DisplayID> = []) {
        let visibleTiles = tiles.filter { !fullscreenDisplays.contains($0.display) }.map(\.tile)
        tabBars.sync(tiles: visibleTiles, focused: model.focused) { [self] id in
            let app = watcher.app(for: id.pid)
            let full = titles[id] ?? ""
            let label = config.tabBar.stripAppSuffix ? TitleCleaner.clean(full, appName: app?.name) : (full.isEmpty ? (app?.name ?? "Untitled") : full)
            return TabItem(id: id, title: label, fullTitle: full.isEmpty ? (app?.name ?? "") : full, icon: app?.icon)
        }
    }

    /// Applies `rect`; if the app clamps the size (minimum-size constraints), centers the
    /// window inside the tile instead of leaving it in the corner. Returns the effective frame.
    @discardableResult
    private func place(_ ax: AXWindow, in rect: CGRect) -> CGRect {
        ax.setFrame(rect)
        guard let actual = ax.frame else { return rect }
        noteAcceptedSize(actual.size, requested: rect.size, for: ax.id)
        if abs(actual.width - rect.width) > 2 || abs(actual.height - rect.height) > 2 {
            let placed: CGRect
            if ax.id == model.focused {
                // Focused: go straight to where `bringConstrainedWindowToPointer` would put it
                // (centred on the pointer if it's in the tile, else the tile centre), so the
                // window doesn't hop from under its tab to the pointer in two steps.
                let p = mouse.location
                let target = rect.contains(p) ? p : rect.center
                placed = Self.centered(size: actual.size, on: target, within: rect)
            } else if let tab = tabAnchors[ax.id] {
                // In a tab group: sit directly below its tab (clamped to the tile), so moving the
                // pointer down from the tab lands on this window rather than the one behind it.
                let x = min(max(tab.midX - actual.width / 2, rect.minX), max(rect.minX, rect.maxX - actual.width))
                placed = CGRect(x: x, y: rect.minY, width: actual.width, height: actual.height)
            } else {
                placed = CGRect(x: rect.midX - actual.width / 2, y: rect.midY - actual.height / 2,
                                width: actual.width, height: actual.height)
            }
            ax.setPosition(placed.origin)
            effectiveFrames[ax.id] = placed
            return placed
        }
        effectiveFrames[ax.id] = nil
        return rect
    }

    /// Records the size an app actually accepted. An axis that came back smaller than requested
    /// is a cap; an axis the app filled is free. A previously capped axis that now fills is freed
    /// again, and a cap grows if the app accepts more than we had recorded. Coming back *larger*
    /// than requested is a minimum-size constraint and says nothing about the maximum.
    private func noteAcceptedSize(_ actual: CGSize, requested: CGSize, for id: WindowID) {
        let old = observedMax[id]
        func axis(_ got: CGFloat, _ asked: CGFloat, _ previous: CGFloat?) -> CGFloat {
            if got < asked - 2 { return got }                          // clamped: that's the cap
            if got > asked + 2 { return previous ?? .infinity }         // hit a minimum: keep what we knew
            if let p = previous, p.isFinite, abs(asked - p) <= 2 { return p }  // got exactly the cap we asked for
            return .infinity                                            // filled a larger request: free
        }
        let new = CGSize(width: axis(actual.width, requested.width, old?.width),
                         height: axis(actual.height, requested.height, old?.height))
        let value: CGSize? = (new.width.isFinite || new.height.isFinite) ? new : nil
        if value != old {
            observedMax[id] = value
            relayoutPending = true
            log("size cap \(id): \(value.map { "\(Int($0.width.isFinite ? $0.width : -1))×\(Int($0.height.isFinite ? $0.height : -1))" } ?? "none")")
        }
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

    // MARK: - Mouse resize

    /// Converts a finished drag-resize of a tiled window into split-weight changes.
    private func finishUserResize() {
        guard !userResizing.isEmpty else { return }
        let ids = userResizing
        userResizing.removeAll()
        var changed = false
        for id in ids {
            guard let ax = axWindows[id], let have = ax.frame, let want = desiredFrames[id],
                  let ws = model.workspace(containing: id), let display = model.display(ws.displayID) else { continue }
            // The user may have pulled the window past a size we thought was its limit: re-measure.
            observedMax[id] = nil
            let edges: [(Direction, CGFloat)] = [
                (.left, have.minX - want.minX), (.right, have.maxX - want.maxX),
                (.up, have.minY - want.minY), (.down, have.maxY - want.maxY),
            ]
            for (edge, delta) in edges where abs(delta) >= 2 {
                var ok = false
                let caps = observedMax
                model.update(ws.id) { ok = $0.tree.resizeEdge(id, edge: edge, by: delta, in: display.frame, maxSize: { caps[$0] }) }
                if ok { changed = true; log("mouse resize \(id) \(edge) by \(Int(delta))") }
            }
            lastApplied[id] = nil  // force re-apply even if the tile didn't change (snap back)
        }
        applyLayout()
        if !changed { scheduleVerify() }
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

@MainActor
private final class ClosureMenuTarget: NSObject {
    let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
    @objc func invoke() { handler() }
}

extension NSMenuItem {
    @MainActor
    static func action(_ title: String, _ handler: @escaping () -> Void) -> NSMenuItem {
        let target = ClosureMenuTarget(handler)
        let item = NSMenuItem(title: title, action: #selector(ClosureMenuTarget.invoke), keyEquivalent: "")
        item.target = target
        item.representedObject = target
        return item
    }
}
