import AppKit
import ApplicationServices
import IOKit
import IOKit.pwr_mgt
import MacrxCore

enum WindowEvent {
    case created(AXWindow, app: AXApp)
    case destroyed(WindowID)
    /// The system reports this window as focused (user click, app activation, ⌘-Tab…).
    case focused(WindowID)
    case titleChanged(WindowID)
    /// The window was moved or resized by something other than macrx.
    case frameChanged(WindowID)
    /// Same window, new AX element (the app's AX server handed out fresh handles, e.g. after sleep).
    case elementChanged(AXWindow)
    /// The app quit; sent after `.destroyed` for each of its windows.
    case appTerminated(pid_t)
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
    /// Reconciliation is paused until this date around sleep/wake, when apps answer AX slowly
    /// (or not at all) and a naive diff would tear every window out of its workspace.
    private var reconcileSuspendedUntil = Date.distantPast
    private var power: PowerObserver?

    private func suspendReconcile(_ why: String) {
        if reconcileSuspendedUntil != .distantFuture { log("reconcile paused: \(why)") }
        reconcileSuspendedUntil = .distantFuture
    }

    private func resumeReconcile(_ why: String) {
        log("reconcile resumes in 5 s: \(why)")
        reconcileSuspendedUntil = Date().addingTimeInterval(5)
    }

    /// Tooltips, hover cards, popups etc. are `AXWindow`s too, but must never be managed.
    /// Some (Chrome's tab preview card) even report a standard subrole, so `register` also
    /// requires the window to be at the normal window level.
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
        // Sleep / screen lock: stop reconciling, and give apps a few seconds after wake to respond.
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            tokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.suspendReconcile("\(name.rawValue)") }
            })
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            tokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.resumeReconcile("\(name.rawValue)") }
            })
        }
        // IOKit's sleep message arrives before NSWorkspace's, while apps are still answering.
        power = PowerObserver(
            willSleep: { [weak self] in MainActor.assumeIsolated { self?.suspendReconcile("IOKit will sleep") } },
            didWake: { [weak self] in MainActor.assumeIsolated { self?.resumeReconcile("IOKit did wake") } })

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
        guard apps[pid] != nil else { return }
        observers[pid]?.invalidate()
        observers[pid] = nil
        apps[pid] = nil
        for (id, w) in windows where id.pid == pid {
            windows[id] = nil
            elementToID[w.element] = nil
            onEvent?(.destroyed(id))
        }
        onEvent?(.appTerminated(pid))
    }

    private func appActivated(_ pid: pid_t) {
        guard let app = apps[pid], let fw = app.focusedWindow, windows[fw.id] != nil else { return }
        onEvent?(.focused(fw.id))
    }

    // MARK: Windows

    private func register(_ w: AXWindow, app: AXApp) {
        guard windows[w.id] == nil, w.role == kAXWindowRole, !w.isMinimized,
              Self.managedSubroles.contains(w.subrole), w.isNormalLevel else { return }
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
    /// A window's identity is its CG window number; AX elements are just handles that an app's
    /// AX server may replace (e.g. after sleep), so a stale element is swapped, never "destroyed".
    private func reconcile() {
        guard Date() >= reconcileSuspendedUntil else { return }
        for (pid, app) in apps {
            if app.runningApp.isTerminated { untrack(pid); continue }
            // An app that doesn't answer (just woke, hung, busy) is skipped this round: treating a
            // failed query as "no windows" would tear every window out of its workspace.
            guard let current = app.windowsIfResponsive else { continue }
            var currentIDs: Set<WindowID> = []
            for w in current {
                currentIDs.insert(w.id)
                if let known = windows[w.id] {
                    if known.element != w.element { refreshElement(of: w.id, to: w, app: app) }
                } else {
                    register(w, app: app)
                }
            }
            for (id, w) in windows where id.pid == pid && !currentIDs.contains(id) {
                // Gone from the AX list: drop it only if the window server agrees it no longer
                // exists (or it was minimized). Anything else is a transient and is retried.
                if w.isMinimized || !Self.windowServerKnows(id.cgID) { unregister(id) }
            }
        }
        for running in NSWorkspace.shared.runningApplications where apps[running.processIdentifier] == nil {
            track(running, attempt: 5)  // single attempt; the timer will retry
        }
    }

    /// Same window, new AX element: re-point our bookkeeping and observers, no events.
    private func refreshElement(of id: WindowID, to fresh: AXWindow, app: AXApp) {
        guard let old = windows[id] else { return }
        observers[id.pid]?.removeAll(for: old.element)
        elementToID[old.element] = nil
        windows[id] = fresh
        elementToID[fresh.element] = id
        if let obs = observers[app.pid] {
            for n in Self.windowNotifications { obs.add(n, to: fresh.element) }
        }
        onEvent?(.elementChanged(fresh))
        log("refreshed AX element for \(id)")
    }

    private static func windowServerKnows(_ cgID: CGWindowID) -> Bool {
        guard let list = CGWindowListCopyWindowInfo(.optionIncludingWindow, cgID) as? [[String: Any]] else { return false }
        return !list.isEmpty
    }
}

/// `IORegisterForSystemPower` wrapper: fires before the system sleeps and after it wakes.
private final class PowerObserver {
    private var port: io_connect_t = 0
    private var notifier: io_object_t = 0
    private var source: CFRunLoopSource?
    private let willSleep: () -> Void
    private let didWake: () -> Void

    init?(willSleep: @escaping () -> Void, didWake: @escaping () -> Void) {
        self.willSleep = willSleep
        self.didWake = didWake
        var portRef: IONotificationPortRef?
        let me = Unmanaged.passUnretained(self).toOpaque()
        port = IORegisterForSystemPower(me, &portRef, { refcon, _, messageType, messageArgument in
            guard let refcon else { return }
            let obs = Unmanaged<PowerObserver>.fromOpaque(refcon).takeUnretainedValue()
            obs.handle(messageType, messageArgument)
        }, &notifier)
        guard port != 0, let portRef else { return nil }
        source = IONotificationPortGetRunLoopSource(portRef)?.takeUnretainedValue()
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }

    private func handle(_ type: natural_t, _ arg: UnsafeMutableRawPointer?) {
        // IOMessage.h macros aren't importable; these are iokit_common_msg(0x270/0x280/0x300).
        let canSleep: natural_t = 0xE000_0270, willSleep: natural_t = 0xE000_0280, poweredOn: natural_t = 0xE000_0300
        switch type {
        case canSleep, willSleep:
            self.willSleep()
            IOAllowPowerChange(port, Int(bitPattern: arg))
        case poweredOn:
            didWake()
        default:
            break
        }
    }

    deinit {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if notifier != 0 { IODeregisterForSystemPower(&notifier) }
        if port != 0 { IOServiceClose(port) }
    }
}
