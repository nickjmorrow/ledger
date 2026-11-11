import Foundation
import GRDB

public enum Status: String, Codable, CaseIterable, Sendable {
    case inbox, todo, today, done, canceled, duplicate

    public var isClosed: Bool { self == .done || self == .canceled || self == .duplicate }
    public var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
}

/// 0 means none; the rest sort urgent first.
public enum Priority: Int, Codable, CaseIterable, Sendable {
    case none = 0, urgent, high, medium, low
    public var title: String { ["No priority", "Urgent", "High", "Medium", "Low"][rawValue] }
}

public struct Recurrence: Codable, Sendable, Equatable {
    public enum Unit: String, Codable, Sendable { case day, week, month }
    public var every: Unit
    public var interval: Int
    public init(every: Unit, interval: Int = 1) { self.every = every; self.interval = interval }
}

public struct Issue: Codable, FetchableRecord, Sendable, Equatable, Identifiable {
    public var id: String
    public var number: Int?
    public var title: String
    public var description: String
    public var status: Status
    public var priority: Int
    public var dueDate: String?
    public var cycleId: String?
    public var projectId: String?
    public var parentId: String?
    public var labels: [String]
    public var recur: String?
    public var sortOrder: Double
    public var createdAt: String
    public var startedAt: String?
    public var completedAt: String?
    public var canceledAt: String?
    public var archivedAt: String?
    public var linearId: String?

    public var identifier: String { number.map { "MOR-\($0)" } ?? "MOR-?" }
    public var recurrence: Recurrence? { recur.flatMap { try? JSONDecoder().decode(Recurrence.self, from: Data($0.utf8)) } }
}

public struct Label: Codable, FetchableRecord, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var color: String
}

public struct Cycle: Codable, FetchableRecord, Sendable, Equatable, Identifiable {
    public var id: String
    public var number: Int
    public var startsAt: String
    public var endsAt: String
    public var title: String?
}

public struct Project: Codable, FetchableRecord, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var color: String
    public var description: String
    public var status: String
}

public struct SavedView: Codable, FetchableRecord, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var filter: String
    public var layout: String
    public var sortOrder: Double
}
