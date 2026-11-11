import Foundation
import GRDB

public struct IssueFilter: Sendable {
    public var statuses: Set<Status>?
    public var labelIds: [String] = []
    public var priorities: Set<Int>?
    public var projectId: String?
    public var cycleId: String?
    public var parentId: String?
    public var dueOnOrBefore: String?
    public var text: String?
    public var includeArchived = false
    public var limit = 500
    public init() {}
}

/// Everything the app, the CLI and Claude can do to issues, labels, projects and views.
extension Ledger {
    static let editableIssueFields: Set<String> = [
        "title", "description", "status", "priority", "dueDate", "cycleId", "projectId", "parentId", "labels", "recur",
        "sortOrder", "archivedAt", "linearId", "createdAt", "startedAt", "completedAt", "canceledAt", "number",
    ]

    // MARK: reads

    public func issues(_ f: IssueFilter = IssueFilter()) throws -> [Issue] {
        var where_ = ["issues.deleted = 0"]
        var args: [DatabaseValueConvertible?] = []
        if let s = f.statuses { where_.append("status IN (\(s.map { _ in "?" }.joined(separator: ",")))"); args += s.map(\.rawValue) }
        if !f.labelIds.isEmpty {
            where_.append("EXISTS (SELECT 1 FROM json_each(issues.labels) WHERE value IN (\(f.labelIds.map { _ in "?" }.joined(separator: ","))))")
            args += f.labelIds
        }
        if let p = f.priorities { where_.append("priority IN (\(p.map { _ in "?" }.joined(separator: ",")))"); args += p.map { $0 } }
        if let p = f.projectId { where_.append("projectId = ?"); args.append(p) }
        if let c = f.cycleId { where_.append("cycleId = ?"); args.append(c) }
        if let p = f.parentId { where_.append("parentId = ?"); args.append(p) }
        if let d = f.dueOnOrBefore { where_.append("dueDate IS NOT NULL AND dueDate <= ?"); args.append(d) }
        if !f.includeArchived { where_.append("archivedAt IS NULL") }
        if let t = f.text, !t.isEmpty {
            where_.append("issues.rowid IN (SELECT rowid FROM issues_ft WHERE issues_ft MATCH ?)")
            args.append(try Ledger.ftsQuery(t))
        }
        args.append(f.limit)
        return try db.read {
            try Issue.fetchAll($0, sql: "SELECT * FROM issues WHERE \(where_.joined(separator: " AND ")) ORDER BY sortOrder, number DESC LIMIT ?",
                               arguments: StatementArguments(args))
        }
    }

    /// Every word must match, the last as a prefix, so results appear while typing.
    static func ftsQuery(_ text: String) throws -> String {
        let words = text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        guard !words.isEmpty else { throw LedgerError.invalid("search text has no words") }
        return words.enumerated().map { "\"\($0.element)\"\($0.offset == words.count - 1 ? "*" : "")" }.joined(separator: " ")
    }

    /// "MOR-123", "123" or an id.
    public func issue(_ ref: String) throws -> Issue {
        let digits = ref.uppercased().hasPrefix("MOR-") ? String(ref.dropFirst(4)) : ref
        let found = try db.read { db -> Issue? in
            if let n = Int(digits), let i = try Issue.fetchOne(db, sql: "SELECT * FROM issues WHERE number = ? AND deleted = 0", arguments: [n]) { return i }
            return try Issue.fetchOne(db, sql: "SELECT * FROM issues WHERE id = ? AND deleted = 0", arguments: [ref])
        }
        guard let found else { throw LedgerError.notFound("no issue \(ref)") }
        return found
    }

    public func labels() throws -> [Label] { try db.read { try Label.fetchAll($0, sql: "SELECT * FROM labels WHERE deleted = 0 ORDER BY name") } }
    public func projects() throws -> [Project] { try db.read { try Project.fetchAll($0, sql: "SELECT * FROM projects WHERE deleted = 0 ORDER BY name") } }
    public func savedViews() throws -> [SavedView] { try db.read { try SavedView.fetchAll($0, sql: "SELECT * FROM savedViews WHERE deleted = 0 ORDER BY sortOrder, name") } }

    // MARK: issue writes

    @discardableResult
    public func createIssue(title: String, _ fields: [String: SyncValue] = [:]) throws -> Issue {
        guard !title.trimmingCharacters(in: .whitespaces).isEmpty else { throw LedgerError.invalid("an issue needs a title") }
        var f = fields
        f["title"] = .text(title)
        if f["status"] == nil { f["status"] = .text(Status.inbox.rawValue) }
        if f["createdAt"] == nil { f["createdAt"] = .text(Ledger.isoNow()) }
        try Ledger.validate(f)
        let id = try db.write { db -> String in
            if f["sortOrder"] == nil { f["sortOrder"] = .double(-Double(clock()) / 1000) }
            return try put(.issues, f, in: db)
        }
        return try db.read { try Issue.fetchOne($0, sql: "SELECT * FROM issues WHERE id = ?", arguments: [id])! }
    }

    /// Edits fields on one issue. Changing status also stamps started/completed/canceled, and completing a recurring issue makes the next one.
    @discardableResult
    public func edit(_ ref: String, _ fields: [String: SyncValue]) throws -> Issue {
        let current = try issue(ref)
        if let bad = fields.keys.first(where: { !Ledger.editableIssueFields.contains($0) }) { throw LedgerError.invalid("can't edit \(bad)") }
        try Ledger.validate(fields)
        var f = fields
        var spawn = false
        if let s = fields["status"]?.string, let status = Status(rawValue: s), status != current.status {
            let now = SyncValue.text(Ledger.isoNow())
            switch status {
            case .done: f["completedAt"] = now; f["canceledAt"] = .null; spawn = current.recurrence != nil
            case .canceled, .duplicate: f["canceledAt"] = now; f["completedAt"] = .null
            case .today: f["completedAt"] = .null; f["canceledAt"] = .null; if current.startedAt == nil { f["startedAt"] = now }
            case .todo, .inbox: f["completedAt"] = .null; f["canceledAt"] = .null
            }
        }
        try db.write { db in
            try put(.issues, id: current.id, f, in: db)
            if spawn, let r = current.recurrence { try spawnNext(of: current, r, in: db) }
        }
        return try issue(current.id)
    }

    public func deleteIssue(_ ref: String) throws {
        let i = try issue(ref)
        try db.write { db in
            try db.execute(sql: "UPDATE issues SET parentId = NULL WHERE parentId = ? AND deleted = 0", arguments: [i.id])
            let ts = try nextTimestamp(db)
            try db.execute(sql: "UPDATE issues SET deleted = 1, ts = ?, device = ?, dirty = 1 WHERE id = ?", arguments: [ts, device, i.id])
        }
    }

    private func spawnNext(of i: Issue, _ r: Recurrence, in db: Database) throws {
        let today = Ledger.day()
        var next = Ledger.date(fromDay: i.dueDate ?? today)!
        let unit: Calendar.Component = [.day: .day, .week: .weekOfYear, .month: .month][r.every]!
        var guardCount = 0
        repeat {
            next = Calendar.current.date(byAdding: unit, value: max(r.interval, 1), to: next)!
            guardCount += 1
        } while Ledger.day(next) <= today && guardCount < 1000
        var f: [String: SyncValue] = [
            "title": .text(i.title), "description": .text(i.description), "status": .text(Status.todo.rawValue), "priority": .int(Int64(i.priority)),
            "dueDate": .text(Ledger.day(next)), "labels": .text(String(decoding: try JSONEncoder().encode(i.labels), as: UTF8.self)),
            "recur": i.recur.map { .text($0) } ?? .null, "createdAt": .text(Ledger.isoNow()), "sortOrder": .double(-Double(clock()) / 1000),
        ]
        if let p = i.projectId { f["projectId"] = .text(p) }
        try put(.issues, f, in: db)
    }

    static func validate(_ f: [String: SyncValue]) throws {
        if let s = f["status"]?.string, Status(rawValue: s) == nil { throw LedgerError.invalid("status must be one of \(Status.allCases.map(\.rawValue).joined(separator: ", "))") }
        if let p = f["priority"]?.integer, !(0...4).contains(p) { throw LedgerError.invalid("priority must be 0 (none) to 4 (low)") }
        if let d = f["dueDate"]?.string, date(fromDay: d) == nil || d.count != 10 { throw LedgerError.invalid("dueDate must look like 2026-11-15") }
        if let l = f["labels"]?.string, (try? JSONDecoder().decode([String].self, from: Data(l.utf8))) == nil { throw LedgerError.invalid("labels must be a JSON array of label ids") }
        if let r = f["recur"]?.string, (try? JSONDecoder().decode(Recurrence.self, from: Data(r.utf8))) == nil {
            throw LedgerError.invalid("recur must look like {\"every\":\"week\",\"interval\":1}")
        }
    }

    // MARK: labels, projects, views

    @discardableResult
    public func putLabel(id: String? = nil, name: String, color: String? = nil) throws -> Label {
        var f: [String: SyncValue] = ["name": .text(name)]
        if let color { f["color"] = .text(color) }
        let rid = try db.write { try put(.labels, id: id, f, in: $0) }
        return try db.read { try Label.fetchOne($0, sql: "SELECT * FROM labels WHERE id = ?", arguments: [rid])! }
    }

    @discardableResult
    public func putProject(id: String? = nil, _ fields: [String: SyncValue]) throws -> Project {
        let rid = try db.write { try put(.projects, id: id, fields, in: $0) }
        return try db.read { try Project.fetchOne($0, sql: "SELECT * FROM projects WHERE id = ?", arguments: [rid])! }
    }

    @discardableResult
    public func putView(id: String? = nil, _ fields: [String: SyncValue]) throws -> SavedView {
        let rid = try db.write { try put(.savedViews, id: id, fields, in: $0) }
        return try db.read { try SavedView.fetchOne($0, sql: "SELECT * FROM savedViews WHERE id = ?", arguments: [rid])! }
    }

    /// Soft-deletes a label, project or view (sync needs the tombstone). Removes a deleted label from issues that carry it.
    public func delete(_ t: Table, id: String) throws {
        guard t != .issues else { throw LedgerError.invalid("use deleteIssue") }
        try db.write { db in
            let ts = try nextTimestamp(db)
            try db.execute(sql: "UPDATE \"\(t.rawValue)\" SET deleted = 1, ts = ?, device = ?, dirty = 1 WHERE id = ?", arguments: [ts, device, id])
            if t == .labels {
                for i in try Issue.fetchAll(db, sql: "SELECT * FROM issues WHERE deleted = 0 AND EXISTS (SELECT 1 FROM json_each(labels) WHERE value = ?)", arguments: [id]) {
                    let kept = i.labels.filter { $0 != id }
                    try put(.issues, id: i.id, ["labels": .text(String(decoding: try JSONEncoder().encode(kept), as: UTF8.self))], in: db)
                }
            }
        }
    }
}
