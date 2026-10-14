import AppKit
import MacrxCore

/// Menu bar status item: shows the visible workspace of every display (`2 · 5`, focused
/// display emphasised) and offers a dropdown to switch workspaces.
@MainActor
final class StatusBar {
    struct DisplayEntry {
        let name: String
        let visibleWorkspace: Int
        let isFocused: Bool
        /// (workspace id, window count), sorted by id.
        let workspaces: [(id: Int, windows: Int)]
    }

    var onSelectWorkspace: ((Int) -> Void)?
    var onReload: (() -> Void)?
    var onQuit: (() -> Void)?

    private var item: NSStatusItem?
    private var entries: [DisplayEntry] = []

    var isShown: Bool {
        get { item != nil }
        set {
            if newValue, item == nil {
                let i = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
                i.button?.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)
                i.menu = NSMenu()
                i.menu?.delegate = menuDelegate
                item = i
                render()
            } else if !newValue, let i = item {
                NSStatusBar.system.removeStatusItem(i)
                item = nil
            }
        }
    }

    private lazy var menuDelegate = MenuDelegate { [weak self] menu in self?.populate(menu) }

    func update(_ entries: [DisplayEntry]) {
        self.entries = entries
        render()
    }

    private func render() {
        guard let button = item?.button else { return }
        let title = NSMutableAttributedString()
        let dim: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor.secondaryLabelColor]
        for (i, e) in entries.enumerated() {
            if i > 0 { title.append(NSAttributedString(string: " · ", attributes: dim)) }
            title.append(NSAttributedString(string: "\(e.visibleWorkspace)", attributes: e.isFocused ? [:] : dim))
        }
        if entries.isEmpty { title.append(NSAttributedString(string: "–", attributes: dim)) }
        button.attributedTitle = title
        button.toolTip = entries.map { "\($0.name): workspace \($0.visibleWorkspace)" }.joined(separator: "\n")
    }

    private func populate(_ menu: NSMenu) {
        menu.removeAllItems()
        for e in entries {
            let header = NSMenuItem(title: e.name, action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for ws in e.workspaces {
                let label = ws.windows == 1 ? "1 window" : "\(ws.windows) windows"
                let mi = NSMenuItem(title: "Workspace \(ws.id)   \(label)", action: #selector(MenuTarget.pick(_:)), keyEquivalent: ws.id < 10 ? "\(ws.id)" : "")
                mi.keyEquivalentModifierMask = [.option]
                mi.indentationLevel = 1
                mi.state = ws.id == e.visibleWorkspace ? .on : .off
                mi.tag = ws.id
                mi.target = target
                menu.addItem(mi)
            }
            menu.addItem(.separator())
        }
        let reload = NSMenuItem(title: "Reload Config", action: #selector(MenuTarget.reload), keyEquivalent: "")
        reload.target = target
        menu.addItem(reload)
        let quit = NSMenuItem(title: "Quit macrx", action: #selector(MenuTarget.quit), keyEquivalent: "")
        quit.target = target
        menu.addItem(quit)
    }

    private lazy var target = MenuTarget(
        pick: { [weak self] n in self?.onSelectWorkspace?(n) },
        reload: { [weak self] in self?.onReload?() },
        quit: { [weak self] in self?.onQuit?() })
}

@MainActor
private final class MenuTarget: NSObject {
    let pickHandler: (Int) -> Void
    let reloadHandler: () -> Void
    let quitHandler: () -> Void
    init(pick: @escaping (Int) -> Void, reload: @escaping () -> Void, quit: @escaping () -> Void) {
        pickHandler = pick; reloadHandler = reload; quitHandler = quit
    }
    @objc func pick(_ sender: NSMenuItem) { pickHandler(sender.tag) }
    @objc func reload() { reloadHandler() }
    @objc func quit() { quitHandler() }
}

@MainActor
private final class MenuDelegate: NSObject, NSMenuDelegate {
    let build: (NSMenu) -> Void
    init(build: @escaping (NSMenu) -> Void) { self.build = build }
    func menuNeedsUpdate(_ menu: NSMenu) { build(menu) }
}
