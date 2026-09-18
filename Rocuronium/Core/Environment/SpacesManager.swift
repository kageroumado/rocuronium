import ApplicationServices
import CoreGraphics
import Foundation

// The SkyLight/CoreGraphicsServices Spaces API — the same private-API footing rocuronium
// already stands on for `CGVirtualDisplay`, bound here with `@_silgen_name` rather than a
// bridging header because these are free C functions, not ObjC classes. Undocumented and
// version-sensitive: every call degrades to an empty/failed result rather than trusting a
// return, and the managed-spaces plist is read defensively (its key names have drifted across
// releases, so several are tried).
//
// Real Spaces are what you want for *testing* an app across Spaces; the virtual display remains
// the answer for invisible agent work, because switching a Space changes what the human sees.

private typealias CGSConnectionID = Int32

@_silgen_name("CGSMainConnectionID")
private func CGSMainConnectionID() -> CGSConnectionID

@_silgen_name("CGSCopyManagedDisplaySpaces")
private func CGSCopyManagedDisplaySpaces(_ cid: CGSConnectionID) -> Unmanaged<CFArray>?

@_silgen_name("CGSManagedDisplaySetCurrentSpace")
private func CGSManagedDisplaySetCurrentSpace(_ cid: CGSConnectionID, _ display: CFString, _ space: UInt64)

@_silgen_name("CGSAddWindowsToSpaces")
private func CGSAddWindowsToSpaces(_ cid: CGSConnectionID, _ windows: CFArray, _ spaces: CFArray)

@_silgen_name("CGSRemoveWindowsFromSpaces")
private func CGSRemoveWindowsFromSpaces(_ cid: CGSConnectionID, _ windows: CFArray, _ spaces: CFArray)

// The CGWindowID behind an AXUIElement — the handle CGS windows-to-spaces calls take. Private,
// and the only route from an accessibility element to the window-server id.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ identifier: UnsafeMutablePointer<CGWindowID>) -> AXError

nonisolated enum SpacesManager {
    /// One Space on one display.
    struct Space: Sendable {
        let id: UInt64
        /// 1-based position among its display's spaces — the number a human counts.
        let index: Int
        let isActive: Bool
        /// CGS space type: 0 user, 4 fullscreen-app, 2 system. Reported raw plus a label guess.
        let kind: String
    }

    /// One display's Spaces, in order, with the display's CGS identifier (what a switch takes).
    struct DisplaySpaces: Sendable {
        let displayIdentifier: String
        /// 1-based display position, for the reply.
        let displayIndex: Int
        let spaces: [Space]
    }

    private static func kindLabel(_ type: Int) -> String {
        switch type {
        case 0: "user"
        case 4: "fullscreen"
        case 2: "system"
        default: "type \(type)"
        }
    }

    /// Reads a space dictionary's id, trying the key names macOS has used across releases.
    private static func spaceID(_ dict: [String: Any]) -> UInt64? {
        for key in ["ManagedSpaceID", "id64", "id"] {
            if let number = dict[key] as? NSNumber { return number.uint64Value }
        }
        return nil
    }

    /// Every Space, grouped by display, active one marked. Read-only.
    static func list() -> [DisplaySpaces] {
        let cid = CGSMainConnectionID()
        guard let raw = CGSCopyManagedDisplaySpaces(cid)?.takeRetainedValue() as? [[String: Any]] else {
            return []
        }
        return raw.enumerated().compactMap { displayIndex, display in
            let identifier = display["Display Identifier"] as? String ?? "?"
            let currentID = (display["Current Space"] as? [String: Any]).flatMap(spaceID)
            let entries = (display["Spaces"] as? [[String: Any]]) ?? []
            let spaces = entries.enumerated().compactMap { index, entry -> Space? in
                guard let id = spaceID(entry) else { return nil }
                let type = (entry["type"] as? NSNumber)?.intValue ?? 0
                return Space(id: id, index: index + 1, isActive: id == currentID, kind: kindLabel(type))
            }
            return DisplaySpaces(displayIdentifier: identifier, displayIndex: displayIndex + 1, spaces: spaces)
        }
    }

    enum SwitchError: Error, LocalizedError {
        case noSpaces
        case notFound(UInt64)
        case noNeighbour(String)

        var errorDescription: String? {
            switch self {
            case .noSpaces: "the Spaces API returned nothing — Mission Control may be mid-transition"
            case let .notFound(id): "no Space with id \(id) on any display"
            case let .noNeighbour(direction): "no Space \(direction) the active one on this display"
            }
        }
    }

    /// The display holding a given space, and that space.
    private static func locate(_ id: UInt64) -> (DisplaySpaces, Space)? {
        for display in list() {
            if let space = display.spaces.first(where: { $0.id == id }) { return (display, space) }
        }
        return nil
    }

    /// Switches the display that owns `id` to that Space. The one action here that changes what
    /// the human sees, so the router gates it like `activate`.
    static func switchTo(id: UInt64) throws {
        guard let (display, _) = locate(id) else { throw SwitchError.notFound(id) }
        CGSManagedDisplaySetCurrentSpace(CGSMainConnectionID(), display.displayIdentifier as CFString, id)
    }

    /// The Space one step in `direction` (+1 next, −1 previous) from the active one on the main
    /// display, wrapping is refused — an edge is an edge. Returns the resolved id.
    static func neighbour(_ direction: Int) throws -> UInt64 {
        guard let display = list().first else { throw SwitchError.noSpaces }
        guard let activeIndex = display.spaces.firstIndex(where: { $0.isActive }) else {
            throw SwitchError.noSpaces
        }
        let target = activeIndex + direction
        guard display.spaces.indices.contains(target) else {
            throw SwitchError.noNeighbour(direction > 0 ? "after" : "before")
        }
        return display.spaces[target].id
    }

    /// The CGWindowID for an accessibility element, or nil when the private call refuses.
    static func windowID(of element: AXUIElement) -> CGWindowID? {
        var identifier: CGWindowID = 0
        return _AXUIElementGetWindow(element, &identifier) == .success && identifier != 0 ? identifier : nil
    }

    /// Moves a window to another Space without switching to it — non-disruptive to the current
    /// view. Adds to the destination, then removes from every other Space, so the window lands
    /// on exactly one.
    static func move(windowID: CGWindowID, toSpace id: UInt64) throws {
        guard locate(id) != nil else { throw SwitchError.notFound(id) }
        let cid = CGSMainConnectionID()
        let windows = [NSNumber(value: windowID)] as CFArray
        CGSAddWindowsToSpaces(cid, windows, [NSNumber(value: id)] as CFArray)
        // Remove from the others so the window is not left duplicated across Spaces.
        let others = list().flatMap(\.spaces).map(\.id).filter { $0 != id }
        if !others.isEmpty {
            CGSRemoveWindowsFromSpaces(cid, windows, others.map { NSNumber(value: $0) } as CFArray)
        }
    }
}
