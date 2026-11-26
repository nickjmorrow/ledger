import Foundation
import LedgerCore

/// The list's shape: open work first (Today, Todo, Inbox), finished work last.
public enum IssueGrouping {
    public static let order: [Status] = [.today, .todo, .inbox, .done, .canceled, .duplicate]
    public static let collapsedByDefault: Set<Status> = [.done, .canceled, .duplicate]

    public struct Group: Identifiable, Equatable {
        public var status: Status
        public var issues: [Issue]
        public var id: Status { status }
    }

    public static func group(_ issues: [Issue], keepEmpty: Bool = false) -> [Group] {
        let by = Dictionary(grouping: issues, by: \.status)
        return order.compactMap { s in
            let items = sorted(by[s] ?? [], closed: s.isClosed)
            return items.isEmpty && !keepEmpty ? nil : Group(status: s, issues: items)
        }
    }

    /// Open: priority (urgent first, none last), then the stored order, then newest. Closed: most recently finished first.
    public static func sorted(_ issues: [Issue], closed: Bool) -> [Issue] {
        issues.sorted { a, b in
            if closed {
                let (x, y) = (a.completedAt ?? a.canceledAt ?? a.createdAt, b.completedAt ?? b.canceledAt ?? b.createdAt)
                return x != y ? x > y : (a.number ?? .max) > (b.number ?? .max)
            }
            let (pa, pb) = (rank(a.priority), rank(b.priority))
            if pa != pb { return pa < pb }
            if a.sortOrder != b.sortOrder { return a.sortOrder < b.sortOrder }
            return (a.number ?? .max) > (b.number ?? .max)
        }
    }

    static func rank(_ p: Int) -> Int { p == 0 ? 5 : p }
}

/// Which status columns a board shows, and in what order. Each screen keeps its own; hidden statuses can be shown again.
public enum BoardColumns {
    /// A cycle is planned work, so its board starts with just the working columns.
    public static func defaults(for key: String) -> [Status] {
        key == "cycle" ? [.todo, .today, .done] : IssueGrouping.order
    }

    public static func hidden(_ shown: [Status]) -> [Status] { IssueGrouping.order.filter { !shown.contains($0) } }

    /// `s` dropped on `target`'s place: after it when coming from its left, else before it (shown if it was hidden). Nil target: the end.
    public static func moving(_ s: Status, to target: Status?, in shown: [Status]) -> [Status] {
        guard s != target else { return shown }
        var c = shown.filter { $0 != s }
        guard let target, let to = c.firstIndex(of: target) else { c.append(s); return c }
        let fromLeft = (shown.firstIndex(of: s) ?? .max) < (shown.firstIndex(of: target) ?? 0)
        c.insert(s, at: fromLeft ? to + 1 : to)
        return c
    }

    /// `s` swapped with its neighbour `by` places away (-1 left, 1 right); unchanged at an edge.
    public static func shifting(_ s: Status, by: Int, in shown: [Status]) -> [Status] {
        guard let i = shown.firstIndex(of: s), shown.indices.contains(i + by) else { return shown }
        var c = shown
        c.swapAt(i, i + by)
        return c
    }
}
