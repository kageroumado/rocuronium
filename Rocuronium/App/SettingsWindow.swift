import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController {
    private var window: NSWindow?

    func show() {
        if let window, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }

        let view = SettingsView()
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = "Rocuronium Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: 520, height: 460))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        self.window = window
    }
}

struct SettingsView: View {
    @State private var category: SettingsCategory = .models

    var body: some View {
        NavigationSplitView {
            List(SettingsCategory.allCases, selection: $category) { category in
                Label {
                    Text(category.title)
                } icon: {
                    Image(systemName: category.icon)
                        .foregroundStyle(Color.accentColor)
                }
                .tag(category)
            }
            .toolbar(removing: .sidebarToggle)
            .navigationTitle("Settings")
            .frame(minWidth: 150)
        } detail: {
            Group {
                switch category {
                case .models: ModelSettingsView()
                case .about: AboutSettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(category.title)
        }
        .navigationSplitViewStyle(.balanced)
    }
}

enum SettingsCategory: String, CaseIterable, Identifiable {
    case models
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .models: "Models"
        case .about: "About"
        }
    }

    var icon: String {
        switch self {
        case .models: "cpu.fill"
        case .about: "info.circle.fill"
        }
    }
}

struct AboutSettingsView: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 72, height: 72)
            Text("Rocuronium")
                .font(.system(size: 18, weight: .bold))
            Text("Vision and hands for your AI — version \(Self.version)")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack(spacing: 14) {
                Link(
                    "made by kageroumado \(Image(systemName: "arrow.up.right"))",
                    destination: URL(string: "https://kagerou.glass")!
                )
                Link(
                    "GitHub \(Image(systemName: "arrow.up.right"))",
                    destination: URL(string: "https://github.com/kageroumado/rocuronium")!
                )
            }
            .font(.system(size: 12))
        }
        .padding(.vertical, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String ?? "dev"
    }
}
