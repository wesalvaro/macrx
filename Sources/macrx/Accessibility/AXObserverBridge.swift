import AppKit
import ApplicationServices

/// Swift-friendly wrapper around `AXObserver`. Callbacks are delivered on the main run loop.
@MainActor
final class AXObserverBridge {
    typealias Handler = (_ notification: String, _ element: AXUIElement) -> Void

    let pid: pid_t
    private var observer: AXObserver?
    private let handler: Handler
    private var registrations: [(AXUIElement, String)] = []

    init?(pid: pid_t, handler: @escaping Handler) {
        self.pid = pid
        self.handler = handler
        var obs: AXObserver?
        let callback: AXObserverCallback = { _, element, notification, refcon in
            guard let refcon else { return }
            let bridge = Unmanaged<AXObserverBridge>.fromOpaque(refcon).takeUnretainedValue()
            let name = notification as String
            MainActor.assumeIsolated { bridge.handler(name, element) }
        }
        guard AXObserverCreate(pid, callback, &obs) == .success, let obs else { return nil }
        observer = obs
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
    }

    @discardableResult
    func add(_ notification: String, to element: AXUIElement) -> Bool {
        guard let observer else { return false }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let err = AXObserverAddNotification(observer, element, notification as CFString, refcon)
        if err == .success || err == .notificationAlreadyRegistered {
            registrations.append((element, notification))
            return true
        }
        return false
    }

    func remove(_ notification: String, from element: AXUIElement) {
        guard let observer else { return }
        AXObserverRemoveNotification(observer, element, notification as CFString)
        registrations.removeAll { $0.0 == element && $0.1 == notification }
    }

    func removeAll(for element: AXUIElement) {
        for (e, n) in registrations where e == element {
            remove(n, from: e)
        }
    }

    func invalidate() {
        guard let observer else { return }
        for (e, n) in registrations { AXObserverRemoveNotification(observer, e, n as CFString) }
        registrations.removeAll()
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        self.observer = nil
    }

    deinit {
        // `invalidate()` is expected to have been called; observers die with their app anyway.
    }
}
