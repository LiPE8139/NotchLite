import AppKit
import ApplicationServices

/// Toggles Apple Music's "Love" through its own menu command.
///
/// The scripting property `loved` only exists on library tracks — Apple Music streams report
/// themselves as `shared track` and reject it — but the app's *menu* command works for any track,
/// and we already hold Accessibility permission. The menu item's own title also tells us whether
/// the current track is loved, which is how the heart stays in sync.
enum AppleMusicLove {
    private static let loveTitles = ["喜爱", "喜欢", "Love", "Love…", "添加喜爱"]
    private static let unloveTitles = ["取消喜爱", "取消喜欢", "Unlove", "Remove from Loved"]

    private static func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private static func title(_ element: AXUIElement) -> String? {
        attribute(element, kAXTitleAttribute as String) as? String
    }

    private static func children(_ element: AXUIElement) -> [AXUIElement] {
        attribute(element, kAXChildrenAttribute as String) as? [AXUIElement] ?? []
    }

    /// The Love / Unlove menu item, whichever is currently present.
    static func loveMenuItem() -> (element: AXUIElement, isLoved: Bool)? {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").first
        else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        guard let menuBar = attribute(axApp, kAXMenuBarAttribute as String) else { return nil }

        var scanned: [String] = []
        // The Love command lives inside the Rating submenu on current Music versions, so walk one
        // level deeper instead of only looking at top-level items.
        func visit(_ element: AXUIElement, depth: Int) {
            for child in children(element) {
                guard let name = title(child) else {
                    if depth < 2 { visit(child, depth: depth + 1) }
                    continue
                }
                scanned.append(String(repeating: "  ", count: depth) + name)
                if unloveTitles.contains(name) { found = (child, true); return }
                if loveTitles.contains(name) { found = (child, false); return }
                if depth < 2, !children(child).isEmpty { visit(child, depth: depth + 1) }
            }
        }

        var found: (AXUIElement, Bool)?
        for barItem in children(menuBar as! AXUIElement) {
            visit(barItem, depth: 0)
            if let found { return found }
        }
        // Diagnostic: if the wording does not match, keep the actual menu titles around so the
        // lookup can be fixed without guessing. Written only on a miss.
        let report = "menu titles:\n" + scanned.joined(separator: "\n")
        try? Data(report.utf8).write(to: URL(fileURLWithPath: "/tmp/notchlite-menu.log"))
        return nil
    }

    /// Presses the menu command when Music exposes one.
    ///
    /// Note: current Music versions only carry star ratings in the Rating submenu — there is no
    /// Love item at all, and submenu contents are not materialised until a menu is opened. Rather
    /// than flashing menus open on every press, this only looks at what is already visible.
    @discardableResult
    static func press() -> Bool {
        guard let item = loveMenuItem() else { return false }
        return AXUIElementPerformAction(item.element, kAXPressAction as CFString) == .success
    }

    /// First menu item anywhere in the menu bar whose title matches.
    private static func firstMenuItem(titled names: [String]) -> AXUIElement? {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").first
        else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        guard let menuBar = attribute(axApp, kAXMenuBarAttribute as String) else { return nil }

        for barItem in children(menuBar as! AXUIElement) {
            for menu in children(barItem) {
                for item in children(menu) {
                    if let name = title(item), names.contains(name) { return item }
                }
            }
        }
        return nil
    }

    /// Current loved state, from the menu item's wording.
    static func isLoved() -> Bool? {
        loveMenuItem()?.isLoved
    }
}
