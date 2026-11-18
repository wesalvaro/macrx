import AppKit
import MacrxCore

/// Visual indicator for visible floating windows:
/// 1. A translucent amber outline around each floating window's perimeter (click-through).
/// 2. A clickable `"Floating"` pill badge pinned to the top-center of the visible portion of
///    the window; clicking it re-tiles the window immediately.
@MainActor
final class FloatingIndicatorController {
    struct Entry: Equatable {
        let id: WindowID
        let frame: CGRect
        let screenFrame: CGRect?
        let isFocused: Bool
        let shortcutHint: String?
    }

    var onUnfloat: ((WindowID) -> Void)?

    private struct Pair {
        let border: FloatingBorderPanel
        let pill: FloatingPillPanel
    }

    private var pairs: [WindowID: Pair] = [:]

    func sync(_ entries: [Entry]) {
        var seen: Set<WindowID> = []
        // Order unfocused entries first so the focused floating window's indicator sits on top.
        let sorted = entries.sorted { !$0.isFocused && $1.isFocused }
        for e in sorted {
            seen.insert(e.id)
            let pair = pairs[e.id] ?? makePair(for: e.id)
            pairs[e.id] = pair

            let borderRect = CoordinateSpace.toAppKit(e.frame)
            if pair.border.frame != borderRect {
                pair.border.setFrame(borderRect, display: false)
            }
            pair.border.borderView.isFocused = e.isFocused
            if !pair.border.isVisible || e.isFocused {
                pair.border.orderFrontRegardless()
            }
            pair.border.display()

            let pillSize = CGSize(width: 88, height: 22)
            let pillAX = Self.pillFrame(for: e.frame, screenFrame: e.screenFrame, size: pillSize)
            let pillRect = CoordinateSpace.toAppKit(pillAX)
            if pair.pill.frame != pillRect {
                pair.pill.setFrame(pillRect, display: false)
            }
            pair.pill.pillView.isFocused = e.isFocused
            let hint = e.shortcutHint.map { " (\($0))" } ?? ""
            pair.pill.pillView.toolTip = "Floating window — click to tile\(hint)"
            pair.pill.orderFrontRegardless()
            pair.pill.display()
        }
        for (id, pair) in pairs where !seen.contains(id) {
            pair.border.orderOut(nil)
            pair.pill.orderOut(nil)
            pairs[id] = nil
        }
    }

    func bringToFront() {
        let sorted = pairs.values.sorted { !$0.border.borderView.isFocused && $1.border.borderView.isFocused }
        for pair in sorted {
            if pair.border.isVisible { pair.border.orderFrontRegardless() }
            if pair.pill.isVisible { pair.pill.orderFrontRegardless() }
        }
    }

    func hideAll() {
        for pair in pairs.values {
            pair.border.orderOut(nil)
            pair.pill.orderOut(nil)
        }
        pairs.removeAll()
    }

    /// Computes the AX frame for the floating pill, centered on the top edge of the visible
    /// portion of `windowFrame` and clamped inside `screenFrame` so dragging a floating window
    /// partly offscreen never hides the badge.
    static func pillFrame(for windowFrame: CGRect, screenFrame: CGRect?, size: CGSize) -> CGRect {
        let visible: CGRect
        if let s = screenFrame {
            let inter = windowFrame.intersection(s)
            visible = (!inter.isNull && inter.width >= size.width + 12 && inter.height >= size.height + 8) ? inter : windowFrame
        } else {
            visible = windowFrame
        }
        var x = visible.midX - size.width / 2
        var y = visible.minY + 4
        if let s = screenFrame {
            x = min(max(x, s.minX + 6), max(s.minX + 6, s.maxX - size.width - 6))
            y = min(max(y, s.minY + 4), max(s.minY + 4, s.maxY - size.height - 4))
        }
        return CGRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height)
    }

    private func makePair(for id: WindowID) -> Pair {
        let border = FloatingBorderPanel()
        let pill = FloatingPillPanel()
        pill.pillView.onClick = { [weak self] in self?.onUnfloat?(id) }
        return Pair(border: border, pill: pill)
    }
}

private final class FloatingBorderPanel: NSPanel {
    let borderView = FloatingBorderView()

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        borderView.autoresizingMask = [.width, .height]
        contentView = borderView
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class FloatingBorderView: NSView {
    var isFocused = false { didSet { if isFocused != oldValue { needsDisplay = true } } }

    override func draw(_ dirtyRect: NSRect) {
        let lineWidth: CGFloat = isFocused ? 3.0 : 2.0
        let rect = bounds.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
        guard rect.width > 0, rect.height > 0 else { return }
        let radius = min(10, min(rect.width, rect.height) / 2)
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        NSColor.systemOrange.withAlphaComponent(isFocused ? 0.88 : 0.45).setStroke()
        path.lineWidth = lineWidth
        path.stroke()
    }
}

private final class FloatingPillPanel: NSPanel {
    let pillView = FloatingPillView()

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        let effect = NSVisualEffectView()
        effect.material = .headerView
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 11
        effect.layer?.masksToBounds = true
        effect.autoresizingMask = [.width, .height]
        pillView.autoresizingMask = [.width, .height]
        effect.addSubview(pillView)
        contentView = effect
        pillView.frame = effect.bounds
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class FloatingPillView: NSView {
    var isFocused = false { didSet { if isFocused != oldValue { needsDisplay = true } } }
    var onClick: (() -> Void)?
    private var hovered = false { didSet { if hovered != oldValue { needsDisplay = true } } }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }

    override func draw(_ dirtyRect: NSRect) {
        let radius = bounds.height / 2
        let bgPath = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
        let fillAlpha: CGFloat = hovered ? 0.40 : (isFocused ? 0.24 : 0.14)
        NSColor.systemOrange.withAlphaComponent(fillAlpha).setFill()
        bgPath.fill()

        let strokeWidth: CGFloat = 1.25
        let strokeRect = bounds.insetBy(dx: strokeWidth / 2, dy: strokeWidth / 2)
        let strokePath = NSBezierPath(roundedRect: strokeRect, xRadius: strokeRect.height / 2, yRadius: strokeRect.height / 2)
        let strokeAlpha: CGFloat = hovered ? 1.0 : (isFocused ? 0.85 : 0.55)
        NSColor.systemOrange.withAlphaComponent(strokeAlpha).setStroke()
        strokePath.lineWidth = strokeWidth
        strokePath.stroke()

        let symbolName = hovered ? "rectangle.split.2x1" : "rectangle.on.rectangle"
        let title = hovered ? "Tile" : "Floating"
        let font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        let textColor: NSColor = (hovered || isFocused) ? .labelColor : .secondaryLabelColor
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: textColor]
        let textSize = (title as NSString).size(withAttributes: attrs)

        let symCfg = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        let icon = NSImage(systemSymbolName: symbolName, accessibilityDescription: title)?
            .withSymbolConfiguration(symCfg)?
            .tinted(hovered ? .labelColor : .systemOrange)
        let iconSize = icon?.size ?? .zero
        let gap: CGFloat = icon != nil ? 4 : 0
        let totalW = iconSize.width + gap + textSize.width
        let startX = ((bounds.width - totalW) / 2).rounded()

        if let icon {
            let iconRect = CGRect(x: startX, y: (bounds.height - iconSize.height) / 2, width: iconSize.width, height: iconSize.height)
            icon.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        let textRect = CGRect(x: startX + iconSize.width + gap, y: (bounds.height - textSize.height) / 2 - 0.5, width: textSize.width, height: textSize.height)
        (title as NSString).draw(in: textRect, withAttributes: attrs)
    }

    override func mouseMoved(with event: NSEvent) {
        let onTop = MouseController.isOwnPanelTopmost(at: CoordinateSpace.toAX(NSEvent.mouseLocation))
        hovered = onTop && bounds.contains(convert(event.locationInWindow, from: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        mouseMoved(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
    }

    override func mouseDown(with event: NSEvent) {
        guard MouseController.isOwnPanelTopmost(at: CoordinateSpace.toAX(NSEvent.mouseLocation)) else { return }
        onClick?()
    }
}
