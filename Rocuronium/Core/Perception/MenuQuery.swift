import ApplicationServices
import Foundation

/// Keyboard shortcuts delivered by pressing the matching **menu item**, not by posting keys.
///
/// This exists because of a measured Chromium limitation: keycode-only posted events are
/// ignored entirely, so Cmd+A never arrives as a key. But menus are native AppKit even in
/// Electron, and `AXPress` on a menu item runs the same action the keystroke would — so the
/// shortcut becomes reachable with no CGEvent at all, on every toolkit, without touching
/// focus. (Technique observed in Codex's shipped implementation, via `AXMenuItemCmdVirtualKey`.)
nonisolated enum MenuQuery {
    private enum Constants {
        /// Menu trees are shallow; the cap bounds IPC on pathological apps.
        static let maximumDepth = 6
        static let maximumItemsVisited = 3000
    }

    // MARK: - Shortcut parsing

    /// A parsed "cmd+shift+a". Matching uses the same encoding menu items expose:
    /// a command character (or virtual keycode for keys that have none) plus the Carbon
    /// modifier mask, where **0 means plain Cmd** and bit 3 means "no Cmd at all".
    struct Shortcut {
        let character: String?
        let virtualKey: Int?
        /// Carbon menu modifier mask: shift = 1, option = 2, control = 4, no-command = 8.
        let modifiers: Int

        /// Keys that carry no command character and match by virtual keycode instead.
        private static let namedKeys: [String: Int] = [
            "return": 0x24, "enter": 0x24, "tab": 0x30, "space": 0x31,
            "delete": 0x33, "backspace": 0x33, "escape": 0x35, "esc": 0x35,
            "left": 0x7B, "right": 0x7C, "down": 0x7D, "up": 0x7E,
        ]

        /// Parses "cmd+a", "cmd+shift+z", "cmd+left". Returns nil for no key or no such
        /// modifier. A trailing "+" ("cmd++", zoom) is the plus key itself.
        static func parse(_ text: String) -> Shortcut? {
            var tokens = text.lowercased().split(separator: "+", omittingEmptySubsequences: true).map(String.init)
            if text.hasSuffix("++") { tokens.append("+") }
            guard let key = tokens.popLast() else { return nil }

            var command = false, shift = false, option = false, control = false
            for token in tokens {
                switch token {
                case "cmd", "command", "⌘": command = true
                case "shift", "⇧": shift = true
                case "opt", "option", "alt", "⌥": option = true
                case "ctrl", "control", "⌃": control = true
                default: return nil
                }
            }
            let mask = (command ? 0 : 8) + (shift ? 1 : 0) + (option ? 2 : 0) + (control ? 4 : 0)

            if let keycode = namedKeys[key] {
                return Shortcut(character: nil, virtualKey: keycode, modifiers: mask)
            }
            guard key.count == 1 else { return nil }
            return Shortcut(character: key.uppercased(), virtualKey: nil, modifiers: mask)
        }
    }

    // MARK: - Menu walk

    struct Match {
        let element: AXElement
        /// "Edit ▸ Select All" — for the evidence, so the caller sees which item acted.
        let path: String
        let enabled: Bool

        /// Whether pressing this would do something no read-back could undo.
        ///
        /// The need is concrete and was measured: **every** app's menu bar carries the Apple
        /// menu, so `shortcut --app TextEdit --keys cmd+shift+q` resolves to "Log Out Kirie…"
        /// and `cmd+opt+shift+q` to the variant that logs out *without* a confirmation dialog.
        /// An agent reaching for a text shortcut can end the user's session from any target.
        /// `type` already refuses a bare newline for the same reason — a verb that can send or
        /// destroy must say so before it acts, not report it afterwards.
        ///
        /// Quit is deliberately absent: it is app-scoped, ordinary, and the app's own
        /// save prompts still apply. This list is for the session and the filesystem.
        var hazard: String? {
            let title = path.lowercased()
            let patterns = [
                "log out": "would end the login session",
                "shut down": "would power off the Mac",
                "restart": "would reboot the Mac",
                "sleep": "would put the Mac to sleep",
                "lock screen": "would lock the screen",
                "empty trash": "would permanently delete the Trash",
                "move to trash": "would delete the selected items",
                "erase": "would erase data",
            ]
            for (needle, consequence) in patterns where title.contains(needle) {
                return consequence
            }
            return nil
        }
    }

    /// Finds the menu item carrying this shortcut. The tree is readable while every menu is
    /// closed, so nothing flashes on screen. First match wins, matching what the real
    /// keystroke would trigger.
    static func item(for shortcut: Shortcut, in menuBar: AXElement) -> Match? {
        var visited = 0
        return search(menuBar, shortcut: shortcut, path: [], depth: 0, visited: &visited)
    }

    private static func search(
        _ element: AXElement, shortcut: Shortcut, path: [String], depth: Int, visited: inout Int
    ) -> Match? {
        guard depth <= Constants.maximumDepth else { return nil }
        for child in element.children {
            // The cap must gate every child, not just recursion entry: one pathologically
            // wide container would otherwise be walked in full, each item costing AX IPC.
            visited += 1
            guard visited <= Constants.maximumItemsVisited else { return nil }
            let title = child.string(kAXTitleAttribute) ?? ""
            if child.role == "AXMenuItem", matches(child, shortcut) {
                let enabled = (child.attribute(kAXEnabledAttribute) as? Bool) ?? true
                return Match(
                    element: child,
                    path: (path + [title]).filter { !$0.isEmpty }.joined(separator: " ▸ "),
                    enabled: enabled,
                )
            }
            // Containers (AXMenuBarItem, AXMenu, submenu items) carry the title path;
            // bare AXMenus repeat their parent's title, which the isEmpty filter drops.
            if let found = search(
                child, shortcut: shortcut,
                path: title.isEmpty || child.role == "AXMenu" ? path : path + [title],
                depth: depth + 1, visited: &visited,
            ) { return found }
        }
        return nil
    }

    private static func matches(_ item: AXElement, _ shortcut: Shortcut) -> Bool {
        let modifiers = (item.attribute("AXMenuItemCmdModifiers") as? NSNumber)?.intValue
        guard modifiers == shortcut.modifiers else { return false }
        if let character = shortcut.character {
            return item.string("AXMenuItemCmdChar")?.uppercased() == character
        }
        if let virtualKey = shortcut.virtualKey {
            return (item.attribute("AXMenuItemCmdVirtualKey") as? NSNumber)?.intValue == virtualKey
        }
        return false
    }
}
