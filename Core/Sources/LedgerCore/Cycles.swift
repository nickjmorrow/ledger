import Foundation
import GRDB

/// Two-week cycles starting on Mondays, numbered from 29 = 2026-11-02 (Linear's numbering, so imported history lines up).
/// Rows have deterministic ids (`cycle-29`), so every device creating the same cycle converges on one row.
extension Ledger {
    static let anchorNumber = 29
    static let anchorStart = "2026-11-02"
    static let cycleDays = 14

    public static func cycleNumber(on day: String) -> Int {
        let cal = Calendar.current
        let a = date(fromDay: anchorStart)!, d = date(fromDay: day)!
        let days = cal.dateComponents([.day], from: a, to: d).day ?? 0
        return anchorNumber + Int((Double(days) / Double(cycleDays)).rounded(.down))
    }

    static func cycleDates(_ number: Int) -> (start: String, end: String) {
        let a = date(fromDay: anchorStart)!
        let start = Calendar.current.date(byAdding: .day, value: (number - anchorNumber) * cycleDays, to: a)!
        let end = Calendar.current.date(byAdding: .day, value: cycleDays, to: start)!
        return (day(start), day(end))
    }

    /// Makes sure the current and next cycles exist and moves unfinished work out of cycles that have ended. Safe to call often.
    @discardableResult
    public func rollCycles(today: String = Ledger.day()) throws -> Cycle {
        let n = Ledger.cycleNumber(on: today)
        return try db.write { db in
            for k in [n, n + 1] where try !(Bool.fetchOne(db, sql: "SELECT 1 FROM cycles WHERE id = ?", arguments: ["cycle-\(k)"]) ?? false) {
                let d = Ledger.cycleDates(k)
                try put(.cycles, id: "cycle-\(k)", ["number": .int(Int64(k)), "startsAt": .text(d.start), "endsAt": .text(d.end)], in: db)
            }
            let stale = try String.fetchAll(db, sql: """
                SELECT issues.id FROM issues JOIN cycles ON cycles.id = issues.cycleId
                WHERE issues.deleted = 0 AND issues.archivedAt IS NULL AND issues.status IN ('inbox','todo','today') AND cycles.endsAt <= ?
                """, arguments: [today])
            for id in stale { try put(.issues, id: id, ["cycleId": .text("cycle-\(n)")], in: db) }
            return try Cycle.fetchOne(db, sql: "SELECT * FROM cycles WHERE id = ?", arguments: ["cycle-\(n)"])!
        }
    }

    public func cycles() throws -> [Cycle] {
        try db.read { try Cycle.fetchAll($0, sql: "SELECT * FROM cycles WHERE deleted = 0 ORDER BY number DESC") }
    }
}
