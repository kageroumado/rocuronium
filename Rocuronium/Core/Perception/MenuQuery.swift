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

        /// The character an item reports in `AXMenuItemCmdChar` for a named key when it
        /// carries no `AXMenuItemCmdVirtualKey` — the AppKit function-key range for arrows
        /// and friends, a control character for the rest.
        let functionCharacter: String?

        static let shiftBit = 1

        /// Keys that carry no command character and match by virtual keycode instead.
        /// Shared with the `key` verb, which posts these same keycodes as bare keystrokes.
        static let namedKeys: [String: Int] = [
            "return": 0x24, "enter": 0x24, "tab": 0x30, "space": 0x31,
            "delete": 0x33, "backspace": 0x33, "escape": 0x35, "esc": 0x35,
            "left": 0x7B, "right": 0x7C, "down": 0x7D, "up": 0x7E,
            "home": 0x73, "end": 0x77, "pageup": 0x74, "pagedown": 0x79,
            "forwarddelete": 0x75,
            "f1": 0x7A, "f2": 0x78, "f3": 0x63, "f4": 0x76, "f5": 0x60, "f6": 0x61,
            "f7": 0x62, "f8": 0x64, "f9": 0x65, "f10": 0x6D, "f11": 0x67, "f12": 0x6F,
        ]

        /// `NSUpArrowFunctionKey` and its siblings, as menu items report them.
        static let functionCharacters: [String: Unicode.Scalar] = [
            "up": "\u{F700}", "down": "\u{F701}", "left": "\u{F702}", "right": "\u{F703}",
            "f1": "\u{F704}", "f2": "\u{F705}", "f3": "\u{F706}", "f4": "\u{F707}",
            "f5": "\u{F708}", "f6": "\u{F709}", "f7": "\u{F70A}", "f8": "\u{F70B}",
            "f9": "\u{F70C}", "f10": "\u{F70D}", "f11": "\u{F70E}", "f12": "\u{F70F}",
            "forwarddelete": "\u{F728}", "home": "\u{F729}", "end": "\u{F72B}",
            "pageup": "\u{F72C}", "pagedown": "\u{F72D}",
            "return": "\r", "enter": "\r", "tab": "\t", "space": " ",
            "delete": "\u{8}", "backspace": "\u{8}", "escape": "\u{1B}", "esc": "\u{1B}",
        ]

        /// Spelled-out punctuation, for callers (and shells) that would rather not type the
        /// symbol: `cmd+plus`, `cmd+minus`, `cmd+comma`.
        static let characterNames: [String: String] = [
            "plus": "+", "minus": "-", "hyphen": "-", "equal": "=", "equals": "=",
            "comma": ",", "period": ".", "dot": ".", "slash": "/", "backslash": "\\",
            "semicolon": ";", "colon": ":", "quote": "'", "apostrophe": "'",
            "backtick": "`", "grave": "`", "leftbracket": "[", "bracketleft": "[",
            "rightbracket": "]", "bracketright": "]", "underscore": "_", "question": "?",
        ]

        /// The unshifted → shifted pairs that share a physical key on the ANSI layout. A
        /// menu item names its key by the character it produces, and apps disagree on which
        /// half they store: Safari, Preview and Ghostty all carry "zoom in" as `+` with
        /// modifiers 0 (no shift bit), while the keystroke a person means by it is ⌘=.
        static let shiftedCounterpart: [String: String] = [
            "=": "+", "-": "_", ",": "<", ".": ">", "/": "?", ";": ":", "'": "\"",
            "`": "~", "[": "{", "]": "}", "\\": "|",
            "1": "!", "2": "@", "3": "#", "4": "$", "5": "%",
            "6": "^", "7": "&", "8": "*", "9": "(", "0": ")",
        ]

        /// Parses "cmd+a", "cmd+shift+z", "cmd+left", "cmd+=", "cmd++", "cmd+plus". Returns
        /// nil for no key or no such modifier. "+" separates tokens, so a trailing "++"
        /// ("cmd++", zoom) — or a lone "+" — is the plus key itself.
        static func parse(_ text: String) -> Shortcut? {
            guard let (key, mask) = tokenize(text) else { return nil }
            if let keycode = namedKeys[key] {
                return Shortcut(
                    character: nil, virtualKey: keycode, modifiers: mask,
                    functionCharacter: functionCharacters[key].map { String(Character($0)) },
                )
            }
            let character = characterNames[key] ?? key
            guard character.count == 1 else { return nil }
            return Shortcut(character: character.uppercased(), virtualKey: nil, modifiers: mask, functionCharacter: nil)
        }

        /// Splits a chord into its key token (lowercased) and the Carbon modifier mask.
        static func tokenize(_ text: String) -> (key: String, mask: Int)? {
            let lowered = text.lowercased().trimmingCharacters(in: .whitespaces)
            var tokens = lowered.split(separator: "+", omittingEmptySubsequences: true).map(String.init)
            if lowered == "+" || lowered.hasSuffix("++") { tokens.append("+") }
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
            return (key, (command ? 0 : 8) + (shift ? shiftBit : 0) + (option ? 2 : 0) + (control ? 4 : 0))
        }

        /// The (character, modifier mask) encodings a menu item may use for this chord, best
        /// first. The exact spelling always wins; after it come the encodings of the *same
        /// physical key*: `cmd+=` also finds an item stored as `+` (shift implied by the
        /// character), and `cmd++` / `cmd+shift+=` find one stored as `=` with the shift bit.
        var characterCandidates: [(character: String, modifiers: Int)] {
            guard let character else { return [] }
            let unshifted = modifiers & ~Self.shiftBit
            var candidates = [(character, modifiers)]
            if let shifted = Self.shiftedCounterpart[character] {
                candidates.append((shifted, unshifted))
            }
            if let base = Self.shiftedCounterpart.first(where: { $0.value == character })?.key {
                candidates.append((character, unshifted))
                candidates.append((base, modifiers | Self.shiftBit))
            }
            var seen = Set<String>()
            return candidates.filter { seen.insert("\($0.0)\u{1}\($0.1)").inserted }
        }

        /// How well a menu item's key equivalent matches: 0 is exact, higher is a looser
        /// encoding of the same key, nil is no match. Pure, so it is tested on raw values.
        func rank(itemCharacter: String?, itemModifiers: Int?, itemVirtualKey: Int?) -> Int? {
            guard let itemModifiers else { return nil }
            if let virtualKey {
                guard itemModifiers == modifiers else { return nil }
                if itemVirtualKey == virtualKey { return 0 }
                if let functionCharacter, itemCharacter == functionCharacter { return 1 }
                return nil
            }
            guard let itemCharacter = itemCharacter?.uppercased(), !itemCharacter.isEmpty else { return nil }
            return characterCandidates.firstIndex {
                $0.character == itemCharacter && $0.modifiers == itemModifiers
            }
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
        /// menu, so `shortcut --app TextEdit --keys cmd+shift+q` resolves to "Log Out <user>…"
        /// and `cmd+opt+shift+q` to the variant that logs out *without* a confirmation dialog.
        /// An agent reaching for a text shortcut can end the user's session from any target.
        /// `type` already refuses a bare newline for the same reason — a verb that can send or
        /// destroy must say so before it acts, not report it afterwards.
        ///
        /// Session-wide consequences live only in the Apple menu, so those patterns check the
        /// path's first component — an app menu's "Restart to Update" restarts the *app*, and
        /// flagging it as "would reboot the Mac" (measured on Refrax 2026-08-09) teaches
        /// callers to pass confirm reflexively, which defeats the rail. Data-destroying
        /// patterns stay global: "Move to Trash" is hazardous wherever it appears.
        ///
        /// Quit is deliberately absent: it is app-scoped, ordinary, and the app's own
        /// save prompts still apply. This list is for the session and the filesystem.
        var hazard: String? {
            let title = path.lowercased()
            let inAppleMenu = path.components(separatedBy: " ▸ ").first == "Apple"
            if inAppleMenu {
                let sessionPatterns = [
                    "log out": "would end the login session",
                    "shut down": "would power off the Mac",
                    "restart": "would reboot the Mac",
                    "sleep": "would put the Mac to sleep",
                    "lock screen": "would lock the screen",
                ]
                for (needle, consequence) in sessionPatterns where title.contains(needle) {
                    return consequence
                }
            }
            let dataPatterns = [
                "empty trash": "would permanently delete the Trash",
                "move to trash": "would delete the selected items",
                "erase": "would erase data",
            ]
            for (needle, consequence) in dataPatterns where title.contains(needle) {
                return consequence
            }
            return nil
        }
    }

    /// Finds the menu item carrying this shortcut. The tree is readable while every menu is
    /// closed, so nothing flashes on screen. The first exact match wins, matching what the
    /// real keystroke would trigger; failing that, the first item carrying the same physical
    /// key in a looser encoding (see `Shortcut.characterCandidates`).
    static func item(for shortcut: Shortcut, in menuBar: AXElement) -> Match? {
        var visited = 0
        var best: (rank: Int, match: Match)?
        search(menuBar, shortcut: shortcut, path: [], depth: 0, visited: &visited, best: &best)
        return best?.match
    }

    /// Every menu item that carries the chord in any of its encodings, and whether the walk
    /// stopped at its cap first. For the hazard rail, which must not judge a chord by its
    /// best-ranked item alone: key-equivalent dispatch may fire another encoding, and a
    /// truncated walk has not seen every item.
    static func allItems(for shortcut: Shortcut, in menuBar: AXElement) -> (matches: [Match], truncated: Bool) {
        var visited = 0
        var matches: [Match] = []
        collect(menuBar, shortcut: shortcut, path: [], depth: 0, visited: &visited, matches: &matches)
        return (matches, visited > Constants.maximumItemsVisited)
    }

    private static func collect(
        _ element: AXElement, shortcut: Shortcut, path: [String], depth: Int, visited: inout Int,
        matches: inout [Match]
    ) {
        guard depth <= Constants.maximumDepth else { return }
        for child in element.children {
            visited += 1
            guard visited <= Constants.maximumItemsVisited else { return }
            let title = child.string(kAXTitleAttribute) ?? ""
            if child.role == "AXMenuItem", rank(child, shortcut) != nil {
                matches.append(Match(
                    element: child,
                    path: (path + [title]).filter { !$0.isEmpty }.joined(separator: " ▸ "),
                    enabled: (child.attribute(kAXEnabledAttribute) as? Bool) ?? true,
                ))
                continue
            }
            collect(
                child, shortcut: shortcut,
                path: title.isEmpty || child.role == "AXMenu" ? path : path + [title],
                depth: depth + 1, visited: &visited, matches: &matches,
            )
        }
    }

    // MARK: - Path matching

    /// Splits "File ▸ Export…" (or "File > Export") into components. Both separators are
    /// accepted because "▸" is what this tool prints and ">" is what a human types.
    static func parsePath(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == ">" || $0 == "▸" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// How a path lookup ended. Failure carries what *was* at the failing level, because the
    /// caller is an agent guessing menu titles from memory — the fix is in the listing.
    enum PathResolution {
        case found(Match)
        case notFound(component: String, available: [String])
        /// The path names a submenu container. Pressing one only opens it visually — it runs
        /// nothing — so it is refused, with its items listed so the caller can go one deeper.
        case submenu(path: String, items: [String])
    }

    /// Resolves a title path level by level. Matching is case-insensitive and ignores a
    /// trailing ellipsis, so "File > Export" finds "Export…" without the caller typing "…".
    static func item(atPath components: [String], in menuBar: AXElement) -> PathResolution {
        var current = menuBar
        var canonical: [String] = []
        for component in components {
            let wanted = normalize(component)
            let candidates = menuChildren(of: current)
            guard let match = candidates.first(where: {
                normalize($0.string(kAXTitleAttribute) ?? "") == wanted
            }) else {
                return .notFound(
                    component: component,
                    available: candidates
                        .compactMap { $0.string(kAXTitleAttribute) }
                        .filter { !$0.isEmpty },
                )
            }
            canonical.append(match.string(kAXTitleAttribute) ?? component)
            current = match
        }
        let path = canonical.joined(separator: " ▸ ")
        let below = menuChildren(of: current)
        guard current.role == "AXMenuItem", below.isEmpty else {
            return .submenu(
                path: path,
                items: below.compactMap { $0.string(kAXTitleAttribute) }.filter { !$0.isEmpty },
            )
        }
        let enabled = (current.attribute(kAXEnabledAttribute) as? Bool) ?? true
        return .found(Match(element: current, path: path, enabled: enabled))
    }

    /// The pressable/openable things one level down. Menu bars hold `AXMenuBarItem`s
    /// directly; menu bar items and submenu items interpose a single `AXMenu` whose children
    /// are the actual items — that wrapper is transparent to a human reading the menu, so it
    /// is transparent to path matching too.
    private static func menuChildren(of element: AXElement) -> [AXElement] {
        let children = element.children
        if children.count == 1, children[0].role == "AXMenu" {
            return children[0].children
        }
        return children
    }

    private static func normalize(_ title: String) -> String {
        var text = title.trimmingCharacters(in: .whitespaces)
        while text.hasSuffix("…") || text.hasSuffix("...") {
            text.removeLast(text.hasSuffix("…") ? 1 : 3)
            text = text.trimmingCharacters(in: .whitespaces)
        }
        return text.lowercased()
    }

    /// Walks the menu keeping the best-ranked match; stops early only on an exact one.
    private static func search(
        _ element: AXElement, shortcut: Shortcut, path: [String], depth: Int, visited: inout Int,
        best: inout (rank: Int, match: Match)?
    ) {
        guard depth <= Constants.maximumDepth else { return }
        for child in element.children {
            if best?.rank == 0 { return }
            // The cap must gate every child, not just recursion entry: one pathologically
            // wide container would otherwise be walked in full, each item costing AX IPC.
            visited += 1
            guard visited <= Constants.maximumItemsVisited else { return }
            let title = child.string(kAXTitleAttribute) ?? ""
            if child.role == "AXMenuItem", let rank = rank(child, shortcut), rank < (best?.rank ?? .max) {
                let enabled = (child.attribute(kAXEnabledAttribute) as? Bool) ?? true
                best = (rank, Match(
                    element: child,
                    path: (path + [title]).filter { !$0.isEmpty }.joined(separator: " ▸ "),
                    enabled: enabled,
                ))
                continue
            }
            // Containers (AXMenuBarItem, AXMenu, submenu items) carry the title path;
            // bare AXMenus repeat their parent's title, which the isEmpty filter drops.
            search(
                child, shortcut: shortcut,
                path: title.isEmpty || child.role == "AXMenu" ? path : path + [title],
                depth: depth + 1, visited: &visited, best: &best,
            )
        }
    }

    private static func rank(_ item: AXElement, _ shortcut: Shortcut) -> Int? {
        guard let modifiers = (item.attribute("AXMenuItemCmdModifiers") as? NSNumber)?.intValue else { return nil }
        return shortcut.rank(
            itemCharacter: item.string("AXMenuItemCmdChar"),
            itemModifiers: modifiers,
            itemVirtualKey: (item.attribute("AXMenuItemCmdVirtualKey") as? NSNumber)?.intValue,
        )
    }
}
