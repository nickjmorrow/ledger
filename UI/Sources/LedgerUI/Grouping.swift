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
