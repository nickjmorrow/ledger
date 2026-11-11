import Foundation
import LedgerCore

public enum Fuzzy {
    /// nil when `query` doesn't match `text`; higher is better. Prefix beats word start beats substring beats scattered letters.
    public static func score(_ query: String, in text: String) -> Int? {
        let q = query.lowercased().filter { !$0.isWhitespace }, t = text.lowercased()
        if q.isEmpty { return 0 }
        if t.hasPrefix(q) { return 1000 - t.count }
        if let r = t.range(of: q) {
            let i = t.distance(from: t.startIndex, to: r.lowerBound)
            let wordStart = i == 0 || !t[t.index(t.startIndex, offsetBy: i - 1)].isLetter && !t[t.index(t.startIndex, offsetBy: i - 1)].isNumber
            return (wordStart ? 800 : 600) - i
        }
        var from = t.startIndex, first: Int?, last = 0
        for ch in q {
            guard let hit = t[from...].firstIndex(of: ch) else { return nil }
            let at = t.distance(from: t.startIndex, to: hit)
            if first == nil { first = at }
            last = at
            from = t.index(after: hit)
        }
        return max(1, 300 - (last - (first ?? 0)) - (first ?? 0))
    }
}

public struct PaletteItem: Identifiable {
    public enum Kind: String { case action, issue, project, label, view, cycle }
    public var id: String
    public var kind: Kind
    public var title: String
    public var subtitle = ""
    public var symbol: String
    /// An issue's number, so "123" and "mor-123" find it.
    public var number: Int?
    public var run: @MainActor () -> Void
}

public enum Palette {
    public static func rank(_ items: [PaletteItem], query: String, limit: Int = 40) -> [PaletteItem] {
        var q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if q.isEmpty { return Array(items.prefix(limit)) }
        if q.hasPrefix("mor-") { q = String(q.dropFirst(4)) } else if q.hasPrefix("#"), Int(q.dropFirst()) != nil { q = String(q.dropFirst()) }
        let digits = Int(q) != nil
        let scored: [(PaletteItem, Int)] = items.compactMap { item in
            if digits, let n = item.number {
                let s = String(n)
                if s == q { return (item, 2000) }
                if s.hasPrefix(q) { return (item, 1500 - s.count) }
            }
            guard let s = Fuzzy.score(q, in: item.title) ?? (item.subtitle.isEmpty ? nil : Fuzzy.score(q, in: item.subtitle).map { $0 / 2 }) else { return nil }
            return (item, s)
        }
        return scored.enumerated().sorted { ($0.element.1, -$0.offset) > ($1.element.1, -$1.offset) }.prefix(limit).map(\.element.0)
    }
}
