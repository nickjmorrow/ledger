import LedgerCore
import Foundation
import GRDB

enum SQLValue: Codable, Equatable {
    case null, int(Int64), double(Double), text(String)

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let i = try? c.decode(Int64.self) { self = .int(i) }
        else if let d = try? c.decode(Double.self) { self = .double(d) }
        else { self = .text(try c.decode(String.self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case let .int(i): try c.encode(i)
        case let .double(d): try c.encode(d)
        case let .text(s): try c.encode(s)
        }
    }
}

struct QueryResult: Codable, Equatable {
    var columns: [String]
    var rows: [[SQLValue]]
}

extension Ledger {
    /// Runs one read-only statement (SELECT or WITH ... SELECT) and returns at most `limit` rows.
    /// Anything that could write, and anything with more than one statement, is rejected.
    func query(sql: String, limit: Int = 500) throws -> QueryResult {
        let head = sql.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard head.hasPrefix("select") || head.hasPrefix("with") else {
            throw LedgerError.invalid("read-only: only SELECT statements are allowed")
        }
        return try db.read { db in
            let statement: Statement
            do { statement = try db.makeStatement(sql: sql) } catch {
                throw LedgerError.invalid("read-only: \(error)")
            }
            guard statement.isReadonly else { throw LedgerError.invalid("read-only: statement would write") }
            let columns = statement.columnNames
            var rows: [[SQLValue]] = []
            let cursor = try Row.fetchCursor(statement)
            while rows.count < limit, let row = try cursor.next() {
                rows.append(columns.indices.map { i in
                    let value: DatabaseValue = row[i]
                    switch value.storage {
                    case .null: return .null
                    case let .int64(v): return .int(v)
                    case let .double(v): return .double(v)
                    case let .string(v): return .text(v)
                    case let .blob(v): return .text("<blob \(v.count) bytes>")
                    }
                })
            }
            return QueryResult(columns: columns, rows: rows)
        }
    }
}
