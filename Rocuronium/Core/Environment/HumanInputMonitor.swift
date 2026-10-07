import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// One piece of human input observed while an action was in flight.
nonisolated struct HumanInputEvent: Equatable, Sendable {
    enum Kind: String, Sendable {
        case mouseDown, keyDown, scroll, pointerMotion
    }

    let kind: Kind
    /// Seconds since monitoring began for the action.
    let offset: TimeInterval
    /// Where the pointer was, in global top-left points.
    let location: CGPoint
    /// The process the input went to: the owner of the window under the pointer for mouse and
    /// scroll input, the frontmost app for keys. Nil when it could not be told.
    let pid: pid_t?
}

/// What the monitor saw over one action, and the reply fields it turns into.
nonisolated struct HumanInputReport: Equatable, Sendable {
    /// False when no tap could be created (no permission), so nothing was watched.
    let monitored: Bool
    let events: [HumanInputEvent]
    /// A hardware payload was cut short because the human used the mouse or keyboard.
    let stopped: Bool
    let targetPid: pid_t?

    static let unmonitored = HumanInputReport(monitored: false, events: [], stopped: false, targetPid: nil)

    /// The kinds that can produce the change an action's evidence reads. Pointer motion is
    /// recorded as a hardware stop cause only: hovering is the human using their Mac.
    static let attributableKinds: Set<HumanInputEvent.Kind> = [.mouseDown, .keyDown, .scroll]

    /// Whether `event` landed in the target app.
    static func inTarget(_ event: HumanInputEvent, target: pid_t?) -> Bool {
        guard let target, let pid = event.pid else { return false }
        return pid == target
    }

    /// `mixed` when the action was confirmed and the human clicked, typed, or scrolled in the
    /// target app while it ran or while its evidence was gathered — the confirmation may be the
    /// human's doing. `agent` otherwise.
    static func attribution(verdict: String?, events: [HumanInputEvent], target: pid_t?) -> String {
        let humanTouchedTarget = events.contains {
            attributableKinds.contains($0.kind) && inTarget($0, target: target)
        }
        return verdict == "confirmed" && humanTouchedTarget ? "mixed" : "agent"
    }

    /// The `humanInput` block, plus `attribution` when the reply carries a verdict and input was
    /// watched — an unwatched action has no basis to vouch either way.
    func replyFields(verdict: String?) -> [String: Any] {
        var block: [String: Any] = ["monitored": monitored, "stopped": stopped]
        if !events.isEmpty {
            block["events"] = events.map { event -> [String: Any] in
                [
                    "kind": event.kind.rawValue,
                    "inTarget": Self.inTarget(event, target: targetPid),
                    "atMs": Int((event.offset * 1000).rounded()),
                ]
            }
        }
        var fields: [String: Any] = ["humanInput": block]
        if monitored, verdict != nil {
            fields["attribution"] = Self.attribution(verdict: verdict, events: events, target: targetPid)
        }
        return fields
    }
}

/// Watches for human input while an action is in flight, telling it apart from ours by the
/// `SyntheticInput` mark.
///
/// A listen-only session event tap, created when an acting command begins and destroyed when its
/// reply is built: the machine's input is observed only for the seconds an agent is acting on
/// it. The tap reports kinds, times, and which app the input went to — never key content.
///
/// Two consumers:
/// - The **hardware tentacle** arms the monitor before it takes the cursor or keyboard. Any human
///   input after that (pointer motion above a noise floor included) makes `shouldYield` true, and
///   the remaining payload stops — a human reaching for their mouse wins.
/// - **Every acting reply** carries the report, and a confirmed verdict is marked `mixed` when
///   the human clicked, typed, or scrolled in the target app meanwhile.
///
/// Lock-guarded rather than an actor: the tap callback runs on its own thread and the cursor
/// walk polls `shouldYield` from a raw thread, and neither can suspend.
nonisolated final class HumanInputMonitor: @unchecked Sendable {
    static let shared = HumanInputMonitor()

    private enum Constants {
        /// Pointer travel (points) inside one motion burst below which motion is a resting
        /// hand's jitter, not a human taking the mouse.
        static let motionNoiseFloor = 4.0
        /// A pause this long ends a motion burst and resets its travel.
        static let motionBurstGap: TimeInterval = 0.25
        /// Consecutive scroll or motion events closer than this are one gesture, recorded once.
        static let coalesceWindow: TimeInterval = 0.3
        /// Bounds the report; the first events of an interruption are the informative ones.
        static let maxEvents = 32
    }

    private let lock = NSLock()
    private var active = false
    private var start = Date()
    private var targetPid: pid_t?
    private var frontmostPid: pid_t?
    private var events: [HumanInputEvent] = []
    private var armed = false
    private var interrupted = false
    private var stopped = false
    private var motionTravel = 0.0
    private var lastMotion: Date?

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var runLoop: CFRunLoop?
    private var activationObserver: (any NSObjectProtocol)?

    private init() {}

    // MARK: - Session (the router, around each acting command)

    /// Starts watching for the duration of one action. Returns false, and watches nothing, when
    /// the tap cannot be created — the process lacks Accessibility and Input Monitoring.
    @MainActor
    @discardableResult
    func begin(targetPid: pid_t?) -> Bool {
        stopTap()
        lock.withLock {
            active = false
            start = Date()
            self.targetPid = targetPid
            frontmostPid = NSWorkspace.shared.frontmostApplication?.processIdentifier
            events = []
            armed = false
            interrupted = false
            stopped = false
            motionTravel = 0
            lastMotion = nil
        }
        // Checked first so a missing grant never raises a permission prompt mid-action.
        guard AXIsProcessTrusted() || CGPreflightListenEventAccess() else { return false }
        guard let runLoop = tapRunLoop() else { return false }

        let mask: [CGEventType] = [
            .leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown, .scrollWheel,
            .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
        ]
        let eventMask = mask.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: { _, type, event, userInfo in
                if let userInfo {
                    Unmanaged<HumanInputMonitor>.fromOpaque(userInfo).takeUnretainedValue().handle(type, event)
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque(),
        ), let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else { return false }

        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: nil,
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard let self, let pid = app?.processIdentifier else { return }
            lock.withLock { self.frontmostPid = pid }
        }
        lock.withLock {
            self.tap = tap
            self.source = source
            active = true
        }
        CFRunLoopAddSource(runLoop, source, .commonModes)
        CFRunLoopWakeUp(runLoop)
        return true
    }

    /// Stops watching and returns what was seen.
    @MainActor
    func end() -> HumanInputReport {
        let wasMonitored = lock.withLock { tap != nil }
        stopTap()
        return lock.withLock {
            HumanInputReport(monitored: wasMonitored, events: events, stopped: stopped, targetPid: targetPid)
        }
    }

    @MainActor
    private func stopTap() {
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
            self.activationObserver = nil
        }
        let (tap, source) = lock.withLock {
            active = false
            armed = false
            defer { self.tap = nil; self.source = nil }
            return (self.tap, self.source)
        }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source, let runLoop { CFRunLoopRemoveSource(runLoop, source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
    }

    /// The tap's own thread and run loop, started once and parked between actions: the tap
    /// callback must never wait on the main actor, which is awaiting the very action it watches.
    private func tapRunLoop() -> CFRunLoop? {
        if let runLoop { return runLoop }
        let ready = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var started: CFRunLoop?
        let thread = Thread {
            started = CFRunLoopGetCurrent()
            // A run loop with no source returns at once; a timer that never fires keeps it parked.
            let keepAlive = CFRunLoopTimerCreateWithHandler(
                kCFAllocatorDefault, .greatestFiniteMagnitude, 0, 0, 0, { _ in },
            )
            CFRunLoopAddTimer(CFRunLoopGetCurrent(), keepAlive, .commonModes)
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "rocuronium.human-input"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        runLoop = started
        return started
    }

    // MARK: - The hardware tentacle

    /// Called before the hardware tentacle takes the cursor or keyboard (including the charge-up
    /// wind-up): from here on any human input means the remaining payload must stop.
    func armHardware() {
        lock.withLock {
            guard !armed else { return }
            armed = true
            motionTravel = 0
            lastMotion = nil
        }
    }

    /// Whether the human has used the mouse or keyboard since the hardware tentacle armed. True
    /// also records that a payload yielded, which the reply reports as `stopped`.
    func shouldYield() -> Bool {
        lock.withLock {
            if interrupted { stopped = true }
            return interrupted
        }
    }

    /// Whether the human has used the mouse or keyboard since the hardware tentacle armed,
    /// without recording a yield — for wording a result after the fact.
    var humanInterruptedHardware: Bool {
        lock.withLock { interrupted }
    }

    // MARK: - The tap

    private func handle(_ type: CGEventType, _ event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = lock.withLock({ active ? self.tap : nil }) { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        guard !SyntheticInput.isOurs(event) else { return }
        let kind: HumanInputEvent.Kind
        switch type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown: kind = .mouseDown
        case .keyDown: kind = .keyDown
        case .scrollWheel: kind = .scroll
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged: kind = .pointerMotion
        default: return
        }
        let location = event.location
        let travel = hypot(
            event.getDoubleValueField(.mouseEventDeltaX),
            event.getDoubleValueField(.mouseEventDeltaY),
        )
        let now = Date()

        // Decide under the lock whether this event is recorded; resolve the window owner (a
        // window-list query) outside it.
        let decision: (record: Bool, needsWindowOwner: Bool, keyPid: pid_t?, offset: TimeInterval)? = lock.withLock {
            guard active else { return nil }
            let offset = now.timeIntervalSince(start)
            if kind == .pointerMotion {
                guard armed else { return nil }
                if let lastMotion, now.timeIntervalSince(lastMotion) > Constants.motionBurstGap { motionTravel = 0 }
                lastMotion = now
                motionTravel += travel
                guard motionTravel > Constants.motionNoiseFloor else { return nil }
                interrupted = true
            } else if armed {
                interrupted = true
            }
            guard events.count < Constants.maxEvents else { return nil }
            if kind == .scroll || kind == .pointerMotion, let last = events.last, last.kind == kind,
               offset - last.offset < Constants.coalesceWindow
            {
                return nil
            }
            return (true, kind != .keyDown, kind == .keyDown ? frontmostPid : nil, offset)
        }
        guard let decision, decision.record else { return }
        let pid = decision.needsWindowOwner ? Self.windowOwner(at: location) : decision.keyPid
        lock.withLock {
            guard active, events.count < Constants.maxEvents else { return }
            events.append(HumanInputEvent(kind: kind, offset: decision.offset, location: location, pid: pid))
        }
    }

    /// The owner of the topmost visible window at `point`, by the occlusion check's own rule —
    /// our overlay windows and the Dock's whole-display backdrop are not where a click lands.
    private static func windowOwner(at point: CGPoint) -> pid_t? {
        HardwareInput.occluder(
            at: point, target: nil, ownPID: getpid(),
            windows: HardwareInput.onScreenWindowSlots(), displays: HardwareInput.displayBounds(),
        )
    }
}
