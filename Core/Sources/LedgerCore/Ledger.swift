import Foundation
import GRDB

/// One Ledger database: on the server it is the hub, on a device it is that device's copy.
public final class Ledger: @unchecked Sendable {
    public let db: DatabaseQueue
    public let device: String
    let clock: @Sendable () -> Int64

    public init(path: String, device: String? = nil, clock: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) throws {
        var config = Configuration()
        // The hub process and the CLI open the same file, so a second writer waits instead of failing.
        config.busyMode = .timeout(5)
        if path != ":memory:" { config.prepareDatabase { try $0.execute(sql: "PRAGMA journal_mode = WAL") } }
        db = path == ":memory:" ? try DatabaseQueue(configuration: config) : try DatabaseQueue(path: path, configuration: config)
        self.clock = clock
        try db.write { try Schema.migrate($0) }
        let name = try device ?? db.write { db -> String in
            if let d = try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = 'device'") { return d }
            let d = UUID().uuidString.lowercased()
            try db.execute(sql: "INSERT INTO meta (key, value) VALUES ('device', ?)", arguments: [d])
            return d
        }
        self.device = name
    }

    // MARK: clock

    /// A timestamp greater than anything this database has seen, so an edit made after receiving someone's work always beats it,
    /// even if this device's wall clock runs behind.
    func nextTimestamp(_ db: Database) throws -> Int64 {
        let last = try Int64.fetchOne(db, sql: "SELECT CAST(value AS INTEGER) FROM meta WHERE key = 'lamport'") ?? 0
        let ts = max(clock(), last + 1)
        try db.execute(sql: "INSERT OR REPLACE INTO meta (key, value) VALUES ('lamport', ?)", arguments: [String(ts)])
        return ts
    }

    static func observe(_ ts: Int64, _ db: Database) throws {
        let last = try Int64.fetchOne(db, sql: "SELECT CAST(value AS INTEGER) FROM meta WHERE key = 'lamport'") ?? 0
        if ts > last { try db.execute(sql: "INSERT OR REPLACE INTO meta (key, value) VALUES ('lamport', ?)", arguments: [String(ts)]) }
    }

    public func meta(_ key: String) throws -> String? {
        try db.read { try String.fetchOne($0, sql: "SELECT value FROM meta WHERE key = ?", arguments: [key]) }
    }

    public func setMeta(_ key: String, _ value: String) throws {
        try db.write { try $0.execute(sql: "INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)", arguments: [key, value]) }
    }

    // MARK: row writes

    /// Inserts a row or merges `fields` into it, stamping it as changed here and now. The one way data is written.
    @discardableResult
    func put(_ t: Table, id: String? = nil, _ fields: [String: SyncValue], in db: Database) throws -> String {
        let known = t.dataColumnNames
        if let bad = fields.keys.first(where: { !known.contains($0) }) { throw LedgerError.invalid("unknown field \(bad) on \(t.rawValue)") }
        let ts = try nextTimestamp(db)
        let rid = id ?? UUID().uuidString.lowercased()
        let exists = try Bool.fetchOne(db, sql: "SELECT 1 FROM \"\(t.rawValue)\" WHERE id = ?", arguments: [rid]) ?? false
        let keys = fields.keys.sorted()
        var args: [DatabaseValueConvertible?] = keys.map { fields[$0]! }
        if exists {
            let sets = (keys.map { "\"\($0)\" = ?" } + ["ts = ?", "device = ?", "dirty = 1"]).joined(separator: ", ")
            args += [ts, device, rid]
            try db.execute(sql: "UPDATE \"\(t.rawValue)\" SET \(sets) WHERE id = ?", arguments: StatementArguments(args))
        } else {
            let cols = (["id", "ts", "device", "dirty"] + keys.map { "\"\($0)\"" }).joined(separator: ", ")
            let marks = Array(repeating: "?", count: keys.count + 4).joined(separator: ", ")
            args = [rid, ts, device, 1] + args
            try db.execute(sql: "INSERT INTO \"\(t.rawValue)\" (\(cols)) VALUES (\(marks))", arguments: StatementArguments(args))
        }
        return rid
    }

    // MARK: dates

    public static func isoNow(_ date: Date = Date()) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }

    /// yyyy-MM-dd in the local calendar.
    public static func day(_ date: Date = Date()) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    public static func date(fromDay s: String) -> Date? {
        let p = s.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        return Calendar.current.date(from: DateComponents(year: p[0], month: p[1], day: p[2]))
    }
}
