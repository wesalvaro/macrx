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
/// hover-only close button (`×`), drag-to-reorder/move, and right-click context menu.
final class TabBarView: NSView {
    var items: [TabItem] = [] { didSet { if items != oldValue { relayout() } } }
    var topID: WindowID? { didSet { if topID != oldValue { needsDisplay = true } } }
    var hoveredID: WindowID? { didSet { if hoveredID != oldValue { needsDisplay = true } } }
    var closeHovered = false { didSet { if closeHovered != oldValue { needsDisplay = true } } }
    var draggedID: WindowID? { didSet { if draggedID != oldValue { needsDisplay = true } } }
    var isFocused = false { didSet { if isFocused != oldValue { needsDisplay = true } } }
    var fontSize: CGFloat = 12 { didSet { if fontSize != oldValue { relayout() } } }
    var widthMode: TabWidthMode = .fit { didSet { if widthMode != oldValue { relayout() } } }

    var onTabClicked: ((WindowID) -> Void)?
    var onTabClosed: ((WindowID) -> Void)?
    var menuForTab: ((WindowID) -> NSMenu?)?
    var onDragUpdated: ((WindowID, CGPoint) -> Void)?
    var onDragEnded: ((WindowID, CGPoint) -> Void)?

    /// Tab rects in view coordinates (origin top-left, left → right).
    private(set) var tabRects: [CGRect] = []

    private let hPad: CGFloat = 10
    private let iconGap: CGFloat = 6
    private let closeSize: CGFloat = 16
    private let minTab: CGFloat = 80
    private let maxTab: CGFloat = 280

    private var mouseDownID: WindowID?
    private var mouseDownOnClose = false
    private var mouseDownPoint: CGPoint = .zero
    private var isDragging = false

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func layout() {
        super.layout()
        relayout()
    }

    private var font: NSFont { .systemFont(ofSize: fontSize, weight: .medium) }
    private var iconSize: CGFloat { max(12, min(18, bounds.height - 10)) }

    func closeRect(for tabRect: CGRect) -> CGRect {
        CGRect(x: tabRect.maxX - 7 - closeSize, y: (tabRect.height - closeSize) / 2, width: closeSize, height: closeSize)
    }

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
            let dragged = item.id == draggedID
            let showClose = hovered && draggedID == nil
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
            if dragged {
                let border = NSBezierPath(roundedRect: pill.insetBy(dx: 0.75, dy: 0.75), xRadius: radius, yRadius: radius)
                border.lineWidth = 1.5
                accent.withAlphaComponent(0.85).setStroke()
                border.stroke()
            }

            let fg: NSColor = selected ? .labelColor : .secondaryLabelColor

            var x = r.minX + hPad
            if let icon = item.icon {
                let ir = CGRect(x: x, y: (r.height - iconSize) / 2, width: iconSize, height: iconSize)
                icon.draw(in: ir, from: .zero, operation: .sourceOver, fraction: selected ? 1 : 0.75, respectFlipped: true, hints: nil)
                x += iconSize + iconGap
            }
            let cr = closeRect(for: r)
            let rightEdge = showClose ? (cr.minX - 4) : (r.maxX - hPad)
            let para = NSMutableParagraphStyle()
            para.lineBreakMode = .byTruncatingTail
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: fg, .paragraphStyle: para]
            let text = item.title as NSString
            let size = text.size(withAttributes: attrs)
            let tr = CGRect(x: x, y: (r.height - size.height) / 2, width: max(0, rightEdge - x), height: size.height)
            text.draw(with: tr, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attrs)

            if showClose {
                if closeHovered {
                    NSColor.labelColor.withAlphaComponent(0.16).setFill()
                    NSBezierPath(roundedRect: cr, xRadius: 4, yRadius: 4).fill()
                }
                let cross = NSBezierPath()
                let d: CGFloat = 3.5
                let cx = cr.midX, cy = cr.midY
                cross.move(to: CGPoint(x: cx - d, y: cy - d))
                cross.line(to: CGPoint(x: cx + d, y: cy + d))
                cross.move(to: CGPoint(x: cx - d, y: cy + d))
                cross.line(to: CGPoint(x: cx + d, y: cy - d))
                cross.lineWidth = 1.5
                cross.lineCapStyle = .round
                (closeHovered ? NSColor.labelColor : NSColor.secondaryLabelColor).setStroke()
                cross.stroke()
            }
        }

        NSColor.separatorColor.setFill()
        CGRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }

    func tab(at viewPoint: CGPoint) -> WindowID? {
        tabRects.firstIndex { $0.contains(viewPoint) }.map { items[$0].id }
    }

    func closeButton(at viewPoint: CGPoint) -> WindowID? {
        guard let i = tabRects.firstIndex(where: { $0.contains(viewPoint) }), i < items.count else { return nil }
        return closeRect(for: tabRects[i]).contains(viewPoint) ? items[i].id : nil
    }

    override func mouseMoved(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        hoveredID = tab(at: pt)
        closeHovered = closeButton(at: pt) != nil
    }

    override func mouseExited(with event: NSEvent) {
        hoveredID = nil
        closeHovered = false
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            rightMouseDown(with: event)
            return
        }
        let pt = convert(event.locationInWindow, from: nil)
        guard let id = tab(at: pt) else { return }
        mouseDownID = id
        mouseDownPoint = pt
        isDragging = false
        mouseDownOnClose = (closeButton(at: pt) == id)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let id = mouseDownID, !mouseDownOnClose else { return }
        let pt = convert(event.locationInWindow, from: nil)
        if !isDragging {
            guard hypot(pt.x - mouseDownPoint.x, pt.y - mouseDownPoint.y) >= 4 else { return }
            isDragging = true
            draggedID = id
        }
        onDragUpdated?(id, CoordinateSpace.toAX(NSEvent.mouseLocation))
    }

    override func mouseUp(with event: NSEvent) {
        let id = mouseDownID
        let wasOnClose = mouseDownOnClose
        let wasDragging = isDragging
        mouseDownID = nil
        mouseDownOnClose = false
        isDragging = false
        draggedID = nil
        guard let id else { return }
        let pt = convert(event.locationInWindow, from: nil)
        if wasDragging {
            onDragEnded?(id, CoordinateSpace.toAX(NSEvent.mouseLocation))
        } else if wasOnClose {
            if closeButton(at: pt) == id { onTabClosed?(id) }
        } else if tab(at: pt) == id {
            onTabClicked?(id)
        }
    }

    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else { super.otherMouseDown(with: event); return }
        if let id = tab(at: convert(event.locationInWindow, from: nil)) { onTabClosed?(id) }
    }

    override func rightMouseDown(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        guard let id = tab(at: pt), let menu = menuForTab?(id) else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
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
