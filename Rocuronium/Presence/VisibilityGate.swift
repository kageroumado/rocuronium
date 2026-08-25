import AppKit
import SwiftUI

extension View {
    /// Sets `hidden` true while the hosting window can't be seen — closed, ordered
    /// out, or fully occluded — so an animation-driven `TimelineView` can hand its
    /// schedule a `paused:` flag.
    ///
    /// `TimelineView(.animation)` keeps producing frames for windows nobody can see:
    /// the popover's style swatches, the demo stage's gallery, and the overlay panel
    /// between sessions all kept drawing their Canvas art at 60fps into the void
    /// (~30% CPU with everything "closed"). Every 60fps art view pairs this with
    /// `.animation(minimumInterval:paused:)`:
    ///
    ///     @State private var hidden = false
    ///     TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: hidden)) { … }
    ///         .pausedWhileWindowHidden($hidden)
    func pausedWhileWindowHidden(_ hidden: Binding<Bool>) -> some View {
        background(WindowVisibilityReader(hidden: hidden))
    }
}

/// Tracks the hosting window through `viewDidMoveToWindow` and occlusion-state
/// notifications. `didChangeOcclusionStateNotification` fires for order-in/out and
/// close as well as actual occlusion, so one observer covers every way a window
/// stops being seen.
private struct WindowVisibilityReader: NSViewRepresentable {
    @Binding var hidden: Bool

    func makeNSView(context _: Context) -> TrackingView {
        let view = TrackingView()
        view.onChange = { visible in
            if hidden == visible {
                hidden = !visible
            }
        }
        return view
    }

    func updateNSView(_: TrackingView, context _: Context) {}

    final class TrackingView: NSView {
        var onChange: ((Bool) -> Void)?
        private var observer: (any NSObjectProtocol)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer {
                NotificationCenter.default.removeObserver(observer)
                self.observer = nil
            }
            guard let window else {
                report(false)
                return
            }
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification,
                object: window, queue: .main,
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.reportCurrentState()
                }
            }
            reportCurrentState()
        }

        private func reportCurrentState() {
            guard let window else {
                report(false)
                return
            }
            report(window.isVisible && window.occlusionState.contains(.visible))
        }

        /// Deferred: `viewDidMoveToWindow` can land mid view-update, and flipping
        /// SwiftUI state inside an update is undefined.
        private func report(_ visible: Bool) {
            DispatchQueue.main.async { [onChange] in
                onChange?(visible)
            }
        }

        deinit {
            if let observer {
                NotificationCenter.default.removeObserver(observer)
            }
        }
    }
}
