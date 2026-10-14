import AppKit
import MacrxCore

/// Keeps one `TabBarPanel` per visible tile that has a tab bar.
@MainActor
final class TabBarController {
    var onTabClicked: ((WindowID) -> Void)?
    var fontSize: CGFloat = 12

    private var panels: [ObjectIdentifier: TabBarPanel] = [:]

    /// Tab bar frames (AX coordinates) per stack, for pointer hit-testing.
    private(set) var frames: [ObjectIdentifier: CGRect] = [:]

    /// The window whose tab is under `p`, if `p` is inside a tab bar.
    func tab(at p: CGPoint, tiles: [Tile]) -> (stack: ObjectIdentifier, window: WindowID)? {
        for tile in tiles where tile.hasTabBar && tile.tabBar.contains(p) {
            let w = tile.tabBar.width / CGFloat(tile.windows.count)
            let i = min(Int((p.x - tile.tabBar.minX) / w), tile.windows.count - 1)
            return (tile.stackID, tile.windows[max(0, i)])
        }
        return nil
    }

    func sync(tiles: [Tile], focused: WindowID?, item: (WindowID) -> TabItem) {
        var seen: Set<ObjectIdentifier> = []
        frames.removeAll(keepingCapacity: true)
        for tile in tiles where tile.hasTabBar {
            seen.insert(tile.stackID)
            let panel = panels[tile.stackID] ?? makePanel(for: tile.stackID)
            let view = panel.tabView
            view.items = tile.windows.map(item)
            view.topID = tile.top
            view.isFocused = focused.map(tile.windows.contains) ?? false
            view.fontSize = fontSize
            let rect = CoordinateSpace.toAppKit(tile.tabBar)
            if panel.frame != rect { panel.setFrame(rect, display: true) }
            frames[tile.stackID] = tile.tabBar
            if !panel.isVisible { panel.orderFrontRegardless() }
        }
        for (id, panel) in panels where !seen.contains(id) {
            panel.orderOut(nil)
            panels[id] = nil
        }
    }

    func setFocused(_ focused: WindowID?) {
        for panel in panels.values {
            panel.tabView.isFocused = focused.map(panel.tabView.items.map(\.id).contains) ?? false
        }
    }

    /// Re-asserts z-order above the managed windows.
    func bringToFront() {
        for panel in panels.values where panel.isVisible { panel.orderFrontRegardless() }
    }

    func hideAll() {
        panels.values.forEach { $0.orderOut(nil) }
        panels.removeAll()
        frames.removeAll()
    }

    private func makePanel(for id: ObjectIdentifier) -> TabBarPanel {
        let p = TabBarPanel()
        p.tabView.onTabClicked = { [weak self] w in self?.onTabClicked?(w) }
        panels[id] = p
        return p
    }
}
