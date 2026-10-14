import AppKit
import CoreGraphics
import MacrxCore

/// Global hotkeys via a CGEvent tap. Matched key presses are swallowed so the
/// focused application never sees them.
@MainActor
final class HotkeyTap {
    var bindings: [KeyCombo: Command] = [:]
    var onCommand: ((Command) -> Void)?

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    func start() -> Bool {
        guard tap == nil else { return true }
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.tapDisabledByTimeout.rawValue)
            | (1 << CGEventType.tapDisabledByUserInput.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let tap = Unmanaged<HotkeyTap>.fromOpaque(refcon).takeUnretainedValue()
            // The tap's run loop source lives on the main run loop, so this is on the main thread.
            nonisolated(unsafe) let ev = event
            let swallow = MainActor.assumeIsolated { tap.handle(type: type, event: ev) }
            return swallow ? nil : Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: CGEventMask(mask), callback: callback, userInfo: refcon
        ) else { return false }
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
    }

    /// Returns `true` if the event should be swallowed.
    private func handle(type: CGEventType, event: CGEvent) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        case .keyDown:
            let combo = KeyCombo(
                modifiers: Self.modifiers(from: event.flags),
                keyCode: UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            )
            guard let cmd = bindings[combo] else { return false }
            // Dispatch asynchronously so a slow command never stalls the event tap.
            DispatchQueue.main.async { [weak self] in self?.onCommand?(cmd) }
            return true
        default:
            return false
        }
    }

    static func modifiers(from flags: CGEventFlags) -> Set<Modifier> {
        var m: Set<Modifier> = []
        if flags.contains(.maskAlternate) { m.insert(.alt) }
        if flags.contains(.maskShift) { m.insert(.shift) }
        if flags.contains(.maskControl) { m.insert(.ctrl) }
        if flags.contains(.maskCommand) { m.insert(.cmd) }
        return m
    }
}
