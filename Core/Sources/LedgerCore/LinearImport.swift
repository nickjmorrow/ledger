import Foundation
import GRDB

/// Reads a dump of Linear issues and cycles (the shape the Linear connector's list_issues and list_cycles return) into Ledger.
/// Row ids are derived from Linear's, so running it again updates what it made instead of duplicating it.
public struct ImportReport: Codable, Sendable, Equatable {
    public var issues = 0, skipped = 0, labels = 0, cycles = 0
}

struct LinearIssue: Decodable {
    struct Priority: Decodable { var value: Int }
    var id: String
    var uuid: String
    var title: String
    var description: String?
    var priority: Priority
    var createdAt: String
    var archivedAt: String?, completedAt: String?, startedAt: String?, canceledAt: String?
    var dueDate: String?
    var status: String
    var labels: [String]
    var cycleId: String?
    var parentId: String?
}

struct LinearCycle: Decodable {
    var id: String
    var number: Int
    var startsAt: String
    var endsAt: String
    var title: String?
}

struct LinearPage: Decodable { var issues: [LinearIssue] }

extension Ledger {
    static let labelPalette = ["#ffc83d", "#6fd3a0", "#7aa7ff", "#ff8f6b", "#c79bff", "#5fd0d8", "#ff7aa8", "#b4d96b"]

    /// `issuePages` are the connector's list_issues results (each `{issues:[...]}`); `cycles` is list_cycles' array.
    /// Existing imported issues are left alone unless `overwrite` is set.
    public func importLinear(issuePages: [Data], cycles: Data, overwrite: Bool = false) throws -> ImportReport {
        let dec = JSONDecoder()
        let issues = try issuePages.flatMap { try dec.decode(LinearPage.self, from: $0).issues }
        let linearCycles = try dec.decode([LinearCycle].self, from: cycles)
        var report = ImportReport()
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()
        func parse(_ s: String) -> Date? { iso.date(from: s) ?? isoPlain.date(from: s) }
        func stamp(_ s: String?) -> SyncValue { s.flatMap(parse).map { .text(Ledger.isoNow($0)) } ?? .null }

        try db.write { db in
            var cycleIds: [String: String] = [:]
            for c in linearCycles {
                guard let s = parse(c.startsAt), let e = parse(c.endsAt) else { continue }
                let id = "cycle-\(c.number)"
                cycleIds[c.id] = id
                try put(.cycles, id: id, ["number": .int(Int64(c.number)), "startsAt": .text(Ledger.day(s)), "endsAt": .text(Ledger.day(e)),
                                         "title": c.title.map { .text($0) } ?? .null], in: db)
                report.cycles += 1
            }
            var labelIds: [String: String] = [:]
            for name in Set(issues.flatMap(\.labels)).sorted() {
                let id = "label-" + name.lowercased().replacingOccurrences(of: " ", with: "-")
                labelIds[name] = id
                if try !(Bool.fetchOne(db, sql: "SELECT 1 FROM labels WHERE id = ?", arguments: [id]) ?? false) {
                    let color = Ledger.labelPalette[labelIds.count % Ledger.labelPalette.count]
                    try put(.labels, id: id, ["name": .text(name), "color": .text(color)], in: db)
                    report.labels += 1
                }
            }
            let ids = Dictionary(uniqueKeysWithValues: issues.map { ($0.id, "linear-\($0.uuid)") })
            for i in issues {
                let id = "linear-\(i.uuid)"
                if !overwrite, try Bool.fetchOne(db, sql: "SELECT 1 FROM issues WHERE id = ?", arguments: [id]) ?? false { report.skipped += 1; continue }
                guard let number = Int(i.id.split(separator: "-").last ?? "") else { throw LedgerError.invalid("odd issue id \(i.id)") }
                let created = parse(i.createdAt)
                let status: Status = Status(rawValue: i.status.lowercased()) ?? (i.completedAt != nil ? .done : i.canceledAt != nil ? .canceled : .inbox)
                let labels = i.labels.compactMap { labelIds[$0] }
                try put(.issues, id: id, [
                    "number": .int(Int64(number)), "title": .text(i.title), "description": .text(i.description ?? ""),
                    "status": .text(status.rawValue), "priority": .int(Int64(i.priority.value)),
                    "dueDate": i.dueDate.map { .text($0) } ?? .null,
                    "cycleId": i.cycleId.flatMap { cycleIds[$0] }.map { .text($0) } ?? .null,
                    "parentId": i.parentId.flatMap { ids[$0] }.map { .text($0) } ?? .null,
                    "labels": .text(String(decoding: try JSONEncoder().encode(labels), as: UTF8.self)),
                    "sortOrder": .double(-(created?.timeIntervalSince1970 ?? 0)),
                    "createdAt": stamp(i.createdAt), "startedAt": stamp(i.startedAt), "completedAt": stamp(i.completedAt),
                    "canceledAt": stamp(i.canceledAt), "archivedAt": stamp(i.archivedAt), "linearId": .text(i.uuid),
                ], in: db)
                report.issues += 1
            }
        }
        return report
    }
}
