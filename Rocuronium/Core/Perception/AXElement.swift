import ApplicationServices
import Foundation

/// A safe wrapper over `AXUIElement`.
///
/// Every accessor here exists because the raw API misbehaves in a way that was measured rather
/// than assumed; see `Experiments/ghost-input/RESULTS.md`. The two rules this type enforces:
/// a messaging timeout on every element (a hung app must never hang the engine), and no
/// interpretation of a returned `AXError` as proof that anything happened.
nonisolated struct AXElement {
    let raw: AXUIElement

    private enum Constants {
        /// A wedged app blocks AX IPC indefinitely without this.
        static let messagingTimeout: Float = 2.0
    }

    init(_ raw: AXUIElement) {
        self.raw = raw
        AXUIElementSetMessagingTimeout(raw, Constants.messagingTimeout)
    }

    /// The application-level element for a process.
    init(pid: pid_t) {
        self.init(AXUIElementCreateApplication(pid))
    }

    // MARK: - Attributes

    func attribute(_ name: String) -> CFTypeRef? {
        var out: CFTypeRef?
        guard AXUIElementCopyAttributeValue(raw, name as CFString, &out) == .success else { return nil }
        return out
    }

    func string(_ name: String) -> String? { attribute(name) as? String }

    var role: String { string(kAXRoleAttribute) ?? "?" }
    var subrole: String? { string(kAXSubroleAttribute) }

    /// The most human-meaningful name available, in descending order of trustworthiness.
    /// Labels are frequently absent or wrong, so callers must treat this as a hint.
    /// Short-circuits: every attribute read is an IPC round trip, and building the full array
    /// fetched all four even when the title answered. Over a 5,000-element tree that is
    /// thousands of avoidable round trips.
    var label: String {
        for name in [
            kAXTitleAttribute, kAXDescriptionAttribute,
            kAXPlaceholderValueAttribute, kAXRoleDescriptionAttribute,
        ] {
            if let value = string(name), !value.isEmpty { return value }
        }
        return ""
    }

    var value: String? {
        guard let raw = attribute(kAXValueAttribute) else { return nil }
        if let text = raw as? String { return text }
        if let number = raw as? NSNumber { return number.stringValue }
        return nil
    }

    /// Casting to a CoreFoundation type performs **no** runtime check — the compiler even
    /// rejects `as?` here — so a wrong type is not caught, it is carried. Apps do return
    /// `kCFNull` for empty attributes, which would otherwise yield an element reporting role
    /// `"?"` with no frame, and the engine would say "exposes no press action" instead of
    /// "this app returned something that is not an element". Check the type id explicitly.
    private func axValue(_ name: String) -> AXValue? {
        guard let value = attribute(name), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        return (value as! AXValue)
    }

    var position: CGPoint? {
        guard let value = axValue(kAXPositionAttribute) else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(value, .cgPoint, &point) else { return nil }
        return point
    }

    var size: CGSize? {
        guard let value = axValue(kAXSizeAttribute) else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(value, .cgSize, &size) else { return nil }
        return size
    }

    /// Screen rectangle in the top-left origin space `CGEvent` also uses, so a frame can be
    /// handed straight to a synthetic click or a pixel diff without conversion.
    var frame: CGRect? {
        guard let position, let size else { return nil }
        return CGRect(origin: position, size: size)
    }

    var actionNames: [String] {
        var out: CFArray?
        guard AXUIElementCopyActionNames(raw, &out) == .success else { return [] }
        return (out as? [String]) ?? []
    }

    var children: [AXElement] {
        ((attribute(kAXChildrenAttribute) as? [AXUIElement]) ?? []).map(AXElement.init)
    }

    /// Windows come from `AXWindows`, which is not always the same set as `AXChildren` —
    /// some apps expose windows in only one of the two.
    var windows: [AXElement] {
        ((attribute(kAXWindowsAttribute) as? [AXUIElement]) ?? []).map(AXElement.init)
    }

    var menuBar: AXElement? {
        guard let bar = attribute(kAXMenuBarAttribute),
              CFGetTypeID(bar) == AXUIElementGetTypeID() else { return nil }
        return AXElement(bar as! AXUIElement)
    }

    /// The app's own idea of what is focused. Instant, and repeatedly finds elements that a
    /// tree walk misses entirely — Electron composer fields in particular.
    var focused: AXElement? {
        guard let element = attribute(kAXFocusedUIElementAttribute),
              CFGetTypeID(element) == AXUIElementGetTypeID() else { return nil }
        return AXElement(element as! AXUIElement)
    }

    var isEditable: Bool {
        ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"].contains(role)
    }

    // MARK: - Mutation

    /// Writes a value. **The returned error is not evidence**: WebKit content returns
    /// `.success` here while changing nothing, so callers must read back and compare.
    @discardableResult
    func setValue(_ text: String) -> AXError {
        AXUIElementSetAttributeValue(raw, kAXValueAttribute as CFString, text as CFString)
    }

    @discardableResult
    func perform(_ action: String = kAXPressAction) -> AXError {
        AXUIElementPerformAction(raw, action as CFString)
    }

    /// Chromium builds its accessibility tree lazily. Setting this asks it to build the full
    /// tree up front. Harmless elsewhere, and worth doing once per Chromium app — but it is
    /// not what unlocks Electron on its own; traversal depth is (see `ElementQuery`).
    @discardableResult
    func enableManualAccessibility() -> AXError {
        AXUIElementSetAttributeValue(raw, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    /// A stable-enough identity for deduping results. `CFEqual` on `AXUIElement` is usable
    /// when the display is awake but degenerates along with everything else when it is not,
    /// so results are collapsed on what they look like instead of on object identity.
    var signature: String {
        let origin = position.map { "\(Int($0.x)),\(Int($0.y))" } ?? "-"
        let extent = size.map { "\(Int($0.width))x\(Int($0.height))" } ?? "-"
        return "\(role)|\(label)|\(origin)|\(extent)"
    }
}
