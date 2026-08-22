import Foundation

/// What the agent did this session, one line per action, verdicts included.
///
/// A ring buffer rather than a file: the log answers "what just happened on my Mac" — the
/// popover shows the tail, the bezel narrates from the same entries, and the `activity` verb
/// hands them to an agent — not "what happened last month", which is the system log's job
/// (`ControlServer` already records every caller there).
@MainActor
@Observable
final class ActivityLog {
    struct Entry: Identifiable {
        let id = UUID()
        let date: Date
        /// The verb: "click", "type", "halt"…
        let action: String
        /// What it aimed at: "'Send' in Discord", "(512, 400)".
        let target: String
        /// The evidence verdict, or "refused"/"error" when the command never ran.
        let verdict: String
        let summary: String
    }

    private(set) var entries: [Entry] = []

    private static let capacity = 200

    func append(action: String, target: String, verdict: String, summary: String) {
        entries.append(Entry(date: Date(), action: action, target: target, verdict: verdict, summary: summary))
        if entries.count > Self.capacity {
            entries.removeFirst(entries.count - Self.capacity)
        }
    }

    func recent(_ count: Int) -> [Entry] {
        Array(entries.suffix(count))
    }
}
