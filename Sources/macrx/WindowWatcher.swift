import AppKit
import ApplicationServices
import MacrxCore

enum WindowEvent {
    case created(AXWindow, app: AXApp)
    case destroyed(WindowID)
    /// The system reports this window as focused (user click, app activation, ⌘-Tab…).
    case focused(WindowID)
    case titleChanged(WindowID)
    /// The window was moved or resized by something other than macrx.
    case frameChanged(WindowID)
}

/// Tracks running applications and their windows via NSWorkspace + AXObserver,
/// emitting `WindowEvent`s. Runs a periodic reconciliation to catch missed notifications.
@MainActor
final class WindowWatcher {
    var onEvent: ((WindowEvent) -> Void)?

    private(set) var apps: [pid_t: AXApp] = [:]
    private var observers: [pid_t: AXObserverBridge] = [:]
    private(set) var windows: [WindowID: AXWindow] = [:]
    private var elementToID: [AXUIElement: WindowID] = [:]
    private var tokens: [NSObjectProtocol] = []
    private var reconcileTimer: Timer?

    /// Tooltips, hover cards, popups etc. are `AXWindow`s too, but must never be managed.
    private static let managedSubroles: Set<String> = [kAXStandardWindowSubrole, kAXDialogSubrole]

    private static let windowNotifications = [
        kAXUIElementDestroyedNotification,
        kAXTitleChangedNotification,
        kAXWindowMiniaturizedNotification,
        kAXWindowDeminiaturizedNotification,
        kAXWindowMovedNotification,
        kAXWindowResizedNotification,
    ]

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        tokens.append(center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated { self?.track(app, attempt: 0) }
        })
        tokens.append(center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated { self?.untrack(app.processIdentifier) }
        })
        tokens.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated { self?.appActivated(app.processIdentifier) }
        })

        for app in NSWorkspace.shared.runningApplications {
            track(app, attempt: 0)
        }

        reconcileTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconcile() }
        }
    }

    func stop() {
        tokens.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        tokens.removeAll()
        reconcileTimer?.invalidate()
        observers.values.forEach { $0.invalidate() }
        observers.removeAll()
    }

    func app(for pid: pid_t) -> AXApp? { apps[pid] }

    // MARK: Apps

    private func track(_ running: NSRunningApplication, attempt: Int) {
        guard running.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let app = AXApp(running), apps[app.pid] == nil else { return }

        guard let observer = AXObserverBridge(pid: app.pid, handler: { [weak self] name, element in
            self?.handle(name, element: element, pid: app.pid)
        }) else {
            retryTrack(running, attempt: attempt)
            return
        }
        // Newly launched apps may not have their AX tree ready yet.
        let ok = observer.add(kAXWindowCreatedNotification, to: app.element)
        if !ok {
            observer.invalidate()
            retryTrack(running, attempt: attempt)
            return
        }
        observer.add(kAXFocusedWindowChangedNotification, to: app.element)
        apps[app.pid] = app
        observers[app.pid] = observer

        for w in app.windows { register(w, app: app) }
        if app.windows.isEmpty && attempt < 3 {
            // Some apps create their first window a moment after launch and miss the notification.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self, let a = self.apps[app.pid] else { return }
                for w in a.windows where self.windows[w.id] == nil { self.register(w, app: a) }
            }
        }
    }

    private func retryTrack(_ running: NSRunningApplication, attempt: Int) {
        guard attempt < 5 else { return }
        let delay = [0.3, 1.0, 2.0, 4.0, 8.0][attempt]
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.track(running, attempt: attempt + 1)
        }
    }

    private func untrack(_ pid: pid_t) {
        observers[pid]?.invalidate()
        observers[pid] = nil
        apps[pid] = nil
        for (id, w) in windows where id.pid == pid {
            windows[id] = nil
            elementToID[w.element] = nil
            onEvent?(.destroyed(id))
        }
    }

    private func appActivated(_ pid: pid_t) {
        guard let app = apps[pid], let fw = app.focusedWindow, windows[fw.id] != nil else { return }
        onEvent?(.focused(fw.id))
    }

    // MARK: Windows

    private func register(_ w: AXWindow, app: AXApp) {
        guard windows[w.id] == nil, w.role == kAXWindowRole, !w.isMinimized,
              Self.managedSubroles.contains(w.subrole) else { return }
        windows[w.id] = w
        elementToID[w.element] = w.id
        if let obs = observers[app.pid] {
            for n in Self.windowNotifications { obs.add(n, to: w.element) }
        }
        onEvent?(.created(w, app: app))
    }

    private func unregister(_ id: WindowID) {
        guard let w = windows[id] else { return }
        windows[id] = nil
        elementToID[w.element] = nil
        observers[id.pid]?.removeAll(for: w.element)
        onEvent?(.destroyed(id))
    }

    private func handle(_ name: String, element: AXUIElement, pid: pid_t) {
        switch name {
        case kAXWindowCreatedNotification:
            guard let app = apps[pid], let w = AXWindow(element: element) else { return }
            register(w, app: app)
        case kAXUIElementDestroyedNotification, kAXWindowMiniaturizedNotification:
            if let id = elementToID[element] { unregister(id) }
        case kAXWindowDeminiaturizedNotification:
            guard let app = apps[pid], let w = AXWindow(element: element) else { return }
            register(w, app: app)
        case kAXFocusedWindowChangedNotification:
            if let id = elementToID[element] ?? AXWindow(element: element).map(\.id), windows[id] != nil {
                onEvent?(.focused(id))
            } else if let app = apps[pid], let w = AXWindow(element: element) {
                // Focused a window we hadn't seen yet (e.g. created before AX was ready).
                register(w, app: app)
                onEvent?(.focused(w.id))
            }
        case kAXTitleChangedNotification:
            if let id = elementToID[element] { onEvent?(.titleChanged(id)) }
        case kAXWindowMovedNotification, kAXWindowResizedNotification:
            if let id = elementToID[element] { onEvent?(.frameChanged(id)) }
        default:
            break
        }
    }

    /// Diffs the AX window lists against what we know, to recover from missed notifications.
    private func reconcile() {
        for (pid, app) in apps {
            if app.runningApp.isTerminated { untrack(pid); continue }
            let current = app.windows
            let currentIDs = Set(current.map(\.id))
            for w in current where windows[w.id] == nil { register(w, app: app) }
            for (id, w) in windows where id.pid == pid && !currentIDs.contains(id) {
                if !w.isAlive || w.isMinimized { unregister(id) }
            }
        }
        for running in NSWorkspace.shared.runningApplications where apps[running.processIdentifier] == nil {
            track(running, attempt: 5)  // single attempt; the timer will retry
        }
    }
}
