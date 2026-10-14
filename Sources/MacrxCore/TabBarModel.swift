import Foundation
import CoreGraphics

/// Turns verbose window titles into tab labels.
public enum TitleCleaner {
    /// Removes trailing app-name suffixes such as `" - Google Chrome"`, `" — Safari"`,
    /// `" | Slack"` and Chrome's profile tail `" - Wes (me@example.com)"`.
    /// Falls back to `appName` when nothing meaningful is left.
    public static func clean(_ title: String, appName: String?) -> String {
        var t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let app = appName?.trimmingCharacters(in: .whitespaces), !app.isEmpty {
            let esc = NSRegularExpression.escapedPattern(for: app)
            // "<title> - <App> - <Profile> (<email>)"  (Chrome)
            // "<title> - <App>" / "<title> — <App>" / "<title> | <App>"
            let patterns = [
                #"(?:^|\s+)[-–—|]\s+"# + esc + #"\s+[-–—]\s+[^-–—|]*\([^)]*\)\s*$"#,
                #"(?:^|\s+)[-–—|]\s+"# + esc + #"\s*$"#,
            ]
            for p in patterns {
                if let re = try? NSRegularExpression(pattern: p, options: [.caseInsensitive]) {
                    let range = NSRange(t.startIndex..., in: t)
                    t = re.stringByReplacingMatches(in: t, options: [], range: range, withTemplate: "")
                }
            }
            t = t.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { return app }
        }
        return t.isEmpty ? "Untitled" : t
    }
}

/// Distributes tab widths across a bar.
public enum TabLayout {
    /// - Parameters:
    ///   - natural: the width each tab would like (icon + text + padding).
    ///   - available: the bar width.
    ///   - minWidth / maxWidth: per-tab clamps.
    /// Behaviour: clamp to `[min, max]`; if there is spare room, grow tabs evenly up to `max`;
    /// if there isn't enough room, shrink proportionally down to `min`; if even that doesn't
    /// fit, split the bar equally.
    public static func widths(natural: [CGFloat], available: CGFloat, minWidth: CGFloat, maxWidth: CGFloat) -> [CGFloat] {
        let n = natural.count
        guard n > 0, available > 0 else { return [] }
        let minW = min(minWidth, available / CGFloat(n))
        var w = natural.map { min(max($0, minW), maxWidth) }
        var total = w.reduce(0, +)
        if total < available {
            // Grow evenly, respecting maxWidth, until the bar is full or everything is at max.
            var growable = w.indices.filter { w[$0] < maxWidth }
            var spare = available - total
            while spare > 0.5, !growable.isEmpty {
                let share = spare / CGFloat(growable.count)
                var used: CGFloat = 0
                for i in growable {
                    let add = min(share, maxWidth - w[i])
                    w[i] += add
                    used += add
                }
                spare -= used
                growable = growable.filter { w[$0] < maxWidth - 0.5 }
                if used < 0.5 { break }
            }
        } else if total > available {
            let scale = available / total
            w = w.map { max(minW, $0 * scale) }
            total = w.reduce(0, +)
            if total > available + 0.5 {
                w = Array(repeating: available / CGFloat(n), count: n)
            }
        }
        return w.map { $0.rounded() }
    }

    /// Converts widths into x-offsets/rects laid out left to right from `origin`.
    public static func rects(widths: [CGFloat], in bar: CGRect) -> [CGRect] {
        var x = bar.minX
        return widths.map { w in
            defer { x += w }
            return CGRect(x: x, y: bar.minY, width: w, height: bar.height)
        }
    }

    /// Equal split, used for `tab-width = "equal"`.
    public static func equalWidths(count: Int, available: CGFloat) -> [CGFloat] {
        guard count > 0 else { return [] }
        return Array(repeating: available / CGFloat(count), count: count)
    }
}
