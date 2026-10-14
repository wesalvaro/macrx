import Foundation
import CoreGraphics

public enum Modifier: String, Hashable, Sendable, CaseIterable {
    case alt, shift, ctrl, cmd

    public init?(name: String) {
        switch name.lowercased() {
        case "alt", "opt", "option": self = .alt
        case "shift": self = .shift
        case "ctrl", "control": self = .ctrl
        case "cmd", "command": self = .cmd
        default: return nil
        }
    }
}

/// A key combination like `alt-shift-h`, expressed with a macOS virtual key code.
public struct KeyCombo: Hashable, Sendable, CustomStringConvertible {
    public let modifiers: Set<Modifier>
    public let keyCode: UInt16

    public init(modifiers: Set<Modifier>, keyCode: UInt16) {
        self.modifiers = modifiers
        self.keyCode = keyCode
    }

    /// Parses `"alt-shift-h"`. The last component is the key, all others modifiers.
    public init?(string: String) {
        let parts = string.split(separator: "-").map(String.init)
        guard let keyName = parts.last, let code = KeyCombo.keyCodes[keyName.lowercased()] else { return nil }
        var mods: Set<Modifier> = []
        for p in parts.dropLast() {
            guard let m = Modifier(name: p) else { return nil }
            mods.insert(m)
        }
        self.init(modifiers: mods, keyCode: code)
    }

    public var description: String {
        let name = KeyCombo.keyCodes.first { $0.value == keyCode }?.key ?? "key\(keyCode)"
        return (Modifier.allCases.filter(modifiers.contains).map(\.rawValue) + [name]).joined(separator: "-")
    }

    /// Key name → macOS virtual key code (ANSI layout).
    public static let keyCodes: [String: UInt16] = [
        "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04, "g": 0x05, "z": 0x06, "x": 0x07,
        "c": 0x08, "v": 0x09, "b": 0x0B, "q": 0x0C, "w": 0x0D, "e": 0x0E, "r": 0x0F, "y": 0x10,
        "t": 0x11, "1": 0x12, "2": 0x13, "3": 0x14, "4": 0x15, "6": 0x16, "5": 0x17, "equal": 0x18,
        "9": 0x19, "7": 0x1A, "minus": 0x1B, "8": 0x1C, "0": 0x1D, "rightsquarebracket": 0x1E,
        "o": 0x1F, "u": 0x20, "leftsquarebracket": 0x21, "i": 0x22, "p": 0x23, "enter": 0x24,
        "l": 0x25, "j": 0x26, "quote": 0x27, "k": 0x28, "semicolon": 0x29, "backslash": 0x2A,
        "comma": 0x2B, "slash": 0x2C, "n": 0x2D, "m": 0x2E, "period": 0x2F, "tab": 0x30,
        "space": 0x31, "backtick": 0x32, "backspace": 0x33, "esc": 0x35,
        "f1": 0x7A, "f2": 0x78, "f3": 0x63, "f4": 0x76, "f5": 0x60, "f6": 0x61, "f7": 0x62,
        "f8": 0x64, "f9": 0x65, "f10": 0x6D, "f11": 0x67, "f12": 0x6F,
        "left": 0x7B, "right": 0x7C, "down": 0x7D, "up": 0x7E,
        "home": 0x73, "end": 0x77, "pageup": 0x74, "pagedown": 0x79, "delete": 0x75,
    ]
}
