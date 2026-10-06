import AppKit
import ApplicationServices

/// Forces Finder windows into Column View by pressing Finder's own
/// "View ▸ as Columns" (⌘3) menu item through Accessibility.
///
/// Why not `defaults write ... FXPreferredViewStyle clmv`: per-folder view
/// settings stored in .DS_Store win over the global default. Why not AppleScript:
/// it needs an extra Automation (Apple Events) permission; the AX route only needs
/// Accessibility, which FinderPin already requires.
///
/// Finder disables its View menu items while it is not frontmost, so this only acts
/// on Finder's focused window while Finder is active (which is the case whenever a
/// new Finder window is opened or the user switches to Finder).
final class ColumnViewEnforcer {
    private weak var tracker: FinderTracker?
    private var cachedItem: AXUIElement?

    init(tracker: FinderTracker) {
        self.tracker = tracker
    }

    func enforceOnFocusedWindow() {
        guard let tracker, tracker.isFinderFrontmost, let app = tracker.appElement,
              let window = AX.element(app, kAXFocusedWindowAttribute),
              let id = AX.windowID(window), tracker.windows[id] != nil else { return }
        if isColumnView(window) { return }
        guard let item = columnsMenuItem(app) else {
            NSLog("[FinderPin] Column View menu item not found")
            return
        }
        let err = AX.perform(item, kAXPressAction)
        if err != .success {
            cachedItem = nil
            if let fresh = columnsMenuItem(app) { AX.perform(fresh, kAXPressAction) }
        }
        NSLog("[FinderPin] forced Column View on window \(id) (\(err.rawValue))")
    }

    func isColumnView(_ window: AXUIElement) -> Bool {
        AX.containsRole("AXBrowser", in: window, maxDepth: 6)
    }

    /// The View-menu item bound to plain ⌘3, identified by its shortcut rather than
    /// by its localized title ("as Columns" / "계층" / …).
    private func columnsMenuItem(_ app: AXUIElement) -> AXUIElement? {
        if let cachedItem, AX.string(cachedItem, kAXMenuItemCmdCharAttribute) == "3" { return cachedItem }
        guard let bar = AX.element(app, kAXMenuBarAttribute) else { return nil }
        for top in AX.children(bar) {
            for menu in AX.children(top) {
                let items = AX.children(menu)
                func plainCmd(_ e: AXUIElement) -> String? {
                    guard (AX.value(e, kAXMenuItemCmdModifiersAttribute) as? Int) == 0 else { return nil }
                    return AX.string(e, kAXMenuItemCmdCharAttribute)
                }
                let chars = Set(items.compactMap(plainCmd))
                // The view-style group is ⌘1…⌘4 in the same menu.
                guard chars.isSuperset(of: ["1", "2", "3"]) else { continue }
                if let item = items.first(where: { plainCmd($0) == "3" }) {
                    cachedItem = item
                    return item
                }
            }
        }
        return nil
    }
}
