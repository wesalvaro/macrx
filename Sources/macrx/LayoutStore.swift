import Foundation
import MacrxCore

/// Persists the layout to `$XDG_STATE_HOME/macrx/layout.json` so a restart can put every
/// window back where it was. Saves are debounced; `saveNow` is for shutdown.
@MainActor
final class LayoutStore {
    static let url: URL = {
        let base = ProcessInfo.processInfo.environment["XDG_STATE_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/state")
        return base.appendingPathComponent("macrx/layout.json")
    }()

    /// Seconds since the epoch at which the machine booted (`kern.boottime`).
    static let bootTime: Int = {
        var tv = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &tv, &size, nil, 0) == 0 else { return 0 }
        return Int(tv.tv_sec)
    }()

    private var pending: LayoutSnapshot?
    private var timer: Timer?
    private var lastWritten: LayoutSnapshot?

    /// The saved layout, if it is readable, the right version and from this boot.
    func load() -> LayoutSnapshot? {
        guard let data = try? Data(contentsOf: Self.url) else { return nil }
        guard let s = try? JSONDecoder().decode(LayoutSnapshot.self, from: data) else {
            log("ignoring unreadable layout file \(Self.url.path)")
            return nil
        }
        guard s.version == LayoutSnapshot.currentVersion else {
            log("ignoring layout file of version \(s.version)")
            return nil
        }
        guard s.bootTime == Self.bootTime else {
            log("ignoring layout saved before the last reboot")
            return nil
        }
        return s
    }

    func save(_ s: LayoutSnapshot) {
        pending = s
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.flush() }
        }
    }

    func saveNow(_ s: LayoutSnapshot) {
        pending = s
        flush()
    }

    private func flush() {
        timer?.invalidate()
        timer = nil
        guard var s = pending else { return }
        pending = nil
        // `savedAt` alone must not force a write.
        if var prev = lastWritten { prev.savedAt = s.savedAt; if prev == s { return } }
        do {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            s.savedAt = Int(Date().timeIntervalSince1970)
            let data = try enc.encode(s)
            try FileManager.default.createDirectory(at: Self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: Self.url, options: .atomic)
            lastWritten = s
        } catch {
            log("could not save layout: \(error)")
        }
    }

}
