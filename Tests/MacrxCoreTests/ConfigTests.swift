import Testing
import Foundation
@testable import MacrxCore

@Suite struct ConfigTests {
    @Test func DefaultConfigParses() {
        let cfg = Config.default
        #expect(cfg.focusFollowsMouse)
        #expect(cfg.tabBar.show == .multiple)
        #expect(cfg.tabBar.switchOn == .hover)
        #expect(cfg.bindings[KeyCombo(string: "alt-j")!] == .focus(.left))
        let r1 = cfg.bindings[KeyCombo(string: "alt-shift-l")!]
        #expect(r1 == .move(.right))
        #expect(cfg.firstWorkspace == 0)
        #expect(cfg.bindings[KeyCombo(string: "alt-0")!] == .workspace(0))
        #expect(cfg.bindings[KeyCombo(string: "alt-3")!] == .workspace(3))
        #expect(cfg.bindings[KeyCombo(string: "alt-shift-0")!] == .moveToWorkspace(0))
        #expect(cfg.bindings[KeyCombo(string: "alt-u")!] == .stack(-1))
        #expect(cfg.bindings[KeyCombo(string: "alt-o")!] == .stack(1))
        #expect(cfg.rules.count == 2)
        #expect(cfg.rules[1].clickToFocus)
                        #expect(cfg.rules[0].matches(appID: "com.apple.finder", title: "Copy 3 items"))
        #expect(!(cfg.rules[0].matches(appID: "com.apple.finder", title: "Documents")))
    }

    @Test func FirstWorkspaceOption() throws {
        #expect(try Config.parse("first-workspace = 1").firstWorkspace == 1)
        #expect(throws: ConfigError.self) { try Config.parse("first-workspace = -1") }
    }

    @Test func PartialConfigUsesDefaults() throws {
        let cfg = try Config.parse("""
        focus-follows-mouse = false
        [tab-bar]
        show = "always"
        switch-on = "click"
        [binding]
        cmd-ctrl-space = "float"
        """)
        #expect(!(cfg.focusFollowsMouse))
        #expect(cfg.mouseFollowsFocus)
        #expect(cfg.tabBar.show == .always)
        #expect(cfg.tabBar.switchOn == .click)
        #expect(cfg.tabBar.height == 26)
        #expect(cfg.bindings == [KeyCombo(modifiers: [.cmd, .ctrl], keyCode: 0x31): .float])

        // Omitting [binding] and [[rule]] keeps the defaults, so a config file only needs
        // what the user actually overrides.
        let minimal = try Config.parse("focus-follows-mouse = false")
        #expect(minimal.bindings == Config.default.bindings)
        #expect(minimal.rules == Config.default.rules)
    }

    @Test func BadCommandIsRejected() {
        #expect { try Config.parse("[binding]\nalt-h = \"fly away\"") } throws: { e in "\(e)".contains("Unknown command") }
        #expect { try Config.parse("[binding]\nhyper-h = \"focus left\"") } throws: { e in "\(e)".contains("Unknown key combination") }
        #expect(throws: (any Error).self) { try Config.parse("this is not toml =") }
    }

    @Test func CommandParsing() {
        let r2 = Command(string: "resize up")
        #expect(r2 == .resize(.up))
        #expect(Command(string: "move-to-display left") == .moveToDisplay(.left))
        #expect(Command(string: "move-to-workspace 7") == .moveToWorkspace(7))
        #expect(Command(string: "stack next") == .stack(1))
        #expect(Command(string: "workspace back-and-forth") == .workspaceBack)
        #expect(Command(string: "focus") == nil)
        #expect(Command(string: "focus sideways") == nil)
        #expect(Command(string: "quit now") == nil)
    }

    @Test func KeyComboParsing() {
        #expect(KeyCombo(string: "option-shift-Left") == KeyCombo(modifiers: [.alt, .shift], keyCode: 0x7B))
        #expect(KeyCombo(string: "h") == KeyCombo(modifiers: [], keyCode: 0x04))
        #expect(KeyCombo(string: "alt-nope") == nil)
        #expect(KeyCombo(string: "alt-shift-h")!.description == "alt-shift-h")
    }
}
