import Foundation
import LedgerCore

/// What's typed into a new issue's title. Plain phrases are taken out of the title and applied: a date ("tomorrow", "next friday",
/// "in 3 days", "nov 30"), "high priority", and a repeat ("every 2 weeks", "weekly"). So is the shorthand `due:tomorrow`, `p:high`, `#label`.
/// A plain date or priority counts only at the end of the text, or after "due", "by" or "on", so "Plan Friday dinner" keeps its Friday.
/// Anything that doesn't parse (an unknown label, `due:soon`) stays in the title untouched.
public struct QuickAdd: Equatable {
    public var title = ""
    public var due: String?
    public var priority: Int?
    public var labelIds: [String] = []
    public var recurrence: Recurrence?

    /// What a plain phrase can set; the composer lets one be switched off so its words stay in the title.
    public enum Field: Hashable, Sendable { case due, priority, repeats }

    public static func parse(_ text: String, labels: [Label], today: Date = Date(), ignoring: Set<Field> = []) -> QuickAdd {
        var out = QuickAdd()
        var kept: [String] = []
        for token in text.split(whereSeparator: \.isWhitespace) {
            let lower = token.lowercased()
            if lower.hasPrefix("due:"), let d = date(String(lower.dropFirst(4)), today: today) { out.due = d }
            else if lower.hasPrefix("p:"), let p = priority(String(lower.dropFirst(2))) { out.priority = p }
            else if lower.hasPrefix("#"), lower.count > 1, let l = labels.first(where: { slug($0.name) == String(lower.dropFirst()) }) {
                if !out.labelIds.contains(l.id) { out.labelIds.append(l.id) }
            } else { kept.append(String(token)) }
        }

        /// False when the phrase's field is switched off, so the words are left alone.
        func take(_ found: Found) -> Bool {
            switch found {
            case .due(let d):
                if ignoring.contains(.due) { return false }
                out.due = d
            case .priority(let p):
                if ignoring.contains(.priority) { return false }
                out.priority = p
            case .repeats(let r, let firstDue):
                if ignoring.contains(.repeats) { return false }
                out.recurrence = r
                if out.due == nil { out.due = firstDue }
            }
            return true
        }
        func takeFromEnd() {
            var found = true
            while found {
                found = false
                let lower = kept.map { $0.lowercased() }
                for i in max(0, kept.count - longestPhrase)..<kept.count {
                    guard let m = phrase(lower, at: i, today: today), i + m.length == kept.count, take(m.found) else { continue }
                    kept.removeSubrange(i...)
                    found = true
                    break
                }
            }
        }
        takeFromEnd()
        var i = 0
        while i < kept.count {
            if let m = phrase(kept.map { $0.lowercased() }, at: i, today: today), m.anywhere, take(m.found) { kept.removeSubrange(i..<i + m.length) } else { i += 1 }
        }
        // Removing a marked phrase can leave a plain one at the end.
        takeFromEnd()
        out.title = kept.joined(separator: " ")
        return out
    }

    // MARK: plain phrases

    enum Found { case due(String), priority(Int), repeats(Recurrence, firstDue: String?) }
    /// `anywhere` is false for phrases that only count at the end of the text.
    struct Match { var length: Int; var found: Found; var anywhere: Bool }

    /// "on in 3 days" is the longest: a marker and three words.
    static let longestPhrase = 4
    static let dateMarkers = ["due", "by", "on"]
    static let priorityWords = ["urgent": 1, "high": 2, "medium": 3, "med": 3, "low": 4]
    static let repeatWords: [String: Recurrence.Unit] = ["daily": .day, "weekly": .week, "monthly": .month]
    static let months = ["january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december"]

    /// The phrase starting at word `i` of the lowercased words, if there is one.
    static func phrase(_ words: [String], at i: Int, today: Date) -> Match? {
        func word(_ k: Int) -> String { i + k < words.count ? words[i + k] : "" }
        if dateMarkers.contains(word(0)) {
            if let d = plainDate(words, at: i + 1, today: today) { return Match(length: d.length + 1, found: .due(d.day), anywhere: true) }
            if let day = date(word(1), today: today) { return Match(length: 2, found: .due(day), anywhere: true) }
            return nil
        }
        if word(0) == "every" {
            if let w = weekdays.firstIndex(of: word(1)) {
                let first = Ledger.day(Calendar.current.date(byAdding: .day, value: daysUntil(weekday: w + 1, from: today), to: today)!)
                return Match(length: 2, found: .repeats(Recurrence(every: .week), firstDue: first), anywhere: true)
            }
            var interval = 1, unitAt = 1
            if word(1) == "other" { interval = 2; unitAt = 2 } else if let n = Int(word(1)), n > 0 { interval = n; unitAt = 2 }
            guard let u = unit(word(unitAt)) else { return nil }
            return Match(length: unitAt + 1, found: .repeats(Recurrence(every: u, interval: interval), firstDue: nil), anywhere: true)
        }
        if let u = repeatWords[word(0)] { return Match(length: 1, found: .repeats(Recurrence(every: u), firstDue: nil), anywhere: false) }
        if word(1) == "priority", let p = priorityWords[word(0)] { return Match(length: 2, found: .priority(p), anywhere: false) }
        if let d = plainDate(words, at: i, today: today) { return Match(length: d.length, found: .due(d.day), anywhere: false) }
        return nil
    }

    /// day, days, week, weeks, month, months.
    static func unit(_ s: String) -> Recurrence.Unit? { Recurrence.Unit(rawValue: s.hasSuffix("s") ? String(s.dropLast()) : s) }

    /// A date in plain words starting at word `i`: today, tomorrow, friday, this friday, next friday (the one in next week), next week
    /// (its Monday), in 3 days, in a week, nov 30, november 30th, 11/30 or 2026-11-30. Month and day without a year mean the next such day.
    static func plainDate(_ words: [String], at i: Int, today: Date) -> (length: Int, day: String)? {
        let cal = Calendar.current
        func word(_ k: Int) -> String { i + k < words.count ? words[i + k] : "" }
        func add(_ n: Int, _ unit: Calendar.Component = .day) -> String { Ledger.day(cal.date(byAdding: unit, value: n, to: today)!) }
        func monthDay(_ month: Int, _ day: Int) -> String? {
            let year = cal.component(.year, from: today)
            for y in [year, year + 1] {
                guard let d = cal.date(from: DateComponents(year: y, month: month, day: day)), cal.component(.month, from: d) == month else { return nil }
                if Ledger.day(d) >= Ledger.day(today) { return Ledger.day(d) }
            }
            return nil
        }
        let a = word(0), b = word(1)
        if a == "today" { return (1, add(0)) }
        if a == "tomorrow" || a == "tmrw" { return (1, add(1)) }
        if let w = weekdays.firstIndex(of: a) { return (1, add(daysUntil(weekday: w + 1, from: today))) }
        if a == "this", let w = weekdays.firstIndex(of: b) { return (2, add(daysUntil(weekday: w + 1, from: today))) }
        if a == "next" {
            let nextMonday = daysUntil(weekday: 2, from: today)
            if b == "week" { return (2, add(nextMonday)) }
            // Sunday is index 0 and ends the week that starts on Monday.
            if let w = weekdays.firstIndex(of: b) { return (2, add(nextMonday + (w + 6) % 7)) }
        }
        if a == "in", let n = ["a", "an"].contains(b) ? 1 : Int(b), n > 0, let u = unit(word(2)) {
            return (3, add(n, [.day: .day, .week: .weekOfYear, .month: .month][u]!))
        }
        if a.count >= 3, let m = months.firstIndex(where: { $0.hasPrefix(a) }) {
            let digits = b.prefix(while: \.isNumber)
            if let day = Int(digits), ["", "st", "nd", "rd", "th"].contains(String(b.dropFirst(digits.count))), let d = monthDay(m + 1, day) { return (2, d) }
        }
        let slash = a.split(separator: "/", omittingEmptySubsequences: false)
        if slash.count == 2, let m = Int(slash[0]), let day = Int(slash[1]), let d = monthDay(m, day) { return (1, d) }
        if a.count == 10, let d = Ledger.date(fromDay: a) { return (1, Ledger.day(d)) }
        return nil
    }

    // MARK: shorthand

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
