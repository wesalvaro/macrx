import AppKit
import MacrxCore

struct TabItem: Equatable {
    let id: WindowID
    let title: String
    let icon: NSImage?

    static func == (a: TabItem, b: TabItem) -> Bool { a.id == b.id && a.title == b.title && a.icon === b.icon }
}

/// Draws one tab per window of a stack.
final class TabBarView: NSView {
    var items: [TabItem] = [] { didSet { if items != oldValue { needsDisplay = true } } }
    var topID: WindowID? { didSet { if topID != oldValue { needsDisplay = true } } }
    var isFocused = false { didSet { if isFocused != oldValue { needsDisplay = true } } }
    var fontSize: CGFloat = 12 { didSet { needsDisplay = true } }
    var onTabClicked: ((WindowID) -> Void)?

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    private func tabRect(_ index: Int) -> CGRect {
        guard !items.isEmpty else { return .zero }
        let w = bounds.width / CGFloat(items.count)
        return CGRect(x: w * CGFloat(index), y: 0, width: w, height: bounds.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        let bg = NSColor.windowBackgroundColor
        bg.setFill()
        bounds.fill()

        let accent = NSColor.controlAccentColor
        let iconSize = max(12, bounds.height - 10)

        for (i, item) in items.enumerated() {
            let r = tabRect(i)
            let selected = item.id == topID
            if selected {
                (isFocused ? accent : NSColor.unemphasizedSelectedContentBackgroundColor).setFill()
                r.insetBy(dx: 1, dy: 1).fill()
            } else {
                NSColor.separatorColor.setFill()
                CGRect(x: r.maxX - 0.5, y: 4, width: 1, height: r.height - 8).fill()
            }
            let fg: NSColor = selected && isFocused ? .alternateSelectedControlTextColor : (selected ? .labelColor : .secondaryLabelColor)
            var x = r.minX + 8
            if let icon = item.icon {
                let ir = CGRect(x: x, y: (r.height - iconSize) / 2, width: iconSize, height: iconSize)
                icon.draw(in: ir, from: .zero, operation: .sourceOver, fraction: selected ? 1 : 0.7, respectFlipped: true, hints: nil)
                x += iconSize + 6
            }
            let para = NSMutableParagraphStyle()
            para.lineBreakMode = .byTruncatingTail
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: fontSize, weight: selected ? .semibold : .regular),
                .foregroundColor: fg,
                .paragraphStyle: para,
            ]
            let text = item.title.isEmpty ? "Untitled" : item.title
            let size = (text as NSString).size(withAttributes: attrs)
            let tr = CGRect(x: x, y: (r.height - size.height) / 2, width: max(0, r.maxX - 8 - x), height: size.height)
            (text as NSString).draw(with: tr, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attrs)
        }

        NSColor.separatorColor.setFill()
        CGRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        for i in items.indices where tabRect(i).contains(p) {
            onTabClicked?(items[i].id)
            return
        }
    }
}

/// A borderless, non-activating panel hosting a `TabBarView`.
final class TabBarPanel: NSPanel {
    let tabView = TabBarView()

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        isOpaque = true
        hasShadow = false
        hidesOnDeactivate = false
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        backgroundColor = .windowBackgroundColor
        contentView = tabView
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
