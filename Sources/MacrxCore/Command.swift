import Foundation
import CoreGraphics

/// Everything macrx can be asked to do.
public enum Command: Equatable, Sendable {
    case focus(Direction)
    case move(Direction)
    case resize(Direction)
    case stack(Int)                    // cycle within stack by delta
    case moveToDisplay(Direction)
    case workspace(Int)
    case moveToWorkspace(Int)
    case fullscreen
    case float
    case toggleOrientation
    case reload
    case quit

    /// Parses config strings like `"focus left"`, `"workspace 3"`, `"stack next"`.
    public init?(string: String) {
        let parts = string.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard let verb = parts.first else { return nil }
        let arg = parts.count > 1 ? parts[1] : nil
        func dir() -> Direction? { arg.flatMap(Direction.init(rawValue:)) }
        func int() -> Int? { arg.flatMap(Int.init) }

        switch (verb, parts.count) {
        case ("focus", 2):            guard let d = dir() else { return nil }; self = .focus(d)
        case ("move", 2):             guard let d = dir() else { return nil }; self = .move(d)
        case ("resize", 2):           guard let d = dir() else { return nil }; self = .resize(d)
        case ("move-to-display", 2):  guard let d = dir() else { return nil }; self = .moveToDisplay(d)
        case ("workspace", 2):        guard let n = int() else { return nil }; self = .workspace(n)
        case ("move-to-workspace", 2):guard let n = int() else { return nil }; self = .moveToWorkspace(n)
        case ("stack", 2):
            switch arg {
            case "next": self = .stack(1)
            case "prev", "previous": self = .stack(-1)
            default: return nil
            }
        case ("fullscreen", 1):        self = .fullscreen
        case ("float", 1):             self = .float
        case ("toggle-orientation", 1): self = .toggleOrientation
        case ("reload", 1):            self = .reload
        case ("quit", 1):              self = .quit
        default: return nil
        }
    }
}
