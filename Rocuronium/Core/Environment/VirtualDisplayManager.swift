import AppKit

/// Creates and destroys the daemon's own headless virtual display, in process.
///
/// Built on the private `CGVirtualDisplay` ObjC classes (declared in the local bridging
/// header — the SDK exports the symbols for linkage but ships no public header). In-process
/// creation makes "the display exists" and "we own it" the same fact: the display dies when
/// this object lets go of it or when the process exits, and attach is observable directly
/// through the object's nonzero `displayID` instead of by polling `NSScreen` for a name.
///
/// The private API's shape has moved across SDK versions (`applySettings:` grew a Swift
/// name; a refresh-deadline symbol appeared), so every step here treats failure as
/// "isolation unavailable" and throws rather than trusting the classes to keep behaving.
@MainActor
final class VirtualDisplayManager {
    private enum Constants {
        /// Pixel buffer of the display. With `hiDPI = 1` this presents as a Retina (@2x)
        /// logical resolution of half these dimensions — 1920×1080.
        static let pixelWidth: UInt32 = 3840
        static let pixelHeight: UInt32 = 2160
        /// Distinct from Test Display's name on purpose: `windows` output and logs must be
        /// able to tell the daemon's own display from the user's.
        static let displayName = "Rocuronium Display"
        static let productID: UInt32 = 0x1235
        static let vendorID: UInt32 = 0x3456
        static let serialNum: UInt32 = 0x0002
        static let sizeInMillimeters = CGSize(width: 600, height: 340)
        static let refreshRate = 60.0
    }

    private(set) var display: CGVirtualDisplay?

    var displayID: CGDirectDisplayID? {
        guard let display, display.displayID != 0 else { return nil }
        return display.displayID
    }

    /// Creates the display, places it to the right of the main display, and verifies the
    /// arrangement. Returns the new display's id.
    ///
    /// The origin at `(mainWidth, 0)` keeps the main display's zero origin — and with it
    /// the menu bar, notification banners, and (by every observation so far) TCC prompts —
    /// exactly where they were. The post-creation assertion makes that a checked invariant
    /// rather than a hope: if a stored arrangement ever makes the virtual display primary,
    /// creation is rolled back and refused.
    @discardableResult
    func create() throws -> CGDirectDisplayID {
        if let id = displayID { return id }

        let mainBefore = CGMainDisplayID()

        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.queue = DispatchQueue.main
        descriptor.name = Constants.displayName
        descriptor.maxPixelsWide = Constants.pixelWidth
        descriptor.maxPixelsHigh = Constants.pixelHeight
        descriptor.sizeInMillimeters = Constants.sizeInMillimeters
        descriptor.productID = Constants.productID
        descriptor.vendorID = Constants.vendorID
        descriptor.serialNum = Constants.serialNum

        guard let created = CGVirtualDisplay(descriptor: descriptor) else {
            throw CreationError.creationFailed
        }
        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = 1
        settings.modes = [
            CGVirtualDisplayMode(width: Constants.pixelWidth, height: Constants.pixelHeight,
                                 refreshRate: Constants.refreshRate),
            CGVirtualDisplayMode(width: Constants.pixelWidth / 2, height: Constants.pixelHeight / 2,
                                 refreshRate: Constants.refreshRate),
        ]
        guard created.apply(settings) else {
            throw CreationError.creationFailed
        }
        guard created.displayID != 0 else {
            throw CreationError.creationFailed
        }
        display = created

        positionToRightOfMain(created.displayID, mainDisplay: mainBefore)

        guard CGMainDisplayID() == mainBefore else {
            destroy()
            throw CreationError.becamePrimary
        }
        return created.displayID
    }

    /// Releasing the `CGVirtualDisplay` object is the teardown — the window server detaches
    /// the display when its owning object goes away.
    func destroy() {
        display = nil
    }

    /// Places the virtual display immediately to the right of the main display, so no
    /// existing window's coordinates change and parked windows live at positive x ≥ the
    /// main display's width.
    private func positionToRightOfMain(_ id: CGDirectDisplayID, mainDisplay: CGDirectDisplayID) {
        let mainWidth = Int32(CGDisplayBounds(mainDisplay).width)
        var configuration: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&configuration) == .success, let configuration else { return }
        CGConfigureDisplayOrigin(configuration, id, mainWidth, 0)
        CGCompleteDisplayConfiguration(configuration, .permanently)
    }

    enum CreationError: LocalizedError {
        case creationFailed
        case becamePrimary

        var errorDescription: String? {
            switch self {
            case .creationFailed:
                "Isolation unavailable: the system refused to create a virtual display (the private CGVirtualDisplay API may have changed)."
            case .becamePrimary:
                "Isolation unavailable: the virtual display became the primary display, which would move the menu bar and every system prompt onto an invisible screen — creation was rolled back."
            }
        }
    }
}
