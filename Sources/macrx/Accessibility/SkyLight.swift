import AppKit
import ApplicationServices

/// Window-server level focus via private SkyLight calls (the technique used by yabai and
/// alt-tab-macos). Needed because some apps (GLFW-based ones like kitty, among others)
/// ignore the Accessibility attributes that are supposed to switch their key window.
///
/// Symbols are resolved at runtime; if they're missing, `focus` returns `false` and
/// callers fall back to the Accessibility path.
enum SkyLight {
    private typealias SetFrontProcessFn = @convention(c) (UnsafePointer<ProcessSerialNumber>, UInt32, UInt32) -> CGError
    private typealias PostEventRecordFn = @convention(c) (UnsafePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>) -> CGError
    private typealias GetProcessForPIDFn = @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus

    nonisolated(unsafe) private static let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    private static let setFrontProcess: SetFrontProcessFn? = sym("_SLPSSetFrontProcessWithOptions")
    private static let postEventRecord: PostEventRecordFn? = sym("SLPSPostEventRecordTo")
    /// Deprecated Carbon API, unavailable to Swift directly but still exported by HIServices.
    private static let getProcessForPID: GetProcessForPIDFn? = sym("GetProcessForPID", global: true)

    private static func sym<T>(_ name: String, global: Bool = false) -> T? {
        let h = global ? UnsafeMutableRawPointer(bitPattern: -2) /* RTLD_DEFAULT */ : handle
        guard let h, let p = dlsym(h, name) else { return nil }
        return unsafeBitCast(p, to: T.self)
    }

    static var isAvailable: Bool { setFrontProcess != nil && postEventRecord != nil && getProcessForPID != nil }

    /// Makes `windowID` of `pid` the frontmost, key window.
    @discardableResult
    static func focus(pid: pid_t, windowID: CGWindowID) -> Bool {
        guard let setFrontProcess, let postEventRecord, let getProcessForPID else { return false }
        var psn = ProcessSerialNumber()
        guard getProcessForPID(pid, &psn) == noErr else { return false }
        let kCPSUserGenerated: UInt32 = 0x200
        guard setFrontProcess(&psn, windowID, kCPSUserGenerated) == .success else { return false }
        // Two synthetic window-server events (activate + make key) addressed to the window.
        for kind: UInt8 in [0x01, 0x02] {
            var bytes = [UInt8](repeating: 0, count: 0xF8)
            bytes[0x04] = 0xF8
            bytes[0x08] = kind
            bytes[0x3A] = 0x10
            var wid = windowID
            withUnsafeBytes(of: &wid) { src in
                for i in 0..<4 { bytes[0x3C + i] = src[i] }
            }
            for i in 0x20..<0x30 { bytes[i] = 0xFF }
            let err = bytes.withUnsafeMutableBufferPointer { postEventRecord(&psn, $0.baseAddress!) }
            if err != .success { FileHandle.standardError.write("[macrx] SLPSPostEventRecordTo(\(kind)) → \(err.rawValue)\n".data(using: .utf8)!) }
        }
        return true
    }
}
