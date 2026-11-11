import Foundation
import LedgerCore

public enum DueFilter: String, Codable, CaseIterable, Sendable {
    case overdue, today, week, any, noDate
    public var title: String { ["overdue": "Overdue", "today": "Due today", "week": "Due this week", "any": "Has a due date", "noDate": "No due date"][rawValue]! }
}

/// What the filter bar edits, and what a saved view stores as JSON in `views.filter`.
public struct ViewFilter: Codable, Equatable, Sendable {
    public var statuses: [String] = []
    public var labels: [String] = []
    public var priorities: [Int] = []
    public var project: String?
    public var due: DueFilter?
    public init() {}

    enum CodingKeys: String, CodingKey { case statuses, labels, priorities, project, due }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        statuses = try c.decodeIfPresent([String].self, forKey: .statuses) ?? []
        labels = try c.decodeIfPresent([String].self, forKey: .labels) ?? []
        priorities = try c.decodeIfPresent([Int].self, forKey: .priorities) ?? []
        project = try c.decodeIfPresent(String.self, forKey: .project)
        due = try? c.decodeIfPresent(DueFilter.self, forKey: .due)
    }

    public var isEmpty: Bool { self == ViewFilter() }

    public func encoded() -> String {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return (try? String(decoding: e.encode(self), as: UTF8.self)) ?? "{}"
    }

    /// Unreadable or empty JSON is an empty filter.
    public static func decode(_ json: String) -> ViewFilter { (try? JSONDecoder().decode(ViewFilter.self, from: Data(json.utf8))) ?? ViewFilter() }

    public func matches(_ i: Issue, today: String = Ledger.day()) -> Bool {
        if !statuses.isEmpty, !statuses.contains(i.status.rawValue) { return false }
        if !labels.isEmpty, Set(labels).isDisjoint(with: i.labels) { return false }
        if !priorities.isEmpty, !priorities.contains(i.priority) { return false }
        if let project, i.projectId != project { return false }
        switch due {
        case nil: break
        case .overdue?: if !Format.isOverdue(i, today: today) { return false }
        case .today?: if i.dueDate != today { return false }
        case .week?:
            guard let d = i.dueDate, let t = Ledger.date(fromDay: today) else { return false }
            if d > Ledger.day(Calendar.current.date(byAdding: .day, value: 7, to: t)!) { return false }
        case .any?: if i.dueDate == nil { return false }
        case .noDate?: if i.dueDate != nil { return false }
        }
        return true
    }
}
