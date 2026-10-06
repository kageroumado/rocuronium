import Foundation

/// How a `--label` query is matched against an element, and how a single target is picked from
/// the matches. Pure: it sees strings, never elements, so the tier and preference rules are
/// unit-testable without a live accessibility tree.
///
/// Two tiers, in one walk: the element's **name** (title, description, placeholder, role
/// description, or the label derived from a control's row) and, only when no name matched, its
/// **value**. Within the winning tier a match is either *exact* (the whole string, case- and
/// surrounding-whitespace-insensitive) or a *substring*.
///
/// `exact` mode keeps exact matches only. Substring mode keeps both, and when that leaves
/// several candidates of which exactly one matches exactly, resolution prefers that one:
/// `符合` names the option `符合` even though `不符合` and the question text contain it too.
nonisolated enum LabelMatching {
    /// How one element answered the query.
    struct Classification: Equatable, Sendable {
        enum Tier: Int, Sendable { case name, value }
        let tier: Tier
        let exact: Bool
    }

    /// Which rule picked the single target — reported to the caller as `matchedBy`.
    enum MatchedBy: String, Sendable {
        /// The only candidate in its tier.
        case only
        /// One of several substring matches, chosen because it alone matched exactly.
        case exact
    }

    enum Pick: Equatable, Sendable {
        case none
        case one(index: Int, matchedBy: MatchedBy)
        case ambiguous(indices: [Int])
    }

    /// Case-folded and trimmed — the form both sides are compared in.
    static func normalize(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// How an element with these names and this value answers `needle`; nil when it does not.
    /// `names` are the element's own label candidates, in any order; empty strings never match.
    static func classify(names: [String], value: String?, needle: String, exactOnly: Bool) -> Classification? {
        let wanted = normalize(needle)
        guard !wanted.isEmpty else { return nil }
        let folded = names.map(normalize).filter { !$0.isEmpty }
        if folded.contains(wanted) { return .init(tier: .name, exact: true) }
        if !exactOnly, folded.contains(where: { $0.contains(wanted) }) { return .init(tier: .name, exact: false) }
        guard let value else { return nil }
        let foldedValue = normalize(value)
        guard !foldedValue.isEmpty else { return nil }
        if foldedValue == wanted { return .init(tier: .value, exact: true) }
        if !exactOnly, foldedValue.contains(wanted) { return .init(tier: .value, exact: false) }
        return nil
    }

    /// The candidates a search reports: the name tier when any name matched, the value tier
    /// otherwise. Indices into `classifications`, in their original order.
    static func tier(_ classifications: [Classification?]) -> [Int] {
        let names = classifications.indices.filter { classifications[$0]?.tier == .name }
        if !names.isEmpty { return names }
        return classifications.indices.filter { classifications[$0]?.tier == .value }
    }

    /// One target from a set of classified candidates, or the ambiguity. The tier rule first;
    /// then, among several, the one exact match if there is exactly one. Two exact matches stay
    /// ambiguous — the rule prefers the unique whole-string answer, it never guesses between
    /// two of them.
    static func pick(_ classifications: [Classification?]) -> Pick {
        let candidates = tier(classifications)
        guard let first = candidates.first else { return .none }
        guard candidates.count > 1 else { return .one(index: first, matchedBy: .only) }
        let exact = candidates.filter { classifications[$0]?.exact == true }
        if exact.count == 1 { return .one(index: exact[0], matchedBy: .exact) }
        return .ambiguous(indices: candidates)
    }
}
