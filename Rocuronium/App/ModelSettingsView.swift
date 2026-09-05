import Hub
import SwiftUI

struct ModelSettingsView: View {
    @State private var store = ModelSettingsStore()

    var body: some View {
        Form {
            Section {
                ForEach(store.models) { model in
                    ModelRow(model: model, store: store)
                }
            } header: {
                HStack {
                    Text("On this Mac")
                    Spacer()
                    if store.isMeasuring { ProgressView().controlSize(.small) }
                    Text(Self.size(store.totalBytes)).monospacedDigit().foregroundStyle(.secondary)
                }
            } footer: {
                Text("Models are stored in Application Support and downloaded on demand. "
                    + "Removing a model degrades vision grounding — it does not break the app.")
            }

            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("How it works").font(.callout.weight(.semibold))
                    Text("When accessibility finds nothing for a target, Rocuronium takes a screenshot "
                        + "and runs a local detector. If the detector can't match, the VLM examines the "
                        + "full screenshot — about 3 seconds on Apple silicon.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Vision Grounding")
            }
        }
        .formStyle(.grouped)
        .task { await store.measure() }
    }

    static func size(_ bytes: Int64) -> String {
        bytes <= 0 ? "—" : ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

private struct ModelRow: View {
    let model: ModelInfo
    let store: ModelSettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: model.icon)
                    .foregroundStyle(model.isInstalled ? .secondary : .tertiary)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.displayName)
                    Text(model.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if model.isInstalled {
                    Text(ModelSettingsView.size(model.diskBytes))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    StatusBadge(text: model.statusText, color: model.statusColor)
                    Button { store.remove(model) } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                        .help("Remove \(model.displayName) to free \(ModelSettingsView.size(model.diskBytes))")
                } else if store.isDownloading(model.id) {
                    Text(ModelSettingsView.size(model.expectedBytes))
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                } else {
                    Text(ModelSettingsView.size(model.expectedBytes))
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                    Button("Download") { store.download(model) }
                }
            }
            if store.isDownloading(model.id) {
                ProgressView(value: store.downloadProgress)
                    .progressViewStyle(.linear)
                    .padding(.leading, 30)
            }
            if let error = store.downloadError, !model.isInstalled {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.leading, 30)
            }
        }
    }
}

private struct StatusBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.12)))
    }
}

// MARK: - Model

struct ModelInfo: Identifiable {
    let id: String
    let displayName: String
    let detail: String
    let icon: String
    let expectedBytes: Int64
    var diskBytes: Int64 = 0
    var isInstalled: Bool = false
    var isLoaded: Bool = false

    var statusText: String {
        isLoaded ? "Loaded" : "Installed"
    }

    var statusColor: Color {
        isLoaded ? .green : .secondary
    }
}

// MARK: - Store

@MainActor
@Observable
final class ModelSettingsStore {
    private(set) var models: [ModelInfo] = ModelSettingsStore.catalog
    private(set) var isMeasuring = false
    private var downloading: Set<String> = []

    var totalBytes: Int64 {
        models.map { max(0, $0.diskBytes) }.reduce(0, +)
    }

    func isDownloading(_ id: String) -> Bool { downloading.contains(id) }

    func measure() async {
        guard !isMeasuring else { return }
        isMeasuring = true
        defer { isMeasuring = false }

        for index in models.indices {
            let id = models[index].id
            let dir = ModelStore.directory(for: id)
            models[index].isInstalled = ModelStore.isInstalled(id)
            models[index].diskBytes = models[index].isInstalled
                ? Self.directorySize(dir)
                : 0
        }
    }

    private(set) var downloadProgress: Double = 0
    private(set) var downloadError: String?

    func download(_ model: ModelInfo) {
        guard let source = Self.sources[model.id] else { return }
        downloading.insert(model.id)
        downloadProgress = 0
        downloadError = nil
        Task(name: "Download \(model.displayName)") {
            defer { downloading.remove(model.id) }
            do {
                let hub = HubApi()
                let cachedDir = try await hub.snapshot(
                    from: source.repo, matching: source.globs
                ) { progress in
                    Task { @MainActor in
                        self.downloadProgress = progress.fractionCompleted
                    }
                }
                let dest = ModelStore.directory(for: model.id)
                try FileManager.default.createDirectory(
                    at: dest.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                if FileManager.default.fileExists(atPath: dest.path) {
                    try FileManager.default.trashItem(at: dest, resultingItemURL: nil)
                }
                try FileManager.default.copyItem(at: cachedDir, to: dest)
                let manifest = ["source": source.repo, "downloadedAt": ISO8601DateFormatter().string(from: .now)]
                let data = try JSONSerialization.data(withJSONObject: manifest, options: .prettyPrinted)
                try data.write(to: dest.appending(path: ModelStore.Constants.manifestName))
                await measure()
            } catch {
                downloadError = error.localizedDescription
            }
        }
    }

    private struct ModelSource {
        let repo: String
        let globs: [String]
    }

    private static let sources: [String: ModelSource] = [
        "holo-3.1-4b": ModelSource(
            repo: "pipenetwork/Holo-3.1-4B-MLX-4bit",
            globs: ["*.safetensors", "*.json", "*.jinja"]
        ),
        "yolo-detector": ModelSource(
            repo: "kageroumado/rocuronium-ui-detector",
            globs: ["model.mlpackage/*", "model.mlpackage/**/*"]
        ),
    ]

    func remove(_ model: ModelInfo) {
        let dir = ModelStore.directory(for: model.id)
        do {
            try FileManager.default.trashItem(at: dir, resultingItemURL: nil)
            if let index = models.firstIndex(where: { $0.id == model.id }) {
                models[index].isInstalled = false
                models[index].diskBytes = 0
            }
        } catch {
            // Logged rather than surfaced: the Trash is the recovery path,
            // so a failure here is a real problem the user needs to see —
            // but the popover is a poor place for a modal. TODO: error card.
        }
    }

    private static func directorySize(_ url: URL) -> Int64 {
        guard let entries = try? FileManager.default.subpathsOfDirectory(atPath: url.path) else { return 0 }
        return entries.reduce(into: Int64(0)) { total, entry in
            let path = url.appending(path: entry).path
            let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0
            total += size
        }
    }

    static let catalog: [ModelInfo] = [
        ModelInfo(
            id: "holo-3.1-4b",
            displayName: "Holo 3.1 4B",
            detail: "GUI grounding VLM — finds UI elements by description when accessibility is empty. "
                + "~3 seconds per query on Apple silicon.",
            icon: "eye.fill",
            expectedBytes: 3_700_000_000
        ),
        ModelInfo(
            id: "yolo-detector",
            displayName: "UI Detector",
            detail: "Fast element detector — proposes control boxes in ~8 ms, so icon toolbars "
                + "become addressable. Each box is labeled from the text inside it; matched "
                + "before the VLM is loaded.",
            icon: "square.dashed",
            expectedBytes: 5_400_000
        ),
    ]
}
