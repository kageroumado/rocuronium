import AppKit
import SwiftUI

/// A deterministic practice target: one window whose controls exist to be driven.
///
/// Every mechanism the engine ships — ghost clicks, typed text, scrolling, hover motion,
/// drags — needs somewhere it can be exercised and *verified* without borrowing the user's
/// real windows. The stage is that somewhere: fixed position, fixed size, stable labels,
/// and every control instrumented with a read-back counter, so evidence has something
/// honest to read. `demo` over the socket (or the popover's button) opens it, reset.
@MainActor
final class DemoStageController {
    private var window: NSWindow?
    private var model = DemoStageModel()

    /// Where the stage always opens, in the top-left global coordinates the verbs speak.
    /// Fixed on purpose: deterministic tests can hard-code aim points.
    private static let origin = CGPoint(x: 720, y: 200)
    private static let size = CGSize(width: 560, height: 720)

    var isVisible: Bool { window?.isVisible ?? false }

    /// Shows the stage, optionally with fresh state. Never steals focus — the stage is for
    /// ghost verbs first, and `activate` exists for when focus is genuinely needed.
    func show(reset: Bool) {
        if reset {
            model = DemoStageModel()
            window?.contentView = nil
        }
        if window == nil || window?.contentView == nil {
            window = makeWindow()
        }
        window?.orderFrontRegardless()
    }

    func hide() {
        window?.orderOut(nil)
    }

    private func makeWindow() -> NSWindow {
        let window = self.window ?? {
            guard let screen = NSScreen.screens.first else {
                return NSWindow(
                    contentRect: NSRect(origin: .zero, size: Self.size),
                    styleMask: [.titled, .closable], backing: .buffered, defer: false,
                )
            }
            // The verbs speak top-left global coordinates; NSWindow speaks bottom-left.
            let cocoaY = screen.frame.height - Self.origin.y - Self.size.height
            let window = NSWindow(
                contentRect: NSRect(origin: CGPoint(x: Self.origin.x, y: cocoaY), size: Self.size),
                styleMask: [.titled, .closable], backing: .buffered, defer: false,
            )
            window.title = "Rocuronium Demo Stage"
            window.isReleasedWhenClosed = false
            return window
        }()
        window.contentView = NSHostingView(rootView: DemoStageView(model: model))
        return window
    }
}

/// The stage's state — every value both drives the UI and is exposed to accessibility, so
/// an action's consequence is always readable back.
@MainActor
@Observable
final class DemoStageModel {
    var clickCount = 0
    var typedText = ""
    var switchOn = false
    var sliderValue = 30.0
    var hoverCount = 0
    var dropCount = 0
}

private struct DemoStageView: View {
    @Bindable var model: DemoStageModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            Text("Demo Stage").font(.heroTitle)
            Text("Deterministic targets for every verb. Counters are the read-back.")
                .font(.caption).foregroundStyle(.secondary)

            HStack(spacing: Theme.Space.md) {
                Button("Tap Target") { model.clickCount += 1 }
                Text("clicks: \(model.clickCount)")
                    .font(.body.monospacedDigit())
                    .accessibilityIdentifier("click-count")
                Spacer()
                Toggle("Demo Switch", isOn: $model.switchOn)
                    .toggleStyle(.checkbox)
            }

            HStack(spacing: Theme.Space.md) {
                TextField("Type Here", text: $model.typedText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                Text("echo: \(model.typedText)")
                    .lineLimit(1)
            }

            HStack(spacing: Theme.Space.md) {
                Slider(value: $model.sliderValue, in: 0 ... 100) { Text("Demo Slider") }
                    .frame(width: 220)
                Text("slider: \(Int(model.sliderValue))")
                    .font(.body.monospacedDigit())
            }

            HStack(spacing: Theme.Space.md) {
                // A hover pad for `move`: entering it is the observable consequence. Backed
                // by an `.activeAlways` AppKit tracking area, because SwiftUI's `onHover`
                // only fires while the app is frontmost — and a deterministic stage must
                // count ghost-driven hovers without anyone stealing focus first.
                Text("Hover Pad")
                    .frame(width: 220, height: 44)
                    .background(Theme.innerShape.fill(Theme.agent.opacity(model.hoverCount > 0 ? 0.25 : 0.12)))
                    .background(AlwaysHoverTracker { model.hoverCount += 1 })
                Text("hovers: \(model.hoverCount)")
                    .font(.body.monospacedDigit())
            }

            Divider()

            // The presence gallery: every pose the jellyfish has, and the charge sigil on
            // a loop — the states on demand, without waiting for a session to produce them.
            HStack(alignment: .top, spacing: Theme.Space.md) {
                ForEach(
                    [
                        ("idle", OverlayModel.Phase.idle),
                        ("thinking", .thinking),
                        ("acting", .acting),
                        ("needs you", .needsHuman),
                    ],
                    id: \.0,
                ) { name, phase in
                    VStack(spacing: 2) {
                        JellyfishStateView(phase: phase)
                            .frame(width: 58, height: 74)
                        // Explicit: the strip is committed dark water, so adaptive
                        // secondary text would vanish into it in light mode.
                        Text(name).font(.caption2).foregroundStyle(.white.opacity(0.65))
                    }
                }
                VStack(spacing: 2) {
                    SigilPreviewView()
                        .frame(width: 74, height: 74)
                    Text("sigil").font(.caption2).foregroundStyle(.white.opacity(0.65))
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Theme.Space.xs)
            .background(Theme.innerShape.fill(Color(red: 0.06, green: 0.07, blue: 0.16)))

            Divider()

            // The scroll flume: 120 fixed rows, so scroll --until-text, AXScrollToVisible,
            // and bar writes all have known distances and a known needle. A plain VStack,
            // never LazyVStack: off-screen rows must exist in the AX tree, or there is no
            // off-screen element for AXScrollToVisible to be asked about.
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(1 ... 120, id: \.self) { row in
                        Text(row == 87 ? "Row 87 · the needle" : "Row \(row)")
                            .font(.callout.monospacedDigit())
                            .padding(.vertical, 1)
                    }
                }
                .padding(.horizontal, Theme.Space.sm)
            }
            .frame(maxHeight: .infinity)
            .background(Theme.innerShape.fill(Color.primary.opacity(0.04)))
        }
        .padding(Theme.Space.lg)
        .frame(width: 560, height: 720, alignment: .topLeading)
    }
}

/// An `.activeAlways` tracking area behind the hover pad: mouse-entered fires whether or
/// not this app is frontmost (measured 2026-08-20 — AppKit background tracking works,
/// SwiftUI's `onHover` does not).
private struct AlwaysHoverTracker: NSViewRepresentable {
    let onEnter: @MainActor () -> Void

    func makeNSView(context _: Context) -> TrackerView {
        let view = TrackerView()
        view.onEnter = onEnter
        return view
    }

    func updateNSView(_ view: TrackerView, context _: Context) {
        view.onEnter = onEnter
    }

    final class TrackerView: NSView {
        var onEnter: @MainActor () -> Void = {}

        override func updateTrackingAreas() {
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self,
            ))
            super.updateTrackingAreas()
        }

        override func mouseEntered(with _: NSEvent) {
            onEnter()
        }
    }
}
