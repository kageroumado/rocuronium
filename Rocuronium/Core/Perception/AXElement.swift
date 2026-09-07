import ApplicationServices
import Foundation

/// A safe wrapper over `AXUIElement`.
///
/// Every accessor here exists because the raw API misbehaves in a way that was measured rather
/// than assumed. The two rules this type enforces:
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

    /// The `AXError` from reading an attribute, or `nil` on success. `attribute` collapses every
    /// failure to a nil value, which erases the one distinction a walk needs at its root:
    /// `.cannotComplete` (the app did not answer within the messaging timeout — it is busy or
    /// wedged) versus `.noValue` (the attribute is legitimately absent).
    func attributeError(_ name: String) -> AXError? {
        var out: CFTypeRef?
        let code = AXUIElementCopyAttributeValue(raw, name as CFString, &out)
        return code == .success ? nil : code
    }

    /// Whether the app answers accessibility queries at all. A single probe of the app-level
    /// element: `.cannotComplete` is the timeout a wedged-but-awake app produces, and every other
    /// outcome — `.noValue` and success included — means the app responded. Walk entry checks this
    /// so an app that never answered is reported as busy rather than as an empty tree.
    var isResponding: Bool {
        attributeError(kAXRoleAttribute) != .cannotComplete
    }

    func string(_ name: String) -> String? { attribute(name) as? String }

    var role: String { string(kAXRoleAttribute) ?? "?" }
    var subrole: String? { string(kAXSubroleAttribute) }

    /// The most human-meaningful name available, in descending order of trustworthiness.
    /// Labels are frequently absent or wrong, so callers must treat this as a hint.
    /// Short-circuits: every attribute read is an IPC round trip, and building the full array
    /// would fetch all four even when the title answers. Over a 5,000-element tree that is
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

    /// The element's own name — title, description, or placeholder — and never the role
    /// description. `label` falls back to the role description because matching benefits from
    /// it, but a row reported to the caller must not: an unlabelled button whose `title` is
    /// empty is a different fact from one titled with the literal word its kind happens to be,
    /// and only `title` can tell them apart. Empty when the element carries no name of its own.
    var title: String {
        for name in [kAXTitleAttribute, kAXDescriptionAttribute, kAXPlaceholderValueAttribute] {
            if let value = string(name), !value.isEmpty { return value }
        }
        return ""
    }

    /// The system's human phrase for the element's kind — "button", "text field", "close
    /// button". Its own field so it never masquerades as a title in a reported row.
    var roleDescription: String? {
        let value = string(kAXRoleDescriptionAttribute)
        return (value?.isEmpty ?? true) ? nil : value
    }

    /// Tooltip text (`AXHelp`), readable without hovering — often the only name an icon-only
    /// control carries, which is what makes this the cheap half of closing the icon-only gap.
    var help: String? {
        let value = string(kAXHelpAttribute)
        return (value?.isEmpty ?? true) ? nil : value
    }

    /// `AXIdentifier`: SwiftUI fills it from `accessibilityIdentifier`, and AppKit often
    /// leaves it as the control's symbol name — a stable handle when the title is absent.
    var identifier: String? {
        let value = string(kAXIdentifierAttribute)
        return (value?.isEmpty ?? true) ? nil : value
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

    /// The action that "clicks" this element: `AXPress` where offered, else `AXShowMenu`.
    ///
    /// Menu buttons (`AXMenuButton`, and the remote elements System Settings panes host in
    /// `AXOpaqueProviderGroup`s) expose only `AXShowMenu` — a plain press-only check reported
    /// "element exposes no press action" for a control a human clicks like any button
    /// (measured on the Wallpaper pane's "Add Video", 2026-08-20). Nil means neither exists.
    var pressishAction: String? {
        let names = actionNames
        if names.contains(kAXPressAction) { return kAXPressAction }
        if names.contains(kAXShowMenuAction) { return kAXShowMenuAction }
        return nil
    }

    /// `AXShowMenu` when the element exposes it — the cursor-free way to open a context menu,
    /// which is what a right-click asks for. Nil when the element has no such action, so the
    /// caller falls through to a posted right-click.
    var showMenuAction: String? {
        actionNames.contains(kAXShowMenuAction) ? kAXShowMenuAction : nil
    }

    var children: [AXElement] {
        ((attribute(kAXChildrenAttribute) as? [AXUIElement]) ?? []).map(AXElement.init)
    }

    /// Windows come from `AXWindows`, which is not always the same set as `AXChildren` —
    /// some apps expose windows in only one of the two.
    var windows: [AXElement] {
        ((attribute(kAXWindowsAttribute) as? [AXUIElement]) ?? []).map(AXElement.init)
    }

    /// One step up the ancestor chain. Used to recognize containment (web areas) — not to
    /// hand elements around, which stays forbidden.
    var parent: AXElement? {
        guard let value = attribute(kAXParentAttribute),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return AXElement(value as! AXUIElement)
    }

    /// The window the app considers primary, which is a better default target than
    /// `windows.first` — that ordering is arbitrary and can surface a palette or an
    /// inspector ahead of the document.
    var mainWindow: AXElement? {
        guard let window = attribute(kAXMainWindowAttribute),
              CFGetTypeID(window) == AXUIElementGetTypeID() else { return nil }
        return AXElement(window as! AXUIElement)
    }

    var menuBar: AXElement? {
        guard let bar = attribute(kAXMenuBarAttribute),
              CFGetTypeID(bar) == AXUIElementGetTypeID() else { return nil }
        return AXElement(bar as! AXUIElement)
    }

    /// The menu bar's right-hand side: the app's status items (`NSStatusItem`s) live here, in
    /// a separate bar the ordinary window walk never reaches. Each child is an
    /// `AXMenuBarItem` with a real on-screen frame — unlike closed menu items — and `AXPress`
    /// on one opens its menu or popover.
    var extrasMenuBar: AXElement? {
        guard let bar = attribute("AXExtrasMenuBar"),
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

    /// The current selection in a text element. The read-back channel for menu commands that
    /// act on selection (Select All and friends), which otherwise have no readable effect.
    var selectedText: String? { string(kAXSelectedTextAttribute) }

    /// The value as a number — scroll bars report their position this way, 0 to 1.
    var numberValue: Double? {
        (attribute(kAXValueAttribute) as? NSNumber)?.doubleValue
    }

    /// The element's vertical scroll bar, on scroll areas that expose one. Its `numberValue`
    /// is normalized position: 0 at the top, 1 at the bottom.
    var verticalScrollBar: AXElement? {
        guard let bar = attribute(kAXVerticalScrollBarAttribute),
              CFGetTypeID(bar) == AXUIElementGetTypeID() else { return nil }
        return AXElement(bar as! AXUIElement)
    }

    /// Writes a numeric value. Same rule as the string overload: the return code is not
    /// evidence, and callers read back.
    @discardableResult
    func setValue(_ number: Double) -> AXError {
        mutate { AXUIElementSetAttributeValue(raw, kAXValueAttribute as CFString, NSNumber(value: number)) }
    }

    var isEditable: Bool {
        ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"].contains(role)
    }

    // MARK: - Mutation

    /// Runs a mutating AX call, hopped to the main thread when the target is **this
    /// process**. Same-process accessibility requests are not IPC'd — they execute
    /// synchronously on the calling thread — and SwiftUI's action/set handlers assert the
    /// main actor, so a self-targeted press from the engine's thread is a guaranteed
    /// SIGTRAP (measured: clicking the demo stage's own button crashed the app). Reads
    /// stay direct: they dispatch no handlers, and the walk over our own windows works.
    /// The main.sync is deadlock-free here because callers on the engine executor never
    /// have the main thread blocked waiting on them — the router *awaits* the engine, and
    /// an awaiting MainActor is suspended, not blocked.
    private func mutate(_ call: () -> AXError) -> AXError {
        var targetPid: pid_t = 0
        if AXUIElementGetPid(raw, &targetPid) == .success,
           targetPid == ProcessInfo.processInfo.processIdentifier,
           !Thread.isMainThread {
            return DispatchQueue.main.sync(execute: call)
        }
        return call()
    }

    /// Writes a value. **The returned error is not evidence**: WebKit content returns
    /// `.success` here while changing nothing, so callers must read back and compare.
    @discardableResult
    func setValue(_ text: String) -> AXError {
        mutate { AXUIElementSetAttributeValue(raw, kAXValueAttribute as CFString, text as CFString) }
    }

    /// Moves an element (in practice: a window) to a point in the same top-left global space
    /// `frame` reads from. Same rule as `setValue`: the return code is not evidence — the
    /// window manager is free to clamp or refuse, so callers read the frame back.
    @discardableResult
    func setPosition(_ point: CGPoint) -> AXError {
        var point = point
        guard let value = AXValueCreate(.cgPoint, &point) else { return .failure }
        return mutate { AXUIElementSetAttributeValue(raw, kAXPositionAttribute as CFString, value) }
    }

    /// Resizes an element (in practice: a window) to a size in points. Same rule as
    /// `setPosition`: the return code is not evidence — the window manager may clamp to the
    /// window's own minimum or maximum, so callers read the frame back.
    @discardableResult
    func setSize(_ size: CGSize) -> AXError {
        var size = size
        guard let value = AXValueCreate(.cgSize, &size) else { return .failure }
        return mutate { AXUIElementSetAttributeValue(raw, kAXSizeAttribute as CFString, value) }
    }

    @discardableResult
    func perform(_ action: String = kAXPressAction) -> AXError {
        mutate { AXUIElementPerformAction(raw, action as CFString) }
    }

    /// Chromium builds its accessibility tree lazily. Setting this asks it to build the full
    /// tree up front. Harmless elsewhere, and worth doing once per Chromium app — but it is
    /// not what unlocks Electron on its own; traversal depth is (see `ElementQuery`).
    @discardableResult
    func enableManualAccessibility() -> AXError {
        AXUIElementSetAttributeValue(raw, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    /// Whether the handle still refers to a live element. Electron in particular rebuilds
    /// elements on focus changes, and a dead handle answers every read with nil — which
    /// downstream looks identical to "the field is empty" and turns a successful action into
    /// a false `noEffect`. Only `.invalidUIElement` proves death; any other answer (including
    /// errors) leaves the handle presumed alive, because re-fetching an *equivalent* element
    /// can find the wrong one of several lookalikes.
    var isValid: Bool {
        var out: CFTypeRef?
        return AXUIElementCopyAttributeValue(raw, kAXRoleAttribute as CFString, &out) != .invalidUIElement
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
