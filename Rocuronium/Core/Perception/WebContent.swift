import AppKit
import ApplicationServices

/// Recognizes the one surface the ghost ladder cannot reach — web page content — and names
/// the channel that can.
///
/// Measured in `Experiments/ghost-input/RESULTS.md`: WebKit web content refuses accessibility
/// writes *and* posted keys, and returns `.success` from the write while changing nothing.
/// Chromium honors posted unicode keys once focus is right, so Electron composers usually
/// succeed on rung 2 and never reach this code. When a web-content target does exhaust the
/// rungs, no OS-level input path exists at all — so rung 3 is a **referral, not an adapter**:
/// structured evidence naming the browser's own protocol, for the calling agent to compose.
/// An adapter here would couple this app to external binaries and to launch flags (CDP's
/// debug port) that only the caller can supply by relaunching the browser.
nonisolated enum WebContent {
    private enum Constants {
        /// How far up the ancestor chain to look for `AXWebArea`. Fields measured at depth
        /// 21–24 in Discord sit well inside; the cap only bounds the IPC cost per lookup.
        static let maximumAncestorDepth = 30
    }

    /// Whether the element sits inside web page content, decided by `AXWebArea` ancestry
    /// rather than by what app it belongs to — a browser's address bar is native, and a
    /// referral there would point away from rungs that actually work.
    static func isWebContent(_ element: AXElement) -> Bool {
        var current: AXElement? = element
        for _ in 0 ..< Constants.maximumAncestorDepth {
            guard let element = current else { return false }
            if element.role == "AXWebArea" { return true }
            current = element.parent
        }
        return false
    }

    /// Which engine renders this process's web content. Determines whose protocol to name.
    enum Family {
        case refrax
        case safari
        case chromium
        case electron
        case unknown
    }

    static func family(of pid: pid_t) -> Family {
        guard let application = NSRunningApplication(processIdentifier: pid) else { return .unknown }
        let bundleID = application.bundleIdentifier ?? ""
        if bundleID == "website.refrax.browser" { return .refrax }
        if bundleID.hasPrefix("com.apple.Safari") { return .safari }
        let chromiumPrefixes = [
            "com.google.Chrome", "org.chromium.Chromium", "com.brave.Browser",
            "com.microsoft.edgemac", "company.thebrowser.Browser", "com.vivaldi.Vivaldi",
            "com.operasoftware.Opera",
        ]
        if chromiumPrefixes.contains(where: bundleID.hasPrefix) { return .chromium }
        // Electron is detected structurally rather than by a bundle-id list that would rot:
        // every Electron app embeds the framework at the same path.
        if let bundleURL = application.bundleURL, FileManager.default.fileExists(
            atPath: bundleURL.appending(path: "Contents/Frameworks/Electron Framework.framework").path,
        ) { return .electron }
        return .unknown
    }

    /// The referral itself, or nil when the target is not web content and the ladder's
    /// failure needs a different explanation.
    static func referral(for element: AXElement, pid: pid_t) -> Evidence.Referral? {
        guard isWebContent(element) else { return nil }
        return switch family(of: pid) {
        case .refrax:
            .init(
                channel: "refrax-ctl",
                reason: "the target is web page content in Refrax; WebKit content refuses OS-level input and reports success while changing nothing",
                advice: "drive the page with refrax-ctl — page_exec, type, and click act on the DOM directly, with DOM read-back as evidence",
            )
        case .safari:
            .init(
                channel: "safari-js",
                reason: "the target is web page content in Safari; WebKit content refuses OS-level input and reports success while changing nothing",
                advice: "use Safari's own automation: osascript 'do JavaScript' (enable Develop ▸ Developer settings ▸ Allow JavaScript from Apple Events) or safaridriver",
            )
        case .chromium:
            .init(
                channel: "cdp",
                reason: "the target is web page content in a Chromium browser and OS-level input did not land",
                advice: "relaunch the browser with --remote-debugging-port=<port> and drive the page over the DevTools protocol; only a launch flag can open that door",
            )
        case .electron:
            .init(
                channel: "cdp",
                reason: "the target is web content in an Electron app and OS-level input did not land",
                advice: "posted unicode keys normally work here once the field holds focus — retry after focusing it; for DOM-level access relaunch with --remote-debugging-port=<port> and use the DevTools protocol",
            )
        case .unknown:
            .init(
                channel: "unknown",
                reason: "the target is web page content in an unrecognized engine and OS-level input did not land",
                advice: "no OS-level input path exists for web content — find this app's own automation channel",
            )
        }
    }
}
