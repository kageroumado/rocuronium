import Propofol
import SwiftUI

/// The showcase's pretend Mac: geometry every scene aims at, in top-left points on a
/// 1280 × 800 desktop.
enum MockLayout {
    static let desktop = CGSize(width: 1280, height: 800)
    static let menuBarHeight: CGFloat = 26
    static let windowTitleBar: CGFloat = 28
    static let safariToolbar: CGFloat = 52
    static let windowCornerRadius: CGFloat = 12

    static let safari = CGRect(x: 90, y: 74, width: 640, height: 470)
    static let notes = CGRect(x: 800, y: 112, width: 390, height: 290)
    static let terminal = CGRect(x: 110, y: 84, width: 660, height: 420)
    static let sketch = CGRect(x: 170, y: 66, width: 760, height: 500)

    static let signInLink = CGRect(x: 610, y: 138, width: 80, height: 24)
    static let emailField = CGRect(x: 250, y: 272, width: 320, height: 32)
    static let passwordField = CGRect(x: 250, y: 336, width: 320, height: 32)
    static let rememberBox = CGRect(x: 250, y: 384, width: 16, height: 16)
    static let signInButton = CGRect(x: 250, y: 418, width: 320, height: 36)
    static let notesDoneButton = CGRect(x: 1128, y: 120, width: 52, height: 22)
    static let notesTitle = CGRect(x: 820, y: 154, width: 340, height: 26)

    /// The mini-map of both displays, bottom-right beside the Dock.
    static let displayStrip = CGRect(x: 1032, y: 630, width: 232, height: 88)

    /// The panel's bottom edge: the live default, 20 pt above the Dock.
    static let panelBottom: CGFloat = 712
    static let dockHeight: CGFloat = 58
    static let dockBottomInset: CGFloat = 8
    /// Where the human's pointer rests when a scene starts.
    static let restingPointer = CGPoint(x: 980, y: 520)
}

/// The windows the showcase can put on its desktop.
enum MockWindowID: String, CaseIterable {
    case safari, notes, terminal, sketch

    var frame: CGRect {
        switch self {
        case .safari: MockLayout.safari
        case .notes: MockLayout.notes
        case .terminal: MockLayout.terminal
        case .sketch: MockLayout.sketch
        }
    }

    var title: String {
        switch self {
        case .safari: "Safari — Sign In"
        case .notes: "Notes"
        case .terminal: "Terminal — zsh"
        case .sketch: "Freeform — Logo"
        }
    }

    var appName: String {
        switch self {
        case .safari: "Safari"
        case .notes: "Notes"
        case .terminal: "Terminal"
        case .sketch: "Freeform"
        }
    }
}

/// Who is moving the showcase pointer: the agent's hardware tentacle, or the human.
enum PointerActor {
    case agent
    case human
}

/// Everything on the pretend desktop at one instant.
struct MockDesktopState {
    /// Back to front; the last is focused.
    var windows: [MockWindowID]
    var email = ""
    var passwordLength = 0
    var remember = false
    /// 0…1 brightness of the Sign In button's press.
    var signInPress = 0.0
    var signedIn = false
    var notesTitle = "Groceries"
    var notesText = ""
    var humanTyping = false
    var terminalLines: [String] = ["kiri@studio rocuronium % "]
    var buildProgress: Double?
    /// The stroke drawn so far, in desktop points.
    var stroke: [CGPoint] = []
    /// 0 on the built-in display, 1 parked on the virtual display.
    var notesParked = 0.0
    var pointer = MockLayout.restingPointer
    var pointerActor = PointerActor.human
    /// The human's hand is on the mouse right now; the pointer wears a "you" tag.
    var humanHandRecent = false
    /// A human click flashing under the pointer, 0…1.
    var humanClick = 0.0
}

// MARK: - Views

/// The pretend desktop: wallpaper, menu bar, windows, Dock, and the display mini-map.
struct MockDesktopView: View {
    let state: MockDesktopState
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack(alignment: .topLeading) {
            Wallpaper()
            ForEach(state.windows, id: \.self) { id in
                MockWindow(id: id, focused: id == state.windows.last, state: state)
                    .offset(x: windowOrigin(id).x, y: windowOrigin(id).y)
            }
            MockDock()
            DisplayStrip(state: state)
                .frame(width: MockLayout.displayStrip.width, height: MockLayout.displayStrip.height)
                .offset(x: MockLayout.displayStrip.minX, y: MockLayout.displayStrip.minY)
            MockMenuBar(app: state.windows.last?.appName ?? "Finder")
        }
        .frame(width: MockLayout.desktop.width, height: MockLayout.desktop.height, alignment: .topLeading)
        .clipped()
    }

    /// A parked window slides off the right edge onto the virtual display.
    private func windowOrigin(_ id: MockWindowID) -> CGPoint {
        var origin = id.frame.origin
        if id == .notes { origin.x += (MockLayout.desktop.width - origin.x + 40) * state.notesParked }
        return origin
    }
}

private struct Wallpaper: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            LinearGradient(
                colors: scheme == .dark
                    ? [Color(red: 0.06, green: 0.08, blue: 0.20), Color(red: 0.20, green: 0.10, blue: 0.30)]
                    : [Color(red: 0.74, green: 0.79, blue: 0.97), Color(red: 0.98, green: 0.84, blue: 0.80)],
                startPoint: .topLeading, endPoint: .bottomTrailing,
            )
            RadialGradient(
                colors: [(scheme == .dark ? Color(red: 0.35, green: 0.25, blue: 0.70) : Color.white).opacity(0.45), .clear],
                center: UnitPoint(x: 0.72, y: 0.30), startRadius: 0, endRadius: 520,
            )
        }
        .frame(width: MockLayout.desktop.width, height: MockLayout.desktop.height)
    }
}

private struct MockMenuBar: View {
    let app: String
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 18) {
            Image(systemName: "apple.logo")
            Text(app).fontWeight(.bold)
            ForEach(["File", "Edit", "View", "Window", "Help"], id: \.self) { Text($0) }
            Spacer()
            Image(systemName: "wifi")
            Image(systemName: "battery.75percent")
            Text("Wed Oct 7  9:41 PM")
        }
        .font(.system(size: 13))
        .foregroundStyle(scheme == .dark ? Color.white : Color.black.opacity(0.85))
        .padding(.horizontal, 16)
        .frame(width: MockLayout.desktop.width, height: MockLayout.menuBarHeight)
        .background((scheme == .dark ? Color.black : Color.white).opacity(0.28))
    }
}

private struct MockDock: View {
    @Environment(\.colorScheme) private var scheme
    private static let apps: [(String, Color)] = [
        ("face.smiling", .blue), ("safari", .cyan), ("note.text", .yellow),
        ("terminal", .gray), ("scribble.variable", .orange), ("gearshape", .gray), ("trash", .secondary),
    ]

    var body: some View {
        HStack(spacing: 10) {
            ForEach(Array(Self.apps.enumerated()), id: \.offset) { _, app in
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(app.1.gradient)
                    .frame(width: 44, height: 44)
                    .overlay(Image(systemName: app.0).font(.system(size: 20, weight: .medium)).foregroundStyle(.white))
            }
        }
        .padding(7)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill((scheme == .dark ? Color.black : Color.white).opacity(0.32))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.white.opacity(0.3), lineWidth: 0.5)),
        )
        .frame(width: MockLayout.desktop.width)
        .offset(y: MockLayout.desktop.height - MockLayout.dockHeight - MockLayout.dockBottomInset)
    }
}

/// A window: title bar with traffic lights, then the app's content.
private struct MockWindow: View {
    let id: MockWindowID
    let focused: Bool
    let state: MockDesktopState
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: MockLayout.windowCornerRadius, style: .continuous)
        VStack(spacing: 0) {
            titleBar
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: id.frame.width, height: id.frame.height)
        .background(shape.fill(body_))
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.primary.opacity(scheme == .dark ? 0.25 : 0.12), lineWidth: 0.5))
        .shadow(color: .black.opacity(focused ? 0.28 : 0.16), radius: focused ? 24 : 14, y: focused ? 12 : 6)
    }

    private var body_: Color {
        if id == .terminal { return scheme == .dark ? Color(white: 0.10) : Color(white: 0.98) }
        return scheme == .dark ? Color(white: 0.17) : Color.white
    }

    private var titleBar: some View {
        ZStack {
            HStack(spacing: 8) {
                ForEach([Color.red, .yellow, .green], id: \.self) { color in
                    Circle().fill(focused ? color.opacity(0.85) : Color.secondary.opacity(0.35)).frame(width: 12, height: 12)
                }
                Spacer()
            }
            Text(id.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(focused ? .primary : .secondary)
        }
        .padding(.horizontal, 12)
        .frame(height: MockLayout.windowTitleBar)
        .background(scheme == .dark ? Color(white: 0.22) : Color(white: 0.94))
    }

    @ViewBuilder private var content: some View {
        switch id {
        case .safari: SafariPage(state: state)
        case .notes: NotesPage(state: state)
        case .terminal: TerminalPage(state: state)
        case .sketch: SketchPage(state: state)
        }
    }
}

/// Places a view at an absolute desktop rect inside a window whose content starts below its title bar.
private extension View {
    func at(_ rect: CGRect, in window: CGRect) -> some View {
        frame(width: rect.width, height: rect.height)
            .offset(x: rect.minX - window.minX, y: rect.minY - window.minY - MockLayout.windowTitleBar)
    }
}

private struct SafariPage: View {
    let state: MockDesktopState
    @Environment(\.colorScheme) private var scheme
    private let window = MockLayout.safari

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            HStack(spacing: 6) {
                Image(systemName: "lock.fill").font(.system(size: 10))
                Text("accounts.example.com").font(.system(size: 12))
            }
            .foregroundStyle(.secondary)
            .frame(width: 300, height: 26)
            .background(Capsule().fill(Color.primary.opacity(0.07)))
            .offset(x: (window.width - 300) / 2, y: (MockLayout.safariToolbar - MockLayout.windowTitleBar - 26) / 2 - 2)
            Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 0.5)
                .offset(y: MockLayout.safariToolbar - MockLayout.windowTitleBar)
            if state.signedIn { welcome } else { form }
        }
    }

    private var form: some View {
        ZStack(alignment: .topLeading) {
            Text("Sign in to Example")
                .font(.system(size: 22, weight: .bold))
                .at(CGRect(x: MockLayout.emailField.minX, y: 196, width: 320, height: 30), in: window)
            Text("Sign in").font(.system(size: 12, weight: .medium)).foregroundStyle(.blue)
                .at(MockLayout.signInLink, in: window)
            fieldLabel("Email", above: MockLayout.emailField)
            field(state.email.isEmpty ? "name@example.com" : state.email, placeholder: state.email.isEmpty)
                .at(MockLayout.emailField, in: window)
            fieldLabel("Password", above: MockLayout.passwordField)
            field(String(repeating: "●", count: state.passwordLength), placeholder: false)
                .at(MockLayout.passwordField, in: window)
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(state.remember ? Color.blue : Color.clear)
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.secondary.opacity(0.6), lineWidth: 1))
                    .overlay(Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white).opacity(state.remember ? 1 : 0))
                    .frame(width: 16, height: 16)
                Text("Remember me").font(.system(size: 13))
            }
            .frame(width: 200, alignment: .leading)
            .at(CGRect(x: MockLayout.rememberBox.minX, y: MockLayout.rememberBox.minY, width: 200, height: 16), in: window)
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.blue.mix(with: .black, by: 0.25 * state.signInPress))
                .overlay(Text("Sign In").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white))
                .at(MockLayout.signInButton, in: window)
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Welcome back, Kiri").font(.system(size: 24, weight: .bold))
            Text("Your dashboard is ready.").foregroundStyle(.secondary)
            HStack(spacing: 12) {
                ForEach(0 ..< 3, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 10).fill([Color.blue, .purple, .teal][index].opacity(0.18))
                        .frame(width: 150, height: 90)
                }
            }
        }
        .at(CGRect(x: 160, y: 200, width: 500, height: 200), in: window)
    }

    private func fieldLabel(_ text: String, above field: CGRect) -> some View {
        Text(text).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            .frame(width: field.width, alignment: .leading)
            .at(CGRect(x: field.minX, y: field.minY - 20, width: field.width, height: 16), in: window)
    }

    private func field(_ text: String, placeholder: Bool) -> some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(placeholder ? .tertiary : .primary)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(scheme == .dark ? 0.10 : 0.04)))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.primary.opacity(0.18), lineWidth: 1))
    }
}

private struct NotesPage: View {
    let state: MockDesktopState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(state.notesTitle).font(.system(size: 18, weight: .bold))
                Spacer()
                Text("Done").font(.system(size: 12, weight: .medium)).foregroundStyle(.orange)
            }
            (Text(state.notesText) + Text(state.humanTyping ? "|" : "").foregroundColor(.orange))
                .font(.system(size: 13))
                .lineSpacing(3)
            if state.humanTyping {
                HumanTag(text: "you, typing")
            }
        }
        .padding(16)
    }
}

private struct TerminalPage: View {
    let state: MockDesktopState

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(state.terminalLines.enumerated()), id: \.offset) { _, line in
                Text(line)
            }
            if let progress = state.buildProgress {
                let filled = Int(progress * 30)
                Text("[\(String(repeating: "=", count: filled))>\(String(repeating: " ", count: 30 - filled))] \(Int(progress * 100))%")
                    .foregroundStyle(.green)
            }
        }
        .font(.system(size: 12, design: .monospaced))
        .padding(12)
    }
}

private struct SketchPage: View {
    let state: MockDesktopState
    private let window = MockLayout.sketch

    var body: some View {
        Canvas { context, size in
            for x in stride(from: 12.0, to: size.width, by: 24) {
                for y in stride(from: 12.0, to: size.height, by: 24) {
                    context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 2, height: 2)), with: .color(.secondary.opacity(0.35)))
                }
            }
            guard state.stroke.count > 1 else { return }
            var path = Path()
            let origin = CGPoint(x: window.minX, y: window.minY + MockLayout.windowTitleBar)
            path.addLines(state.stroke.map { CGPoint(x: $0.x - origin.x, y: $0.y - origin.y) })
            context.stroke(path, with: .color(Theme.agent), style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
        }
    }
}

/// A small tag marking what the human is doing, so a still frame tells their input from the agent's.
struct HumanTag: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color(red: 0.20, green: 0.45, blue: 0.85)))
    }
}

/// The mini-map of the built-in display and the virtual one beside it.
private struct DisplayStrip: View {
    let state: MockDesktopState
    @Environment(\.colorScheme) private var scheme
    private static let scale = 96.0 / MockLayout.desktop.width

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("DISPLAYS").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                screen(title: "Built-in", virtual: false)
                screen(title: "Virtual", virtual: true)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill((scheme == .dark ? Color.black : Color.white).opacity(0.55)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
    }

    private func screen(title: String, virtual: Bool) -> some View {
        let size = CGSize(width: MockLayout.desktop.width * Self.scale, height: MockLayout.desktop.height * Self.scale)
        return VStack(spacing: 2) {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(virtual ? Color.primary.opacity(0.05) : Color.blue.opacity(0.18))
                    .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(
                        Color.primary.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: virtual ? [3, 2] : []),
                    ))
                ForEach(state.windows, id: \.self) { id in
                    if let rect = miniRect(id, virtual: virtual) {
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(id == .notes ? Color.yellow.opacity(0.9) : Color.primary.opacity(0.35))
                            .frame(width: rect.width, height: rect.height)
                            .offset(x: rect.minX, y: rect.minY)
                    }
                }
            }
            .frame(width: size.width, height: size.height)
            .clipped()
            Text(title).font(.system(size: 9)).foregroundStyle(.secondary)
        }
    }

    /// The window's rect in one display's mini-map, or nil when none of it is on that display.
    private func miniRect(_ id: MockWindowID, virtual: Bool) -> CGRect? {
        let parked = id == .notes ? state.notesParked : 0
        var frame = id.frame
        // On the strip the window travels across both displays laid side by side.
        let travel = MockLayout.desktop.width - frame.minX + 60
        frame.origin.x += travel * parked
        if virtual { frame.origin.x -= MockLayout.desktop.width }
        let scaled = CGRect(x: frame.minX * Self.scale, y: frame.minY * Self.scale, width: frame.width * Self.scale, height: frame.height * Self.scale)
        let bounds = CGRect(origin: .zero, size: CGSize(width: MockLayout.desktop.width * Self.scale, height: MockLayout.desktop.height * Self.scale))
        return scaled.intersects(bounds) ? scaled : nil
    }
}

/// The pretend pointer: the system arrow, tagged when the human is the one moving it.
struct MockPointer: View {
    let state: MockDesktopState

    var body: some View {
        ZStack(alignment: .topLeading) {
            if state.humanClick > 0 {
                Circle()
                    .stroke(Color(red: 0.20, green: 0.45, blue: 0.85).opacity(1 - state.humanClick), lineWidth: 2)
                    .frame(width: 10 + 26 * state.humanClick, height: 10 + 26 * state.humanClick)
                    .offset(x: -(5 + 13 * state.humanClick), y: -(5 + 13 * state.humanClick))
            }
            Arrow()
                .fill(Color.black)
                .overlay(Arrow().stroke(Color.white, lineWidth: 1.3))
                .frame(width: 13, height: 20)
                .shadow(color: .black.opacity(0.3), radius: 1.5, y: 1)
            if state.pointerActor == .human, state.humanHandRecent {
                HumanTag(text: "you").offset(x: 14, y: 20)
            }
        }
        .offset(x: state.pointer.x, y: state.pointer.y)
    }

    private struct Arrow: Shape {
        func path(in _: CGRect) -> Path {
            var path = Path()
            path.addLines([
                CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 17), CGPoint(x: 4.2, y: 13.2), CGPoint(x: 7, y: 19.5),
                CGPoint(x: 9.6, y: 18.4), CGPoint(x: 6.9, y: 12.2), CGPoint(x: 12.4, y: 12.2),
            ])
            path.closeSubpath()
            return path
        }
    }
}
