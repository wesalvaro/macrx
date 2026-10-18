import AppKit
import MacrxCore

/// A small glyph shown at the top-right of a tile explaining why it is the size it is.
struct SizeBadge: Equatable {
    let symbol: String
    let tooltip: String
    /// Node to reset to flex when clicked; nil for informational badges.
    let resetsNode: ObjectIdentifier?

    static let width: CGFloat = 22

    static func badges(for kinds: [LayoutEngine.SizeMarkerKind], nodeID: ObjectIdentifier) -> [SizeBadge] {
        var out: [SizeBadge] = []
        for k in kinds {
            switch k {
            case .fixed(let axis, let pts):
                let what = axis == .horizontal ? "width" : "height"
                out.append(SizeBadge(symbol: "lock.fill", tooltip: "Fixed \(what): \(Int(pts)) pt — click to make flexible", resetsNode: nodeID))
            case .capped(let w, let h):
                let symbol: String
                var parts: [String] = []
                if let w { parts.append("width \(Int(w)) pt") }
                if let h { parts.append("height \(Int(h)) pt") }
                switch (w != nil, h != nil) {
                case (true, true): symbol = "arrow.up.and.down.and.arrow.left.and.right"
                case (true, false): symbol = "arrow.left.and.right"
                default: symbol = "arrow.up.and.down"
                }
                out.append(SizeBadge(symbol: symbol, tooltip: "Limited by the app: " + parts.joined(separator: ", "), resetsNode: nil))
            }
        }
        // Right-aligned layout fills from the right, so put the informational arrows last in the
        // array (right-most) and the clickable lock before them.
        return out.sorted { ($0.resetsNode != nil ? 0 : 1) < ($1.resetsNode != nil ? 0 : 1) }.reversed()
    }

    var image: NSImage? {
        let cfg = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        return NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)?.withSymbolConfiguration(cfg)
    }
}

/// Draws a row of badges, right-aligned, and reports clicks on the resettable ones.
/// Shared by the tab bar (drawn inline) and the floating badge panel.
enum SizeBadgeDrawer {
    static func rects(for badges: [SizeBadge], in bounds: CGRect, trailingPad: CGFloat) -> [CGRect] {
        var x = bounds.maxX - trailingPad
        return badges.map { _ in
            x -= SizeBadge.width
            return CGRect(x: x, y: bounds.minY, width: SizeBadge.width, height: bounds.height)
        }
    }

    static func draw(_ badges: [SizeBadge], rects: [CGRect], hovered: Int?) {
        for (i, b) in badges.enumerated() where i < rects.count {
            let r = rects[i]
            let clickable = b.resetsNode != nil
            if clickable, hovered == i {
                NSColor.labelColor.withAlphaComponent(0.16).setFill()
                NSBezierPath(roundedRect: r.insetBy(dx: 2, dy: (r.height - 18) / 2), xRadius: 4, yRadius: 4).fill()
            }
            guard let img = b.image else { continue }
            let tint: NSColor = (clickable && hovered == i) ? .labelColor : .secondaryLabelColor
            let tinted = img.tinted(tint)
            let s = img.size
            let ir = CGRect(x: r.midX - s.width / 2, y: r.midY - s.height / 2, width: s.width, height: s.height)
            tinted.draw(in: ir, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
    }
}

extension NSImage {
    func tinted(_ color: NSColor) -> NSImage {
        let img = NSImage(size: size, flipped: false) { rect in
            self.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        img.isTemplate = false
        return img
    }
}

/// One floating badge panel per node whose top-right tile has no tab bar to host it.
@MainActor
final class SizeBadgeController {
    var onResetSize: ((ObjectIdentifier) -> Void)?
    private var panels: [ObjectIdentifier: BadgePanel] = [:]

    /// `anchors`: node id → (top-right corner of the node in AX coordinates, badges).
    func sync(_ anchors: [ObjectIdentifier: (corner: CGPoint, badges: [SizeBadge])]) {
        var seen: Set<ObjectIdentifier> = []
        for (id, a) in anchors where !a.badges.isEmpty {
            seen.insert(id)
            let panel = panels[id] ?? makePanel()
            panels[id] = panel
            let w = SizeBadge.width * CGFloat(a.badges.count) + 6
            let h: CGFloat = 20
            let ax = CGRect(x: a.corner.x - 6 - w, y: a.corner.y + 6, width: w, height: h)
            let rect = CoordinateSpace.toAppKit(ax)
            if panel.frame != rect { panel.setFrame(rect, display: false) }
            panel.badgeView.badges = a.badges
            panel.badgeView.toolTip = a.badges.map(\.tooltip).joined(separator: "\n")
            if !panel.isVisible { panel.orderFrontRegardless() }
            panel.display()
        }
        for (id, p) in panels where !seen.contains(id) {
            p.orderOut(nil)
            panels[id] = nil
        }
    }

    func bringToFront() { for p in panels.values where p.isVisible { p.orderFrontRegardless() } }

    func hideAll() {
        panels.values.forEach { $0.orderOut(nil) }
        panels.removeAll()
    }

    private func makePanel() -> BadgePanel {
        let p = BadgePanel()
        p.badgeView.onReset = { [weak self] id in self?.onResetSize?(id) }
        return p
    }
}

private final class BadgePanel: NSPanel {
    let badgeView = BadgeView()

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        let effect = NSVisualEffectView()
        effect.material = .headerView
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 6
        effect.layer?.masksToBounds = true
        effect.autoresizingMask = [.width, .height]
        badgeView.autoresizingMask = [.width, .height]
        effect.addSubview(badgeView)
        contentView = effect
        badgeView.frame = effect.bounds
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class BadgeView: NSView {
    var badges: [SizeBadge] = [] { didSet { if badges != oldValue { needsDisplay = true } } }
    var onReset: ((ObjectIdentifier) -> Void)?
    private var hovered: Int? { didSet { if hovered != oldValue { needsDisplay = true } } }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }

    private var rects: [CGRect] { SizeBadgeDrawer.rects(for: badges, in: bounds, trailingPad: 3) }

    override func draw(_ dirtyRect: NSRect) {
        SizeBadgeDrawer.draw(badges, rects: rects, hovered: hovered)
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        hovered = rects.firstIndex { $0.contains(p) }
    }
    override func mouseExited(with event: NSEvent) { hovered = nil }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let i = rects.firstIndex(where: { $0.contains(p) }), let id = badges[i].resetsNode else { return }
        onReset?(id)
    }
}
