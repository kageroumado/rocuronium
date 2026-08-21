import AppKit
import Foundation
import os

/// Session-level display wakefulness through Adrafinil's display-class holds.
///
/// Rung 0 (`DisplayWake.ensureAwake`) wakes the panel per action; this type keeps it awake
/// *between* actions, for the overnight case: an agent that reads, thinks for three minutes,
/// and acts again would otherwise let the display sleep mid-think and pay a wake-and-settle
/// on every step — with every accessibility tree collapsing and repopulating around it.
///
/// Adrafinil is the wake manager of the suite, so the hold is placed there when its CLI is
/// installed (`adrafinil acquire … --display`): its daemon owns TTL reaping, pause, idle
/// release, and the thermal/battery cutouts, and its UI shows who is keeping the display on.
/// Without Adrafinil the same lifecycle runs on a process-local IOPM assertion — an
/// enhancement, never a dependency.
///
/// Lifecycle: the router calls `noteActivity()` on every engine-driving command. The first
/// call places the hold; a slow timer renews it while commands keep arriving and releases it
/// once the engine has been quiet for `Constants.idleRelease`. Renewal rotates keys
/// (Adrafinil's max-age backstop releases a key ~24 h after *first* acquire, and re-acquiring
/// does not reset that clock), and every key that may still be registered daemon-side is
/// released synchronously at app termination — anything that slips through expires via TTL.
///
/// Presence integrity, measured 2026-08-22: `IOPMAssertionDeclareUserActivity` does **not**
/// reset `HIDIdleTime` (19.3 s before → 19.6 s after → kept counting), so neither the wake
/// nor this hold can make the engine mistake its own activity for a human's.
@MainActor
@Observable
final class AdrafinilBridge {
    private(set) var isInstalled = false
    /// True while a display hold is intended and the renewal timer runs.
    private(set) var isHolding = false
    /// "adrafinil" or "internal" while holding — surfaced in `status` so a caller can see
    /// which mechanism keeps the display awake.
    private(set) var mechanism: String?

    private enum Constants {
        static let toolName = "Rocuronium"
        static let holdTTL: TimeInterval = 15 * 60
        static let renewalInterval: TimeInterval = 5 * 60
        /// Engine quiet for this long → the hold is released. Long enough for an agent's
        /// read-think-act rhythm, short enough that a finished session does not pin the
        /// display for the rest of the night.
        static let idleRelease: TimeInterval = 4 * 60
        static let tickInterval: TimeInterval = 30
        /// Bounded wait for the willTerminate release path, so a wedged CLI cannot stall
        /// quit; the daemon-side TTL reaps whatever is left.
        static let synchronousReleaseTimeout: TimeInterval = 2
        /// The installer's symlink locations, then the bundle itself — GUI apps inherit a
        /// minimal PATH, and on a machine with no symlink the Helpers binary is the CLI.
        static let installPaths = [
            "/usr/local/bin/adrafinil",
            "\(NSHomeDirectory())/.local/bin/adrafinil",
            "/Applications/Adrafinil.app/Contents/Helpers/adrafinil",
        ]
    }

    private static let log = Logger(subsystem: "glass.kagerou.rocuronium", category: "AdrafinilBridge")

    @ObservationIgnored private var cliPath: String?
    @ObservationIgnored private var lastActivity: Date?
    @ObservationIgnored private var lastAcquire: Date?
    @ObservationIgnored private var currentKey: String?
    /// Keys that may still be registered daemon-side: inserted at enqueue, removed after the
    /// matching release ran. The synchronous teardown sweeps them all.
    @ObservationIgnored private var outstandingKeys: Set<String> = []
    @ObservationIgnored private var tickTimer: Timer?
    /// Serializes CLI invocations so an acquire/release pair can never reorder.
    @ObservationIgnored private var pendingOperations: Task<Void, Never>?
    /// The no-Adrafinil fallback: the same lifecycle on a process-local assertion.
    @ObservationIgnored private var fallbackHold: DisplayWake.Hold?
    @ObservationIgnored private var terminationObserver: (any NSObjectProtocol)?

    init() {
        cliPath = Self.locateCLI()
        isInstalled = cliPath != nil
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main,
        ) { [weak self] _ in
            // Delivered on the main queue per the observer's `queue:`; the assertion makes
            // that checkable instead of assumed.
            MainActor.assumeIsolated { self?.releaseSynchronously() }
        }
    }

    /// The engine is doing something that needs eyes. Cheap; called per routed command.
    func noteActivity() {
        lastActivity = Date()
        guard !isHolding else { return }
        isHolding = true
        if cliPath != nil {
            mechanism = "adrafinil"
            rotateHold()
        } else {
            mechanism = "internal"
            fallbackHold = DisplayWake.Hold(reason: "Rocuronium session: an agent is driving the interface")
        }
        startTicking()
    }

    // MARK: - Lifecycle

    private func startTicking() {
        tickTimer?.invalidate()
        let timer = Timer(timeInterval: Constants.tickInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = Constants.tickInterval / 3
        // .common: a tracking run loop (the menu bar popover open) suppresses default-mode
        // timers, and a stalled tick would let the hold's TTL lapse mid-session.
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    private func tick() {
        guard isHolding else { return }
        if let lastActivity, Date().timeIntervalSince(lastActivity) > Constants.idleRelease {
            stopHolding()
            return
        }
        if mechanism == "adrafinil", let lastAcquire,
           Date().timeIntervalSince(lastAcquire) >= Constants.renewalInterval {
            rotateHold()
        }
    }

    private func stopHolding() {
        isHolding = false
        mechanism = nil
        tickTimer?.invalidate()
        tickTimer = nil
        fallbackHold?.release()
        fallbackHold = nil
        currentKey = nil
        let keys = outstandingKeys
        guard !keys.isEmpty else { return }
        Self.log.notice("Releasing display hold(s): \(keys.joined(separator: ", "), privacy: .public)")
        enqueue { [self] in
            for key in keys {
                await runCLI(["release", key, "--tool", Constants.toolName])
                outstandingKeys.remove(key)
            }
        }
    }

    /// Acquire a fresh key, then release the one it replaces, so the hold never gaps.
    private func rotateHold() {
        let key = "session-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8).lowercased()
        let previous = currentKey
        currentKey = key
        lastAcquire = Date()
        outstandingKeys.insert(key)
        enqueue { [self] in
            guard isHolding, currentKey == key else {
                // A release ran while this was queued; acquiring now would orphan the hold.
                outstandingKeys.remove(key)
                return
            }
            let landed = await runCLI([
                "acquire", key,
                "--tool", Constants.toolName,
                "--reason", "an agent is driving the interface",
                "--ttl", String(Int(Constants.holdTTL)),
                "--display",
            ])
            if let previous {
                await runCLI(["release", previous, "--tool", Constants.toolName])
                outstandingKeys.remove(previous)
            }
            // An installed CLI with a dead daemon fails soft (exit 0, stderr warning) and
            // holds nothing. The session still needs its display — fall back to the
            // process-local assertion, and let the next session try Adrafinil again.
            if !landed, isHolding, mechanism == "adrafinil" {
                outstandingKeys.remove(key)
                currentKey = nil
                mechanism = "internal"
                fallbackHold = DisplayWake.Hold(reason: "Rocuronium session: an agent is driving the interface")
            }
        }
    }

    /// Best-effort release of every possibly-live key on the quit path, where the queued
    /// async release would never get to run.
    private func releaseSynchronously() {
        tickTimer?.invalidate()
        tickTimer = nil
        isHolding = false
        fallbackHold?.release()
        fallbackHold = nil
        guard let cliPath else { return }
        for key in outstandingKeys {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: cliPath)
            process.arguments = ["release", key, "--tool", Constants.toolName]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            let done = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in done.signal() }
            guard (try? process.run()) != nil else { continue }
            if done.wait(timeout: .now() + Constants.synchronousReleaseTimeout) == .timedOut {
                process.terminate()
            }
        }
        outstandingKeys.removeAll()
    }

    // MARK: - CLI plumbing

    private func enqueue(_ operation: @escaping @MainActor () async -> Void) {
        let previous = pendingOperations
        pendingOperations = Task {
            await previous?.value
            await operation()
        }
    }

    @discardableResult
    private func runCLI(_ arguments: [String]) async -> Bool {
        guard let cliPath else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cliPath)
        process.arguments = arguments
        // The CLI polls stdin for a hook payload before falling back to the positional key;
        // the null device reads as immediate EOF.
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let stderrPipe = Pipe()
        process.standardError = stderrPipe

        // Drain stderr concurrently with the wait for exit: a post-exit read would deadlock
        // the operation chain if the child ever filled the pipe buffer.
        let stderrTask = Task { () -> Data in
            var data = Data()
            do {
                for try await byte in stderrPipe.fileHandleForReading.bytes {
                    data.append(byte)
                }
            } catch {}
            return data
        }
        let launched = await withCheckedContinuation { continuation in
            process.terminationHandler = { _ in continuation.resume(returning: true) }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                Self.log.error("Failed to launch adrafinil: \(error.localizedDescription)")
                continuation.resume(returning: false)
            }
        }
        if !launched {
            try? stderrPipe.fileHandleForWriting.close()
        }
        let message = String(data: await stderrTask.value, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !message.isEmpty {
            Self.log.warning("adrafinil \(arguments.first ?? "", privacy: .public): \(message, privacy: .public)")
        }
        // The CLI fails soft — exit 0 with a stderr warning — so silence is the success signal.
        return launched && process.terminationStatus == 0 && message.isEmpty
    }

    private static func locateCLI() -> String? {
        var candidates = Constants.installPaths
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates += path.split(separator: ":").map { "\($0)/adrafinil" }
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
