import Testing
import Foundation
@testable import MacrxCore

@Suite struct ConfigEditorTests {
    let base = """
    menu-bar = true

    [[rule]]
    app-id = "com.apple.finder"
    float = true
    """

    @Test func AddsParsableWorkspaceRule() throws {
        let out = ConfigEditor.settingWorkspaceRule(in: base, appID: "com.google.Chrome", workspace: 2)
        let cfg = try Config.parse(out)
        #expect(cfg.rules.count == 2)
        #expect(cfg.rules[1].appID == "com.google.Chrome")
        #expect(cfg.rules[1].workspace == 2)
        #expect(ConfigEditor.workspaceRule(in: cfg.rules, appID: "com.google.Chrome") == 2)
        #expect(ConfigEditor.workspaceRule(in: cfg.rules, appID: "com.apple.finder") == nil)
        // The user's text is untouched.
        #expect(out.hasPrefix(base))
    }

    @Test func ReplacesAndRemovesOnlyItsOwnRule() throws {
        let one = ConfigEditor.settingWorkspaceRule(in: base, appID: "com.google.Chrome", workspace: 2)
        let two = ConfigEditor.settingWorkspaceRule(in: one, appID: "com.google.Chrome", workspace: 5)
        #expect(try Config.parse(two).rules.filter { $0.appID == "com.google.Chrome" }.count == 1)
        #expect(try Config.parse(two).rules.last?.workspace == 5)

        let removed = ConfigEditor.removingWorkspaceRule(from: two, appID: "com.google.Chrome")
        #expect(removed.trimmingCharacters(in: .whitespacesAndNewlines) == base.trimmingCharacters(in: .whitespacesAndNewlines))
        // Unknown app: no change.
        #expect(ConfigEditor.removingWorkspaceRule(from: two, appID: "org.other") == two)
    }

    @Test func EscapesAppIDs() throws {
        let out = ConfigEditor.settingWorkspaceRule(in: "", appID: "weird\"id", workspace: 0)
        #expect(try Config.parse(out).rules.first?.appID == "weird\"id")
        #expect(ConfigEditor.removingWorkspaceRule(from: out, appID: "weird\"id").isEmpty)
    }
}
