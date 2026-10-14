import AppKit
import MacrxCore

struct TabItem: Equatable {
    let id: WindowID
    let title: String
    let fullTitle: String
    let icon: NSImage?

    static func == (a: TabItem, b: TabItem) -> Bool {
        a.id == b.id && a.title == b.title && a.fullTitle == b.fullTitle && a.icon === b.icon
    }
}

/// Draws one tab per window of a stack: pill-style selected tab, hover highlight,
/// content-sized widths (or equal), material background supplied by the panel.
final class TabBarView: NSView {
    var items: [TabItem] = [] { didSet { if items != oldValue { relayout() } } }
    var topID: WindowID? { didSet { if topID != oldValue { needsDisplay = true } } }
    var hoveredID: WindowID? { didSet { if hoveredID != oldValue { needsDisplay = true } } }
    var isFocused = false { didSet { if isFocused != oldValue { needsDisplay = true } } }
    var fontSize: CGFloat = 12 { didSet { if fontSize != oldValue { relayout() } } }
    var widthMode: TabWidthMode = .fit { didSet { if widthMode != oldValue { relayout() } } }
    var onTabClicked: ((WindowID) -> Void)?

    /// Tab rects in view coordinates (origin top-left, left → right).
    private(set) var tabRects: [CGRect] = []

    private let hPad: CGFloat = 10
    private let iconGap: CGFloat = 6
    private let minTab: CGFloat = 80
    private let maxTab: CGFloat = 280

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func layout() {
        super.layout()
        relayout()
    }

    private var font: NSFont { .systemFont(ofSize: fontSize, weight: .medium) }
    private var iconSize: CGFloat { max(12, min(18, bounds.height - 10)) }

    private func relayout() {
        guard bounds.width > 0 else { return }
        let widths: [CGFloat]
        switch widthMode {
        case .equal:
            widths = TabLayout.equalWidths(count: items.count, available: bounds.width)
        case .fit:
            let attrs: [NSAttributedString.Key: Any] = [.font: font]
            let natural = items.map { item -> CGFloat in
                let text = (item.title as NSString).size(withAttributes: attrs).width
                return hPad + (item.icon != nil ? iconSize + iconGap : 0) + ceil(text) + hPad
            }
            widths = TabLayout.widths(natural: natural, available: bounds.width, minWidth: minTab, maxWidth: maxTab)
        }
        tabRects = TabLayout.rects(widths: widths, in: bounds)
        toolTip = nil
        removeAllToolTips()
        for (i, r) in tabRects.enumerated() { addToolTip(r, owner: items[i].fullTitle as NSString, userData: nil) }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let accent = NSColor.controlAccentColor
        let pillInset: CGFloat = 3
        let radius: CGFloat = 6

        for (i, item) in items.enumerated() where i < tabRects.count {
            let r = tabRects[i]
            let selected = item.id == topID
            let hovered = item.id == hoveredID
            let pill = r.insetBy(dx: pillInset, dy: pillInset)

            // Subdued, title-bar-like emphasis: a tinted pill on the focused stack, a neutral
            // one on unfocused stacks, a faint one under the pointer.
            if selected {
                let fill = isFocused ? accent.withAlphaComponent(0.32) : NSColor.labelColor.withAlphaComponent(0.12)
                fill.setFill()
                NSBezierPath(roundedRect: pill, xRadius: radius, yRadius: radius).fill()
            } else if hovered {
                NSColor.labelColor.withAlphaComponent(0.08).setFill()
                NSBezierPath(roundedRect: pill, xRadius: radius, yRadius: radius).fill()
            }

            let fg: NSColor = selected ? .labelColor : .secondaryLabelColor

            var x = r.minX + hPad
            if let icon = item.icon {
                let ir = CGRect(x: x, y: (r.height - iconSize) / 2, width: iconSize, height: iconSize)
                icon.draw(in: ir, from: .zero, operation: .sourceOver, fraction: selected ? 1 : 0.75, respectFlipped: true, hints: nil)
                x += iconSize + iconGap
            }
            let para = NSMutableParagraphStyle()
            para.lineBreakMode = .byTruncatingTail
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: fg, .paragraphStyle: para]
            let text = item.title as NSString
            let size = text.size(withAttributes: attrs)
            let tr = CGRect(x: x, y: (r.height - size.height) / 2, width: max(0, r.maxX - hPad - x), height: size.height)
            text.draw(with: tr, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attrs)
        }

        NSColor.separatorColor.setFill()
        CGRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }

    func tab(at viewPoint: CGPoint) -> WindowID? {
        tabRects.firstIndex { $0.contains(viewPoint) }.map { items[$0].id }
    }

    override func mouseDown(with event: NSEvent) {
        if let id = tab(at: convert(event.locationInWindow, from: nil)) { onTabClicked?(id) }
    }
}

/// A borderless, non-activating panel hosting a `TabBarView` over a material background.
final class TabBarPanel: NSPanel {
    let tabView = TabBarView()

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false

        let effect = NSVisualEffectView()
        effect.material = .headerView
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.autoresizingMask = [.width, .height]
        tabView.autoresizingMask = [.width, .height]
        effect.addSubview(tabView)
        contentView = effect
        tabView.frame = effect.bounds
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
