import Foundation
import GRDB

/// A column value as it travels between devices and the hub.
public enum SyncValue: Codable, Sendable, Equatable, DatabaseValueConvertible {
    case null
    case int(Int64)
    case double(Double)
    case text(String)

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Int64.self) { self = .int(v) }
        else if let v = try? c.decode(Double.self) { self = .double(v) }
        else { self = .text(try c.decode(String.self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case let .int(v): try c.encode(v)
        case let .double(v): try c.encode(v)
        case let .text(v): try c.encode(v)
        }
    }

    public var databaseValue: DatabaseValue {
        switch self {
        case .null: return .null
        case let .int(v): return v.databaseValue
        case let .double(v): return v.databaseValue
        case let .text(v): return v.databaseValue
        }
    }

    public static func fromDatabaseValue(_ dbValue: DatabaseValue) -> SyncValue? {
        switch dbValue.storage {
        case .null: return .null
        case let .int64(v): return .int(v)
        case let .double(v): return .double(v)
        case let .string(v): return .text(v)
        case .blob: return nil
        }
    }

    public var string: String? { if case let .text(s) = self { return s } else { return nil } }
    public var integer: Int64? { if case let .int(i) = self { return i } else { return nil } }
}

public enum LedgerError: Error, Equatable, CustomStringConvertible {
    case invalid(String)
    case notFound(String)

    public var description: String {
        switch self {
        case let .invalid(m), let .notFound(m): return m
        }
    }
}
