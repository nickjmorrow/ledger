import Foundation
import LedgerCore

public enum Format {
    private static let short: DateFormatter = { let f = DateFormatter(); f.dateFormat = "MMM d"; return f }()
    private static let long: DateFormatter = { let f = DateFormatter(); f.dateFormat = "MMM d, yyyy"; return f }()

    /// "Today", "Tomorrow", else "Nov 5" (with the year when it isn't this one).
    public static func due(_ day: String, today: String = Ledger.day()) -> String {
        if day == today { return "Today" }
        guard let d = Ledger.date(fromDay: day) else { return day }
        if let t = Ledger.date(fromDay: today), Calendar.current.date(byAdding: .day, value: 1, to: t) == d { return "Tomorrow" }
        return (day.prefix(4) == today.prefix(4) ? short : long).string(from: d)
    }

    public static func isOverdue(_ i: Issue, today: String = Ledger.day()) -> Bool {
        guard let d = i.dueDate, !i.status.isClosed else { return false }
        return d < today
    }

    public static func range(_ c: Cycle) -> String {
        guard let s = Ledger.date(fromDay: c.startsAt), let e = Ledger.date(fromDay: c.endsAt).flatMap({ Calendar.current.date(byAdding: .day, value: -1, to: $0) }) else { return "" }
        return "\(short.string(from: s)) – \(short.string(from: e))"
    }

    public static func ago(_ date: Date, now: Date = Date()) -> String {
        let s = Int(now.timeIntervalSince(date))
        if s < 10 { return "just now" }
        if s < 60 { return "\(s) s ago" }
        if s < 3600 { return "\(s / 60) min ago" }
        if s < 86400 { return "\(s / 3600) h ago" }
        return "\(s / 86400) d ago"
    }
}
