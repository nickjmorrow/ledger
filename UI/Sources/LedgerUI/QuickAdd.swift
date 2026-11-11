import Foundation
import LedgerCore

/// Shorthand typed into a new issue's title: `due:tomorrow`, `p:high` and `#label` are taken out of the title and applied.
/// Anything that doesn't parse (an unknown label, `due:soon`) stays in the title untouched.
public struct QuickAdd: Equatable {
    public var title = ""
    public var due: String?
    public var priority: Int?
    public var labelIds: [String] = []

    public static func parse(_ text: String, labels: [Label], today: Date = Date()) -> QuickAdd {
        var out = QuickAdd()
        var kept: [Substring] = []
        for token in text.split(whereSeparator: \.isWhitespace) {
            let lower = token.lowercased()
            if lower.hasPrefix("due:"), let d = date(String(lower.dropFirst(4)), today: today) { out.due = d }
            else if lower.hasPrefix("p:"), let p = priority(String(lower.dropFirst(2))) { out.priority = p }
            else if lower.hasPrefix("#"), lower.count > 1, let l = labels.first(where: { slug($0.name) == String(lower.dropFirst()) }) {
                if !out.labelIds.contains(l.id) { out.labelIds.append(l.id) }
            } else { kept.append(token) }
        }
        out.title = kept.joined(separator: " ")
        return out
    }

    /// "Deep work" is written #deep-work.
    static func slug(_ name: String) -> String { name.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: "-") }

    static func priority(_ s: String) -> Int? {
        switch s {
        case "urgent", "1": return 1
        case "high", "2": return 2
        case "medium", "med", "3": return 3
        case "low", "4": return 4
        case "none", "0": return 0
        default: return nil
        }
    }

    static let weekdays = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]

    /// Days to the next given weekday (Sunday is 1), never today.
    static func daysUntil(weekday: Int, from d: Date) -> Int {
        let delta = (weekday - Calendar.current.component(.weekday, from: d) + 7) % 7
        return delta == 0 ? 7 : delta
    }

    /// today, tomorrow, a weekday (the next one), nextweek (next Monday), 3d, 2w, or 2026-11-20.
    static func date(_ s: String, today: Date) -> String? {
        let cal = Calendar.current
        func add(_ days: Int) -> String { Ledger.day(cal.date(byAdding: .day, value: days, to: today)!) }
        switch s {
        case "today": return Ledger.day(today)
        case "tomorrow", "tom", "tmrw": return add(1)
        case "nextweek": return add(daysUntil(weekday: 2, from: today))
        default: break
        }
        if s.count >= 3, let i = weekdays.firstIndex(where: { $0.hasPrefix(s) }) { return add(daysUntil(weekday: i + 1, from: today)) }
        if let unit = s.last, "dw".contains(unit), let n = Int(s.dropLast()), n >= 0 { return add(unit == "d" ? n : n * 7) }
        if s.count == 10, let d = Ledger.date(fromDay: s) { return Ledger.day(d) }
        return nil
    }
}
