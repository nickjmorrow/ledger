import Foundation
import GRDB

/// One row as it travels: the common columns plus every data column.
public struct SyncRow: Codable, Sendable, Equatable {
    public var table: String
    public var id: String
    public var ts: Int64
    public var device: String
    public var deleted: Bool
    public var seq: Int64?
    public var fields: [String: SyncValue]
}

public struct SyncReport: Codable, Sendable, Equatable {
    public var pushed = 0
    public var pulled = 0
    public init() {}
}

/// How a device talks to the hub: over HTTP in the apps, in-process in tests.
public protocol SyncTransport: Sendable {
    func pull(since: Int64) async throws -> [SyncRow]
    func push(device: String, rows: [SyncRow]) async throws
}

extension Ledger {
    // MARK: reading rows

    static func syncRow(_ t: Table, _ row: Row) -> SyncRow {
        var fields: [String: SyncValue] = [:]
        for c in t.columns { fields[c.name] = SyncValue.fromDatabaseValue(row[c.name]) ?? .null }
        return SyncRow(table: t.rawValue, id: row["id"], ts: row["ts"], device: row["device"], deleted: (row["deleted"] as Int64) != 0, seq: row["seq"], fields: fields)
    }

    func dirtyRows() throws -> [SyncRow] {
        try db.read { db in try Table.allCases.flatMap { t in try Row.fetchAll(db, sql: "SELECT * FROM \"\(t.rawValue)\" WHERE dirty = 1 ORDER BY ts").map { Ledger.syncRow(t, $0) } } }
    }

    // MARK: applying rows

    /// Takes a row from the other side. Returns false when ours wins and is kept.
    @discardableResult
    func apply(_ r: SyncRow, as role: SyncRole, in db: Database) throws -> Bool {
        guard let t = Table(rawValue: r.table) else { throw LedgerError.invalid("unknown table \(r.table)") }
        let known = t.dataColumnNames
        if let bad = r.fields.keys.first(where: { !known.contains($0) }) { throw LedgerError.invalid("unknown field \(bad) on \(r.table)") }
        try Ledger.observe(r.ts, db)
        let local = try Row.fetchOne(db, sql: "SELECT * FROM \"\(t.rawValue)\" WHERE id = ?", arguments: [r.id])
        var fields = r.fields
        var keepLocal = false
        if let local {
            let (lts, ldev): (Int64, String) = (local["ts"], local["device"])
            let localDirty = (local["dirty"] as Int64) == 1
            let incomingWins = (r.ts, r.device) > (lts, ldev)
            switch role {
            case .hub: keepLocal = !incomingWins
            case .device: keepLocal = localDirty && !incomingWins
            }
            if t == .issues {
                // An issue's number is assigned once, by the hub, and is never lost to an edit that was made before it existed.
                if let n = local["number"] as Int64?, fields["number"] == .null || fields["number"] == nil { fields["number"] = .int(n) }
                else if keepLocal, let n = r.fields["number"]?.integer, (local["number"] as Int64?) == nil {
                    try db.execute(sql: "UPDATE issues SET number = ? WHERE id = ?", arguments: [n, r.id])
                }
            }
        }
        if keepLocal { return false }
        let keys = fields.keys.sorted()
        let cols = (["id", "ts", "device", "deleted", "seq", "dirty"] + keys.map { "\"\($0)\"" }).joined(separator: ", ")
        let marks = Array(repeating: "?", count: keys.count + 6).joined(separator: ", ")
        var args: [DatabaseValueConvertible?] = [r.id, r.ts, r.device, r.deleted ? 1 : 0, r.seq, 0]
        args += keys.map { fields[$0]! }
        try db.execute(sql: "INSERT OR REPLACE INTO \"\(t.rawValue)\" (\(cols)) VALUES (\(marks))", arguments: StatementArguments(args))
        return true
    }

    enum SyncRole { case hub, device }

    // MARK: device side

    /// Pushes what changed here, then pulls what changed there. Last writer wins, per row.
    public func sync(with transport: any SyncTransport) async throws -> SyncReport {
        var report = SyncReport()
        let outgoing = try dirtyRows()
        if !outgoing.isEmpty {
            try await transport.push(device: device, rows: outgoing)
            // Rows edited again while the push was in flight stay dirty for next time.
            try await db.write { db in
                for r in outgoing {
                    try db.execute(sql: "UPDATE \"\(r.table)\" SET dirty = 0 WHERE id = ? AND ts = ?", arguments: [r.id, r.ts])
                }
            }
            report.pushed = outgoing.count
        }
        var cursor = Int64(try meta("hubSeq") ?? "0") ?? 0
        while true {
            let rows = try await transport.pull(since: cursor)
            if rows.isEmpty { break }
            try await db.write { db in for r in rows { try apply(r, as: .device, in: db) } }
            cursor = rows.compactMap(\.seq).max() ?? cursor
            try setMeta("hubSeq", String(cursor))
            report.pulled += rows.count
            if rows.count < SyncHub.pageSize { break }
        }
        return report
    }
}

/// The hub numbers every change in one global order and applies each device's changes with the same last-writer-wins rule the
/// devices use. It is just a Ledger database plus this wrapper, so the `ledger` CLI can work on the hub's database directly.
public final class SyncHub: Sendable {
    public let ledger: Ledger
    public static let pageSize = 1000

    public init(ledger: Ledger) { self.ledger = ledger }

    public func head() throws -> Int64 {
        try ledger.db.read { db in try Table.allCases.map { try Int64.fetchOne(db, sql: "SELECT COALESCE(MAX(seq), 0) FROM \"\($0.rawValue)\"") ?? 0 }.max() ?? 0 }
    }

    private static func head(_ db: Database) throws -> Int64 {
        try Table.allCases.map { try Int64.fetchOne(db, sql: "SELECT COALESCE(MAX(seq), 0) FROM \"\($0.rawValue)\"") ?? 0 }.max() ?? 0
    }

    private static func nextNumber(_ db: Database) throws -> Int64 {
        (try Int64.fetchOne(db, sql: "SELECT COALESCE(MAX(number), 0) FROM issues") ?? 0) + 1
    }

    /// Gives every changed-here row its place in the order, and every issue without one a number.
    private func sequenceLocal(_ db: Database) throws {
        var head = try Self.head(db)
        for t in Table.allCases {
            for id in try String.fetchAll(db, sql: "SELECT id FROM \"\(t.rawValue)\" WHERE dirty = 1 ORDER BY ts") {
                head += 1
                try db.execute(sql: "UPDATE \"\(t.rawValue)\" SET seq = ?, dirty = 0 WHERE id = ?", arguments: [head, id])
            }
        }
        try numberIssues(db)
    }

    private func numberIssues(_ db: Database) throws {
        var head = try Self.head(db)
        for id in try String.fetchAll(db, sql: "SELECT id FROM issues WHERE number IS NULL AND deleted = 0 ORDER BY createdAt, ts") {
            head += 1
            let n = try Self.nextNumber(db)
            try db.execute(sql: "UPDATE issues SET number = ?, seq = ? WHERE id = ?", arguments: [n, head, id])
        }
    }

    public func pull(since: Int64, limit: Int = SyncHub.pageSize) throws -> [SyncRow] {
        try ledger.db.write { try sequenceLocal($0) }
        return try ledger.db.read { db in
            var rows: [SyncRow] = []
            for t in Table.allCases {
                rows += try Row.fetchAll(db, sql: "SELECT * FROM \"\(t.rawValue)\" WHERE seq > ? ORDER BY seq LIMIT ?", arguments: [since, limit]).map { Ledger.syncRow(t, $0) }
            }
            return Array(rows.sorted { ($0.seq ?? 0) < ($1.seq ?? 0) }.prefix(limit))
        }
    }

    /// Takes a device's rows. A row that loses to what the hub has is dropped; the device gets the winner on its next pull.
    public func push(device: String, rows: [SyncRow]) throws {
        try ledger.db.write { db in
            try sequenceLocal(db)
            var head = try Self.head(db)
            for r in rows where try ledger.apply(r, as: .hub, in: db) {
                head += 1
                try db.execute(sql: "UPDATE \"\(r.table)\" SET seq = ? WHERE id = ?", arguments: [head, r.id])
            }
            try numberIssues(db)
        }
    }
}

/// The hub's HTTP API as a pure function, so it can be tested without sockets.
///
///     POST /sync/pull?since=N    → [SyncRow]
///     POST /sync/push            {device, rows:[SyncRow]} → {}
public struct SyncHTTP: Sendable {
    public let hub: SyncHub
    /// Bearer token → a label for whoever holds it.
    public let tokens: [String: String]
    public static let maxBody = 64 * 1024 * 1024

    public init(hub: SyncHub, tokens: [String: String]) { self.hub = hub; self.tokens = tokens }

    public struct Response: Sendable {
        public var status: Int
        public var contentType = "application/json"
        public var body: Data
        public init(status: Int, contentType: String = "application/json", body: Data) { self.status = status; self.contentType = contentType; self.body = body }
    }

    struct PushBody: Codable { var device: String; var rows: [SyncRow] }

    public func isAuthorized(_ authorization: String?) -> Bool {
        guard let a = authorization, a.hasPrefix("Bearer ") else { return false }
        return tokens[String(a.dropFirst(7))] != nil
    }

    public func handle(method: String, path: String, query: [String: String], authorization: String?, body: Data) -> Response {
        guard isAuthorized(authorization) else { return text(401, "unauthorized") }
        do {
            switch (method, path) {
            case ("POST", "/sync/pull"):
                guard let since = Int64(query["since"] ?? "0") else { return text(400, "bad since") }
                return json(try hub.pull(since: since))
            case ("POST", "/sync/push"):
                guard let b = try? JSONDecoder().decode(PushBody.self, from: body) else { return text(400, "bad body") }
                try hub.push(device: b.device, rows: b.rows)
                return Response(status: 200, body: Data("{}".utf8))
            default: return text(404, "not found")
            }
        } catch { return text(500, "server error: \(error)") }
    }

    private func text(_ status: Int, _ s: String) -> Response { Response(status: status, contentType: "text/plain", body: Data(s.utf8)) }
    private func json<T: Encodable>(_ v: T) -> Response { Response(status: 200, body: (try? JSONEncoder().encode(v)) ?? Data("null".utf8)) }
}

public enum SyncHTTPError: Error, Equatable { case status(Int, String) }

/// Talks to a hub server with this device's bearer token.
public final class HTTPSyncTransport: SyncTransport, @unchecked Sendable {
    let base: URL, token: String, session: URLSession, hostHeader: String?

    /// `hostHeader` lets a device reach the hub by its tailnet IP while Tailscale's front door still routes by name.
    public init(baseURL: URL, token: String, hostHeader: String? = nil, session: URLSession = .shared) {
        base = baseURL; self.token = token; self.hostHeader = hostHeader; self.session = session
    }

    private func post(_ path: String, query: [URLQueryItem] = [], body: Data? = nil) async throws -> Data {
        var comps = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query }
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let hostHeader { req.setValue(hostHeader, forHTTPHeaderField: "Host") }
        req.httpBody = body
        req.timeoutInterval = 60
        let (data, resp) = try await session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw SyncHTTPError.status(status, String(decoding: data, as: UTF8.self)) }
        return data
    }

    public func pull(since: Int64) async throws -> [SyncRow] {
        try JSONDecoder().decode([SyncRow].self, from: try await post("sync/pull", query: [URLQueryItem(name: "since", value: String(since))]))
    }

    public func push(device: String, rows: [SyncRow]) async throws {
        _ = try await post("sync/push", body: try JSONEncoder().encode(SyncHTTP.PushBody(device: device, rows: rows)))
    }
}

/// In-process transport for tests.
public final class DirectTransport: SyncTransport, @unchecked Sendable {
    let hub: SyncHub
    public init(hub: SyncHub) { self.hub = hub }
    public func pull(since: Int64) async throws -> [SyncRow] { try hub.pull(since: since) }
    public func push(device: String, rows: [SyncRow]) async throws { try hub.push(device: device, rows: rows) }
}
