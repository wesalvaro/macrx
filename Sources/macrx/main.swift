import AppKit
import Darwin

@_silgen_name("responsibility_get_pid_responsible_for_pid")
private func responsibility_get_pid_responsible_for_pid(_ pid: pid_t) -> pid_t

@_silgen_name("responsibility_spawnattrs_setdisclaim")
private func responsibility_spawnattrs_setdisclaim(_ attr: UnsafeMutablePointer<posix_spawnattr_t?>, _ disclaim: Int32) -> Int32

/// When launched from a terminal (`just dev` / `just run`), macOS attributes TCC (Accessibility)
/// checks to the terminal app (e.g. Ghostty) as the "responsible process". Disclaim that
/// inheritance via `POSIX_SPAWN_SETEXEC` so TCC checks `macrx`'s own signature instead.
private func disclaimParentResponsibilityIfNeeded() {
    let me = getpid()
    let responsible = responsibility_get_pid_responsible_for_pid(me)
    guard responsible > 0, responsible != me else { return }
    var attr: posix_spawnattr_t?
    guard posix_spawnattr_init(&attr) == 0 else { return }
    defer { posix_spawnattr_destroy(&attr) }
    guard responsibility_spawnattrs_setdisclaim(&attr, 1) == 0,
          posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETEXEC)) == 0 else { return }

    let args = CommandLine.arguments
    var cArgs = args.map { strdup($0) } + [nil]
    defer { cArgs.forEach { if let p = $0 { free(p) } } }
    let path = args[0]
    var pid: pid_t = 0
    _ = posix_spawnp(&pid, path, nil, &attr, &cArgs, environ)
}

disclaimParentResponsibilityIfNeeded()

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
