import AppKit
import ApplicationServices
import MacrxCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let displays = DisplayManager()
    private let watcher = WindowWatcher()
    private let mouse = MouseController()
    private let tabBars = TabBarController()
    private let hotkeys = HotkeyTap()
    private var manager: WindowManager?
    private var permissionTimer: Timer?

    static let configURL: URL = {
        let base = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")
        return base.appendingPathComponent("macrx/config.toml")
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installSignalHandlers()

        // kAXTrustedCheckOptionPrompt is a global `var` the compiler can't prove safe; it's a constant string.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        if AXIsProcessTrustedWithOptions(options) {
            begin()
        } else {
            log("Waiting for Accessibility permission (System Settings → Privacy & Security → Accessibility)…")
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] t in
                guard AXIsProcessTrusted() else { return }
                t.invalidate()
                MainActor.assumeIsolated { self?.begin() }
            }
        }
    }

    private func begin() {
        let config = loadConfig()
        let manager = WindowManager(config: config, displays: displays, watcher: watcher, mouse: mouse, tabBars: tabBars)
        manager.onQuit = { NSApp.terminate(nil) }
        manager.onReload = { [weak self] in self?.reload() }
        self.manager = manager

        hotkeys.bindings = config.bindings
        hotkeys.onCommand = { [weak manager] cmd in manager?.perform(cmd) }
        if !hotkeys.start() {
            log("error: could not create event tap (is Accessibility permission granted?)")
        }
        manager.start()
        log("running — AX trusted, \(displays.displays.count) display(s), \(config.bindings.count) bindings")
    }

    private func reload() {
        let config = loadConfig()
        hotkeys.bindings = config.bindings
        manager?.applyConfig(config)
        log("config reloaded")
    }

    private func loadConfig() -> Config {
        let url = Self.configURL
        if !FileManager.default.fileExists(atPath: url.path) {
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Config.defaultTOML.write(to: url, atomically: true, encoding: .utf8)
                log("wrote default config to \(url.path)")
            } catch {
                log("could not write default config: \(error)")
            }
            return .default
        }
        do {
            return try Config.load(from: url)
        } catch {
            log("config error: \(error) — using defaults")
            return .default
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        shutdown()
    }

    private func shutdown() {
        hotkeys.stop()
        mouse.stopFollowing()
        watcher.stop()
        tabBars.hideAll()
        manager?.restoreParkedWindows()
    }

    private func installSignalHandlers() {
        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { NSApp.terminate(nil) }
            src.resume()
            signalSources.append(src)
        }
    }
    private var signalSources: [DispatchSourceSignal] = []

    private func log(_ s: String) {
        FileHandle.standardError.write(("[macrx] " + s + "\n").data(using: .utf8)!)
    }
}
