import Foundation

/// Text-level edits to the user's `config.toml`, so that rules added from the UI land in the
/// file without disturbing anything the user wrote (comments, ordering, formatting).
///
/// Rules written here carry a marker comment so they can be found and removed again.
public enum ConfigEditor {
    static let marker = "# added by macrx"

    /// The `[[rule]]` block that pins `appID`'s new windows to `workspace`.
    public static func workspaceRuleBlock(appID: String, workspace: Int) -> String {
        """
        [[rule]]  \(marker)
        app-id = \(tomlString(appID))
        workspace = \(workspace)

        """
    }

    /// `toml` with any macrx-added workspace rule for `appID` replaced by one for `workspace`.
    public static func settingWorkspaceRule(in toml: String, appID: String, workspace: Int) -> String {
        var out = removingWorkspaceRule(from: toml, appID: appID)
        if !out.isEmpty, !out.hasSuffix("\n") { out += "\n" }
        if !out.isEmpty, !out.hasSuffix("\n\n") { out += "\n" }
        return out + workspaceRuleBlock(appID: appID, workspace: workspace)
    }

    /// `toml` without the macrx-added workspace rule for `appID` (unchanged if there is none).
    public static func removingWorkspaceRule(from toml: String, appID: String) -> String {
        let pattern = #"(?m)^\[\[rule\]\][ \t]*"# + NSRegularExpression.escapedPattern(for: marker)
            + #"[ \t]*\napp-id = "# + NSRegularExpression.escapedPattern(for: tomlString(appID))
            + #"[ \t]*\nworkspace = -?\d+[ \t]*\n(\n)?"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return toml }
        let range = NSRange(toml.startIndex..., in: toml)
        return re.stringByReplacingMatches(in: toml, range: range, withTemplate: "")
    }

    /// The workspace a macrx-added rule pins `appID` to, if any.
    public static func workspaceRule(in rules: [Rule], appID: String) -> Int? {
        rules.first { $0.appID == appID && $0.titleRegex == nil && $0.workspace != nil }?.workspace
    }

    static func tomlString(_ s: String) -> String {
        var out = "\""
        for ch in s.unicodeScalars {
            switch ch {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            default: out.unicodeScalars.append(ch)
            }
        }
        return out + "\""
    }
}
