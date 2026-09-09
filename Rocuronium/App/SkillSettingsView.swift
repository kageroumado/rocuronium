import SwiftUI

/// The agent skill pane: where the operator guide lives on this Mac, whether it matches this
/// build, and the one-click install into the user-level skills directory.
struct SkillSettingsView: View {
    @State private var state: EmbeddedSkill.InstallState = .notInstalled
    @State private var error: String?

    private var directory: URL { EmbeddedSkill.defaultInstallDirectory }

    var body: some View {
        Form {
            Section {
                LabeledContent("Status") {
                    Text(statusText).foregroundStyle(statusColor)
                }
                LabeledContent("Location") {
                    Text(directory.path)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Contents") {
                    Text("\(EmbeddedSkill.files.count) files — SKILL.md and \(EmbeddedSkill.referencePaths.count) references")
                        .foregroundStyle(.secondary)
                }
                if case let .outdated(paths) = state {
                    LabeledContent("Differs") {
                        Text(paths.joined(separator: ", "))
                            .font(.callout.monospaced())
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                HStack {
                    Button(state == .current ? "Reinstall" : (state == .notInstalled ? "Install" : "Update")) { install() }
                    if let error {
                        Text(error).font(.caption).foregroundStyle(.orange)
                    }
                }
            } header: {
                Text("Claude Code skill")
            } footer: {
                Text("The skill is the operator guide for an agent driving this Mac: the reply contract, "
                    + "targeting, acting, vision, plans, presence, and isolation. A harness that loads skills "
                    + "picks it up from this directory. Without it, `rocuronium guide` prints the same text.")
            }
        }
        .formStyle(.grouped)
        .task { refresh() }
    }

    private var statusText: String {
        switch state {
        case .notInstalled: "Not installed"
        case .current: "Installed, matches this build"
        case .outdated: "Installed, differs from this build"
        }
    }

    private var statusColor: Color {
        switch state {
        case .notInstalled: .secondary
        case .current: .green
        case .outdated: .orange
        }
    }

    private func refresh() {
        state = EmbeddedSkill.state(at: directory)
    }

    private func install() {
        do {
            try EmbeddedSkill.install(into: directory)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        refresh()
    }
}
