import Foundation
import CoreGraphics
import TOMLKit

public enum TabBarVisibility: String, Codable, Sendable {
    /// Only when a stack holds two or more windows.
    case multiple
    case always
    case never
}

public enum TabSwitchMode: String, Codable, Sendable {
    /// Moving the pointer over a tab switches to it.
    case hover
    /// Tabs switch only when clicked.
    case click
}

public struct TabBarConfig: Codable, Equatable, Sendable {
    public var show: TabBarVisibility = .multiple
    public var height: Double = 26
    public var fontSize: Double = 12
    public var switchOn: TabSwitchMode = .hover
    public var stripAppSuffix = true

    public init() {}

    enum CodingKeys: String, CodingKey {
        case show, height
        case fontSize = "font-size"
        case switchOn = "switch-on"
        case stripAppSuffix = "strip-app-suffix"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        show = try c.decodeIfPresent(TabBarVisibility.self, forKey: .show) ?? .multiple
        height = try c.decodeNumberIfPresent(forKey: .height) ?? 26
        fontSize = try c.decodeNumberIfPresent(forKey: .fontSize) ?? 12
        switchOn = try c.decodeIfPresent(TabSwitchMode.self, forKey: .switchOn) ?? .hover
        stripAppSuffix = try c.decodeIfPresent(Bool.self, forKey: .stripAppSuffix) ?? true
    }

    /// Height of the bar for a stack with `count` windows.
    public func height(forWindowCount count: Int) -> CGFloat {
        switch show {
        case .never: return 0
        case .always: return CGFloat(height)
        case .multiple: return count >= 2 ? CGFloat(height) : 0
        }
    }
}

/// A window-matching rule. All specified fields must match.
public struct Rule: Codable, Equatable, Sendable {
    public var appID: String?
    public var titleRegex: String?
    /// Window is managed but never tiled.
    public var float: Bool = false
    /// Window is left completely alone (no tiling, no focus tracking).
    public var ignore: Bool = false
    /// The app ignores programmatic key-window changes; focus it by clicking its title bar.
    public var clickToFocus: Bool = false
    /// New matching windows open on this workspace (without switching to it), like i3's `assign`.
    public var workspace: Int?

    public init(appID: String? = nil, titleRegex: String? = nil, float: Bool = false, ignore: Bool = false, clickToFocus: Bool = false, workspace: Int? = nil) {
        self.appID = appID
        self.titleRegex = titleRegex
        self.float = float
        self.ignore = ignore
        self.clickToFocus = clickToFocus
        self.workspace = workspace
    }

    enum CodingKeys: String, CodingKey {
        case appID = "app-id"
        case titleRegex = "title-regex"
        case clickToFocus = "click-to-focus"
        case float, ignore, workspace
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        appID = try c.decodeIfPresent(String.self, forKey: .appID)
        titleRegex = try c.decodeIfPresent(String.self, forKey: .titleRegex)
        float = try c.decodeIfPresent(Bool.self, forKey: .float) ?? false
        ignore = try c.decodeIfPresent(Bool.self, forKey: .ignore) ?? false
        clickToFocus = try c.decodeIfPresent(Bool.self, forKey: .clickToFocus) ?? false
        workspace = try c.decodeIfPresent(Int.self, forKey: .workspace)
    }

    public func matches(appID: String?, title: String?) -> Bool {
        if let want = self.appID, want != appID { return false }
        if let pattern = titleRegex {
            guard let title, title.range(of: pattern, options: .regularExpression) != nil else { return false }
        }
        return self.appID != nil || titleRegex != nil
    }
}

public struct ConfigError: Error, CustomStringConvertible {
    public let description: String
    public init(_ d: String) { description = d }
}

extension KeyedDecodingContainer {
    /// TOML distinguishes integers from floats; accept both for numeric settings.
    func decodeNumberIfPresent(forKey key: Key) throws -> Double? {
        if let d = try? decodeIfPresent(Double.self, forKey: key) { return d }
        if let i = try? decodeIfPresent(Int.self, forKey: key) { return Double(i) }
        return nil
    }
}

public struct Config: Equatable, Sendable {
    public var focusFollowsMouse = true
    public var mouseFollowsFocus = true
    public var resizeStep: Double = 0.05
    /// Show the workspace indicator in the menu bar.
    public var menuBar = true
    /// Number of the first workspace: the one each display starts on, and the base of the
    /// `Workspace N` list in menus. Bindings name workspaces explicitly, so change those too.
    public var firstWorkspace = 0
    public var tabBar = TabBarConfig()
    public var bindings: [KeyCombo: Command] = [:]
    public var rules: [Rule] = []

    public init() {}

    // MARK: Loading

    public static func load(from url: URL) throws -> Config {
        let text = try String(contentsOf: url, encoding: .utf8)
        return try parse(text)
    }

    public static func parse(_ toml: String) throws -> Config {
        let raw: RawConfig
        do {
            raw = try TOMLDecoder().decode(RawConfig.self, from: toml)
        } catch let e as TOMLParseError {
            throw ConfigError("TOML syntax error at line \(e.source.begin.line): \(e.description)")
        }
        var cfg = Config()
        cfg.focusFollowsMouse = raw.focusFollowsMouse ?? true
        cfg.mouseFollowsFocus = raw.mouseFollowsFocus ?? true
        cfg.resizeStep = raw.resizeStep ?? 0.05
        cfg.menuBar = raw.menuBar ?? true
        cfg.firstWorkspace = raw.firstWorkspace ?? 0
        guard cfg.firstWorkspace >= 0 else { throw ConfigError("first-workspace must be 0 or greater") }
        cfg.tabBar = raw.tabBar ?? TabBarConfig()
        cfg.rules = raw.rule ?? []
        for (keyString, cmdString) in raw.binding ?? [:] {
            guard let combo = KeyCombo(string: keyString) else {
                throw ConfigError("Unknown key combination '\(keyString)'")
            }
            guard let cmd = Command(string: cmdString) else {
                throw ConfigError("Unknown command '\(cmdString)' for binding '\(keyString)'")
            }
            cfg.bindings[combo] = cmd
        }
        return cfg
    }

    private struct RawConfig: Decodable {
        var focusFollowsMouse: Bool?
        var mouseFollowsFocus: Bool?
        var resizeStep: Double?
        var menuBar: Bool?
        var firstWorkspace: Int?
        var tabBar: TabBarConfig?
        var binding: [String: String]?
        var rule: [Rule]?

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            focusFollowsMouse = try c.decodeIfPresent(Bool.self, forKey: .focusFollowsMouse)
            mouseFollowsFocus = try c.decodeIfPresent(Bool.self, forKey: .mouseFollowsFocus)
            resizeStep = try c.decodeNumberIfPresent(forKey: .resizeStep)
            menuBar = try c.decodeIfPresent(Bool.self, forKey: .menuBar)
            firstWorkspace = try c.decodeIfPresent(Int.self, forKey: .firstWorkspace)
            tabBar = try c.decodeIfPresent(TabBarConfig.self, forKey: .tabBar)
            binding = try c.decodeIfPresent([String: String].self, forKey: .binding)
            rule = try c.decodeIfPresent([Rule].self, forKey: .rule)
        }

        enum CodingKeys: String, CodingKey {
            case focusFollowsMouse = "focus-follows-mouse"
            case mouseFollowsFocus = "mouse-follows-focus"
            case resizeStep = "resize-step"
            case menuBar = "menu-bar"
            case firstWorkspace = "first-workspace"
            case tabBar = "tab-bar"
            case binding, rule
        }
    }

    // MARK: Defaults

    public static let defaultTOML = """
    # macrx configuration — ~/.config/macrx/config.toml

    focus-follows-mouse = true
    mouse-follows-focus = true
    resize-step = 0.05
    menu-bar = true          # workspace indicator in the menu bar
    first-workspace = 0      # number of the first workspace (bindings below name them explicitly)

    [tab-bar]
    show = "multiple"        # multiple | always | never
    switch-on = "hover"      # hover | click
    strip-app-suffix = true  # "Page - Google Chrome - Me (me@x.com)" → "Page"
    height = 26
    font-size = 12

    [binding]
    # Focus
    alt-i = "focus up"
    alt-j = "focus left"
    alt-k = "focus down"
    alt-l = "focus right"
    alt-u = "stack prev"
    alt-o = "stack next"

    # Move (pass-through: leaves a stack, joins a neighbor, or crosses displays)
    alt-shift-i = "move up"
    alt-shift-j = "move left"
    alt-shift-k = "move down"
    alt-shift-l = "move right"

    # Resize (a resized tile keeps a fixed size; the rest share what is left equally)
    alt-ctrl-i = "resize up"
    alt-ctrl-j = "resize left"
    alt-ctrl-k = "resize down"
    alt-ctrl-l = "resize right"
    alt-ctrl-0 = "resize reset"

    # Displays
    alt-shift-left = "move-to-display left"
    alt-shift-down = "move-to-display down"
    alt-shift-up = "move-to-display up"
    alt-shift-right = "move-to-display right"
    alt-ctrl-left = "move-workspace-to-display left"
    alt-ctrl-down = "move-workspace-to-display down"
    alt-ctrl-up = "move-workspace-to-display up"
    alt-ctrl-right = "move-workspace-to-display right"

    # Workspaces
    alt-0 = "workspace 0"
    alt-1 = "workspace 1"
    alt-2 = "workspace 2"
    alt-3 = "workspace 3"
    alt-4 = "workspace 4"
    alt-5 = "workspace 5"
    alt-6 = "workspace 6"
    alt-7 = "workspace 7"
    alt-8 = "workspace 8"
    alt-9 = "workspace 9"
    alt-tab = "workspace back-and-forth"
    alt-shift-0 = "move-to-workspace 0"
    alt-shift-1 = "move-to-workspace 1"
    alt-shift-2 = "move-to-workspace 2"
    alt-shift-3 = "move-to-workspace 3"
    alt-shift-4 = "move-to-workspace 4"
    alt-shift-5 = "move-to-workspace 5"
    alt-shift-6 = "move-to-workspace 6"
    alt-shift-7 = "move-to-workspace 7"
    alt-shift-8 = "move-to-workspace 8"
    alt-shift-9 = "move-to-workspace 9"

    # Misc
    alt-f = "fullscreen"
    alt-shift-space = "float"
    alt-e = "toggle-orientation"
    alt-shift-r = "reload"
    alt-shift-q = "quit"


    [[rule]]
    app-id = "com.apple.finder"
    title-regex = "^(Copy|Move|Trash)"
    float = true

    # kitty (GLFW) ignores every programmatic key-window switch; a title-bar click is the only way.
    [[rule]]
    app-id = "net.kovidgoyal.kitty"
    click-to-focus = true
    """

    public static let `default`: Config = {
        do { return try parse(defaultTOML) } catch { fatalError("default config invalid: \(error)") }
    }()
}
