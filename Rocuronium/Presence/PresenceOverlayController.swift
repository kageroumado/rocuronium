import AppKit
import SwiftUI

/// Owns the presence surfaces and their lifecycle: the panel (consent prompt included) and the
/// full-screen effects layer.
///
/// The model decides what is shown at any instant (`OverlayModel.presentation(at:)`); this
/// controller turns that into windows. A session runs from the first action or `busy on` to an
/// end the agent declares — `busy off`, a `--done` action, the end of a plan — or to the
/// silence safety. A `busy wait` releases the screen: the panel hides and the session goes on.
/// The effects layer is up only while it has something to draw — a hands-off action, a
/// charging ring, a ripple — and never while idle. ⌃⌥⇧⎋ removes everything at once.
@MainActor
final class PresenceOverlayController {
    /// The relay hooks are `@Sendable` and cannot capture this MainActor object, so they
    /// reach it through a main-actor static instead.
    static weak var shared: PresenceOverlayController?

    let model = OverlayModel()
    /// Fires after ⌃⌥⇧⎋ has halted the engine and removed the chrome; the router logs it.
    var onEmergencyStop: (@MainActor () -> Void)?

    private var panelWindow: PresencePanel?
    private var panelHost: NSHostingView<AnyView>?
    private var effectsWindow: NSWindow?
    private let hotkey = HotkeyMonitor()
    private let consentKeys = ConsentHotkeys()
    private var consentContinuation: CheckedContinuation<ConsentAnswer, Never>?
    private var tickTask: Task<Void, Never>?
    private var panelFading = false
    private var effectsShown = false
    private var moveObserver: (any NSObjectProtocol)?
    /// True while the controller itself moves the panel, so only the human's drags are remembered.
    private var placingPanel = false

    // Nonisolated so the relay hook, which runs off the main actor, can read the wind-up.
    private nonisolated enum Constants {
        static let fadeIn: TimeInterval = 0.2
        static let effectsFade: TimeInterval = 0.2
        /// How often the lifecycle is re-evaluated while a session runs.
        static let tick: Duration = .milliseconds(200)
        /// The charge-up ring's wind-up — the visible interrupt window before each hardware click.
        static let charge: TimeInterval = 0.6
        /// How long a consent prompt waits for the human before it cancels itself — well
        /// inside the socket's 30 s so the caller gets a clean "declined", not a dead call.
        static let consentTimeout: TimeInterval = 25
        /// Transparent room around the panel inside its window, so the entry swell and the
        /// shadow are never clipped by the window edge.
        static let panelMargin: CGFloat = 18
    }

    init() {
        hotkey.onHalt = { [weak self] in self?.emergencyStop() }
    }

    var isSessionVisible: Bool { model.sessionStart != nil }

    // MARK: - Commands (called by the router)

    /// A command is starting. Its action phrase becomes line 2 at once; a hands-off command
    /// turns the panel amber before the pointer moves, so the warning precedes the motion.
    func begin(action: PanelAction) {
        model.begin(action, at: Date())
        appear()
    }

    /// The command's reply is in: line 2 says what it came to, or the panel holds in Stopped.
    func commandFinished(_ reply: [String: Any]) {
        guard isSessionVisible else { return }
        model.finish(reply: reply, at: Date())
        evaluate()
    }

    // MARK: - The agent's declarations (`busy`)

    /// The agent declares a bracket of work with a goal and, optionally, its steps. Shown only
    /// when the human asked to watch every action, or a session is already up; a cue, never a gate.
    func beginHold(goal: String, steps: [String]) {
        guard model.showForAllActions || isSessionVisible else { return }
        model.beginHold(goal: goal, steps: steps, at: Date())
        appear()
    }

    /// Moves the step pointer: `nil` = next, otherwise 1-based. Brings a released panel back.
    func advanceStep(to step: Int?) {
        guard isSessionVisible else { return }
        model.advanceStep(to: step, at: Date())
        appear()
    }

    /// The agent waits on something that is not the UI: the panel hides until it acts again.
    func beginWait(what: String, seconds: TimeInterval?) {
        guard isSessionVisible else { return }
        model.beginWait(what: what, seconds: seconds, at: Date())
        evaluate()
    }

    /// The agent is done: Done shows for two seconds, then everything fades, so "panel gone"
    /// means "nothing is coming".
    func endHold(result: String?) {
        guard isSessionVisible else { return }
        model.endHold(result: result, at: Date())
        evaluate()
    }

    // MARK: - Plans

    /// A plan begins: its step intents become the panel's step list.
    func beginPlan(intents: [String]) {
        guard model.showForAllActions || isSessionVisible else { return }
        model.beginPlan(intents: intents, at: Date())
        appear()
    }

    /// The plan is over — it ends the session: Done, or Ended with the reason it stopped.
    func endPlan(abortReason: String?) {
        guard isSessionVisible else { return }
        model.endPlan(abortReason: abortReason, at: Date())
        evaluate()
    }

    /// A plan paused for the human: held in Stopped until they resume it.
    func pausePlan() {
        guard isSessionVisible else { return }
        model.pausePlan(at: Date())
        appear()
    }

    // MARK: - Consent

    /// Ask the human at the machine to approve a disruptive action, and block on the answer.
    /// The panel grows to hold the question and its keys. The socket call awaits this, so it
    /// resolves quickly: a one-second hold on **Y**, **A** or **N**, or the timeout (treated as
    /// no) well inside the socket's 30 s.
    func requestConsent(prompt: String) async -> ConsentAnswer {
        // Resolve any prompt already standing (only one at a time) as a decline before opening
        // the new one — a stale continuation must never be abandoned unresumed.
        if consentContinuation != nil { resolveConsent(.decline) }

        model.presentConsent(prompt: prompt, at: Date())
        appear()

        consentKeys.onProgress = { [weak self] answer, fraction in
            self?.model.consentHold = (answer, fraction)
        }
        consentKeys.onResolve = { [weak self] answer in
            self?.resolveConsent(answer)
        }
        consentKeys.start()

        let deadline = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Constants.consentTimeout))
            guard !Task.isCancelled else { return }
            self?.resolveConsent(.decline)
        }
        defer { deadline.cancel() }

        return await withCheckedContinuation { continuation in
            consentContinuation = continuation
        }
    }

    private func resolveConsent(_ answer: ConsentAnswer) {
        guard let continuation = consentContinuation else { return }
        consentContinuation = nil
        consentKeys.stop()
        model.resolveConsent(answer, at: Date())
        evaluate()
        continuation.resume(returning: answer)
    }

    // MARK: - Effects (called through the relay)

    func showChargeRing(at point: CGPoint, duration: TimeInterval) {
        model.charge(at: point, duration: duration, now: Date())
        appear()
    }

    func showRipple(at point: CGPoint) {
        model.addRipple(at: point, now: Date())
        appear()
    }

    /// A ghost (cursor-free) action landed at `point` and the human is here to see it: a ripple
    /// where it struck, and nothing else — the action stays a ghost.
    func showGhostPing(at point: CGPoint) {
        guard isSessionVisible else { return }
        model.addRipple(at: point, now: Date())
        evaluate()
    }

    /// Installs the Core-side hooks. Called once at launch, after `shared` is set.
    static func installRelayHooks() {
        PresenceRelay.telegraph = { point in
            // The ring and its wind-up exist only while the overlay is visible; invisible
            // sessions return immediately and pay nothing.
            let armed = await MainActor.run {
                guard let overlay = shared, overlay.isSessionVisible else { return false }
                overlay.showChargeRing(at: point, duration: Constants.charge)
                return true
            }
            guard armed else { return }
            try? await Task.sleep(for: .seconds(Constants.charge))
        }
        PresenceRelay.impact = { point in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    shared?.showRipple(at: point)
                }
            }
        }
        PresenceRelay.ghostImpact = { point in
            // A ghost click gets a ping only when the human asked to watch every action and is
            // actually here to see it — never over a locked or sleeping screen.
            let presence = UserPresence.read()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let overlay = shared, overlay.model.showForAllActions,
                          presence.state != .away, presence.canSee else { return }
                    overlay.showGhostPing(at: point)
                }
            }
        }
    }

    // MARK: - The emergency stop

    /// ⌃⌥⇧⎋: halt the engine, then remove every surface at once — no fade, no ceremony.
    private func emergencyStop() {
        EmergencyStop.halt(reason: "⌃⌥⇧⎋ pressed while the overlay was visible")
        if consentContinuation != nil { resolveConsent(.decline) }
        model.reset()
        hideEverything()
        onEmergencyStop?()
    }

    private func hideEverything() {
        tickTask?.cancel()
        tickTask = nil
        hotkey.unregister()
        panelFading = false
        effectsShown = false
        for window in [panelWindow, effectsWindow] as [NSWindow?] {
            window?.orderOut(nil)
            window?.alphaValue = 0
        }
    }

    // MARK: - Lifecycle

    /// Something happened that keeps the panel up: show it (or cancel a fade in progress),
    /// arm the stop chord, and start re-evaluating.
    private func appear() {
        if panelWindow == nil { makePanelWindow() }
        guard let panelWindow else { return }
        guard model.presentation(at: Date()).isUp else {
            evaluate()
            return
        }
        if !panelWindow.isVisible {
            fitPanel(anchorBottom: true)
            placePanel()
            panelWindow.alphaValue = 0
            panelWindow.orderFrontRegardless()
            ScreenCapture.excludeFromCaptures(windowNumber: panelWindow.windowNumber)
        }
        if panelWindow.alphaValue < 1 || panelFading {
            panelFading = false
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Constants.fadeIn
                panelWindow.animator().alphaValue = 1
            }
        }
        // The stop chord exists only while there is visibly something to stop.
        hotkey.register()
        startTicking()
        evaluate()
    }

    private func startTicking() {
        guard tickTask == nil else { return }
        tickTask = Task(name: "presence panel lifecycle") { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Constants.tick)
                self?.evaluate()
            }
        }
    }

    /// Applies the model's presentation to the windows.
    private func evaluate() {
        let presentation = model.presentation(at: Date())
        setEffects(visible: presentation.effectsVisible)
        if presentation.released {
            releaseScreen()
        } else if !presentation.isUp || presentation.opacity < 1 {
            fadePanelOut()
        }
    }

    /// The agent is waiting on something that is not the UI: fade the panel out and keep the
    /// session, so the next action or step brings it straight back.
    private func releaseScreen() {
        hotkey.unregister()
        guard let panelWindow, panelWindow.isVisible, !panelFading else { return }
        panelFading = true
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = OverlayModel.Constants.fadeOut
            panelWindow.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.panelFading else { return }
                self.panelFading = false
                if self.model.presentation(at: Date()).released { panelWindow.orderOut(nil) }
            }
        })
    }

    private func fadePanelOut() {
        guard let panelWindow, !panelFading, panelWindow.isVisible else {
            if panelWindow?.isVisible != true { finishSession() }
            return
        }
        panelFading = true
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = OverlayModel.Constants.fadeOut
            panelWindow.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            // AppKit calls this on the main thread; the closure is typed Sendable, so assert
            // rather than hop.
            MainActor.assumeIsolated {
                guard let self, self.panelFading else { return }
                let presentation = self.model.presentation(at: Date())
                // A new command may have arrived during the fade; only end a session still down.
                guard !presentation.isUp else {
                    self.panelFading = false
                    return
                }
                if presentation.released {
                    self.panelFading = false
                    panelWindow.orderOut(nil)
                    return
                }
                self.finishSession()
            }
        })
    }

    private func finishSession() {
        model.reset()
        hideEverything()
    }

    private func setEffects(visible: Bool) {
        guard visible != effectsShown else { return }
        effectsShown = visible
        if visible {
            if effectsWindow == nil { effectsWindow = makeEffectsWindow() }
            guard let effectsWindow else { return }
            effectsWindow.alphaValue = 0
            effectsWindow.orderFrontRegardless()
            ScreenCapture.excludeFromCaptures(windowNumber: effectsWindow.windowNumber)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Constants.effectsFade
                effectsWindow.animator().alphaValue = 1
            }
        } else if let effectsWindow {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = Constants.effectsFade
                effectsWindow.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, !self.effectsShown else { return }
                    effectsWindow.orderOut(nil)
                }
            })
        }
    }

    // MARK: - Windows

    private func makePanelWindow() {
        let root = PanelView(model: model)
            .environment(\.panelDraggable, true)
            .padding(Constants.panelMargin)
        let hosting = NSHostingView(rootView: AnyView(root))
        // The controller sizes the window itself, so a change of height can keep whichever edge
        // is nearer the screen's edge where it is.
        hosting.sizingOptions = []
        let window = PresencePanel(contentView: hosting)
        panelHost = hosting
        panelWindow = window
        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: window, queue: .main,
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.placingPanel, let frame = self.panelWindow?.frame else { return }
                PanelPlacement.remember(frame: frame)
            }
        }
        observePanelSize()
    }

    /// The panel's height follows the step list and the consent prompt; re-fit whenever what
    /// decides it changes.
    private func observePanelSize() {
        withObservationTracking {
            _ = model.panelExpanded
            _ = model.steps
            _ = model.consent
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.fitPanel(anchorBottom: nil)
                    self?.observePanelSize()
                }
            }
        }
    }

    /// Sizes the window to the panel. `anchorBottom: nil` keeps the edge nearer its screen edge
    /// fixed, so the step list opens upward from a panel at the bottom and downward from one
    /// at the top.
    private func fitPanel(anchorBottom: Bool?) {
        guard let panelWindow, let panelHost else { return }
        panelHost.layoutSubtreeIfNeeded()
        let size = panelHost.fittingSize
        guard size.width > 0, size.height > 0, size != panelWindow.frame.size else { return }
        var frame = panelWindow.frame
        let keepBottom = anchorBottom ?? {
            guard let screen = panelWindow.screen else { return true }
            return frame.midY < screen.frame.midY
        }()
        if !keepBottom { frame.origin.y = frame.maxY - size.height }
        frame.size = size
        placingPanel = true
        panelWindow.setFrame(frame, display: true)
        placingPanel = false
    }

    /// Puts the panel where the human last left it on the display they are looking at.
    private func placePanel() {
        guard let panelWindow, let screen = PanelPlacement.screenUnderPointer() else { return }
        let origin = PanelPlacement.origin(size: panelWindow.frame.size, on: screen)
        placingPanel = true
        panelWindow.setFrameOrigin(origin)
        placingPanel = false
    }

    private func makeEffectsWindow() -> NSWindow? {
        guard let screen = NSScreen.screens.first else { return nil }
        let window = NSWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: OverlayEffectsView(model: model))
        return window
    }
}
