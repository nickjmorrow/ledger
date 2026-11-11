import ArgumentParser
import LedgerCore
import Foundation

struct LedgerCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ledger",
        abstract: "Issues, labels, projects, views and cycles (a Linear replacement). Prints JSON.",
        subcommands: [IssueGroup.self, LabelGroup.self, ProjectGroup.self, ViewGroup.self, CycleGroup.self, SummaryCommand.self,
                      SQLCommand.self, SchemaCommand.self, SyncSetup.self, SyncCommand.self, SyncServe.self, ImportLinear.self])
}

// MARK: how issues are shown

/// An issue as printed: the stored fields plus the names behind its ids.
struct IssueView: Encodable {
    var issue: Issue
    var labelNames: [String]
    var project: String?
    var cycle: Int?
    var parent: String?
    var subIssues: [String]?

    private enum Extra: String, CodingKey { case identifier, labelNames, project, cycle, parent, subIssues }

    func encode(to encoder: Encoder) throws {
        try issue.encode(to: encoder)
        var c = encoder.container(keyedBy: Extra.self)
        try c.encode(issue.identifier, forKey: .identifier)
        try c.encode(labelNames, forKey: .labelNames)
        try c.encode(project, forKey: .project)
        try c.encode(cycle, forKey: .cycle)
        try c.encode(parent, forKey: .parent)
        try c.encodeIfPresent(subIssues, forKey: .subIssues)
    }
}

extension Ledger {
    func views(_ issues: [Issue], withSubIssues: Bool = false) throws -> [IssueView] {
        let labels = Dictionary(try self.labels().map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        let projects = Dictionary(try self.projects().map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        let cycles = Dictionary(try self.cycles().map { ($0.id, $0.number) }, uniquingKeysWith: { a, _ in a })
        return try issues.map { i in
            var parent: String?
            if let p = i.parentId { parent = try? issue(p).identifier }
            var subs: [String]?
            if withSubIssues {
                var f = IssueFilter(); f.parentId = i.id; f.includeArchived = true
                subs = try self.issues(f).map { "\($0.identifier) \($0.title)" }
            }
            return IssueView(issue: i, labelNames: i.labels.compactMap { labels[$0] }, project: i.projectId.flatMap { projects[$0] },
                             cycle: i.cycleId.flatMap { cycles[$0] }, parent: parent, subIssues: subs)
        }
    }

    // MARK: names to ids

    func labelId(_ name: String) throws -> String {
        let all = try labels()
        if let l = all.first(where: { $0.name.lowercased() == name.lowercased() }) { return l.id }
        throw LedgerError.notFound("no label '\(name)' (labels: \(all.map(\.name).joined(separator: ", ")))")
    }

    func project(named name: String) throws -> Project {
        let all = try projects()
        if let p = all.first(where: { $0.name.lowercased() == name.lowercased() }) { return p }
        throw LedgerError.notFound("no project '\(name)' (projects: \(all.map(\.name).joined(separator: ", ")))")
    }

    /// "current", or a cycle number.
    func cycleId(_ s: String) throws -> String {
        if s.lowercased() == "current" { return try rollCycles().id }
        guard let n = Int(s) else { throw LedgerError.invalid("a cycle is 'current' or its number, like 29") }
        guard let c = try cycles().first(where: { $0.number == n }) else {
            throw LedgerError.notFound("no cycle \(n) (cycles: \(try cycles().map { String($0.number) }.joined(separator: ", ")))")
        }
        return c.id
    }
}

private func ids(_ names: [String], _ f: Ledger) throws -> [String] { try names.map(f.labelId) }
private func json(_ ids: [String]) -> SyncValue { .text(String(decoding: (try? JSONEncoder().encode(ids)) ?? Data("[]".utf8), as: UTF8.self)) }

// MARK: issue input (flags or --json)

/// What can be said about an issue, by name. "none" clears a field.
struct IssueInput: Decodable {
    var title, description, status, priority, due, project, parent, cycle, recur: String?
    var labels, addLabels, removeLabels: [String]?
    var isEmpty: Bool { [title, description, status, priority, due, project, parent, cycle, recur].allSatisfy { $0 == nil } && labels == nil && addLabels == nil && removeLabels == nil }
}

extension IssueInput {
    private enum Keys: String, CodingKey, CaseIterable { case title, description, status, priority, due, dueDate, project, parent, cycle, recur, labels, addLabels, removeLabels }
    private struct Flex: Decodable {
        let s: String
        init(from d: Decoder) throws {
            let c = try d.singleValueContainer()
            if let i = try? c.decode(Int.self) { s = String(i) } else { s = try c.decode(String.self) }
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        status = try c.decodeIfPresent(String.self, forKey: .status)
        priority = try c.decodeIfPresent(Flex.self, forKey: .priority)?.s
        due = try c.decodeIfPresent(String.self, forKey: .due) ?? c.decodeIfPresent(String.self, forKey: .dueDate)
        project = try c.decodeIfPresent(String.self, forKey: .project)
        parent = try c.decodeIfPresent(String.self, forKey: .parent)
        cycle = try c.decodeIfPresent(Flex.self, forKey: .cycle)?.s
        recur = try c.decodeIfPresent(String.self, forKey: .recur)
        labels = try c.decodeIfPresent([String].self, forKey: .labels)
        addLabels = try c.decodeIfPresent([String].self, forKey: .addLabels)
        removeLabels = try c.decodeIfPresent([String].self, forKey: .removeLabels)
    }

    static func parse(json: String) throws -> IssueInput {
        let known = Set(Keys.allCases.map(\.stringValue))
        if let o = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any], let bad = o.keys.sorted().first(where: { !known.contains($0) }) {
            throw LedgerError.invalid("unknown field \(bad); known: \(Keys.allCases.map(\.stringValue).joined(separator: ", "))")
        }
        do { return try JSONDecoder().decode(IssueInput.self, from: Data(json.utf8)) }
        catch let e as LedgerError { throw e }
        catch { throw LedgerError.invalid("--json must be an object like {\"title\": \"...\", \"status\": \"todo\", \"labels\": [\"Home\"]}") }
    }

    /// The database fields this means. `current` is the issue being edited, for adding and removing labels.
    func fields(_ f: Ledger, current: Issue? = nil) throws -> [String: SyncValue] {
        var out: [String: SyncValue] = [:]
        if let title { out["title"] = .text(title) }
        if let description { out["description"] = .text(description) }
        if let status { out["status"] = .text(status.lowercased()) }
        if let priority { out["priority"] = .int(try Self.priority(priority)) }
        if let due { out["dueDate"] = Self.clears(due) ? .null : .text(due) }
        if let project { out["projectId"] = Self.clears(project) ? .null : .text(try f.project(named: project).id) }
        if let parent {
            if Self.clears(parent) { out["parentId"] = .null } else {
                let p = try f.issue(parent)
                if p.id == current?.id { throw LedgerError.invalid("an issue can't be its own parent") }
                out["parentId"] = .text(p.id)
            }
        }
        if let cycle { out["cycleId"] = Self.clears(cycle) ? .null : .text(try f.cycleId(cycle)) }
        if let recur { out["recur"] = Self.clears(recur) ? .null : .text(try Self.recurrence(recur)) }
        if labels != nil || addLabels != nil || removeLabels != nil {
            var set = try labels.map { try ids($0, f) } ?? current?.labels ?? []
            for id in try ids(addLabels ?? [], f) where !set.contains(id) { set.append(id) }
            let drop = Set(try ids(removeLabels ?? [], f))
            out["labels"] = json(set.filter { !drop.contains($0) })
        }
        return out
    }

    static func clears(_ s: String) -> Bool { ["none", ""].contains(s.lowercased()) }

    static func priority(_ s: String) throws -> Int64 {
        let names = ["none": 0, "urgent": 1, "high": 2, "medium": 3, "low": 4]
        if let n = names[s.lowercased()] ?? Int(s), (0...4).contains(n) { return Int64(n) }
        throw LedgerError.invalid("priority must be none, urgent, high, medium or low (or 0 to 4)")
    }

    /// "week:1", "day:3" or "month" → the stored JSON.
    static func recurrence(_ s: String) throws -> String {
        let p = s.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard p.count <= 2, let unit = Recurrence.Unit(rawValue: p[0].lowercased()), let n = p.count == 2 ? Int(p[1]) : 1, n >= 1 else {
            throw LedgerError.invalid("recur must look like week:1 (every day, week or month, with a count)")
        }
        return String(decoding: try JSONEncoder().encode(Recurrence(every: unit, interval: n)), as: UTF8.self)
    }
}

/// The same fields as flags, shared by `issue create` and `issue edit`.
struct IssueFlags: ParsableArguments {
    @Option(help: "Title.") var title: String?
    @Option(help: "inbox, todo, today, done, canceled or duplicate.") var status: String?
    @Option(help: "none, urgent, high, medium or low.") var priority: String?
    @Option(help: "Due date, 2026-11-15, or none.") var due: String?
    @Option(help: "Label name; repeat for several. On edit this replaces the labels.") var label: [String] = []
    @Option(name: .customLong("add-label"), help: "Label name to add (edit).") var addLabel: [String] = []
    @Option(name: .customLong("remove-label"), help: "Label name to remove (edit).") var removeLabel: [String] = []
    @Option(help: "Project name, or none.") var project: String?
    @Option(help: "Parent issue, like MOR-12, or none.") var parent: String?
    @Option(help: "Cycle number or current, or none.") var cycle: String?
    @Option(help: "Markdown description.") var description: String?
    @Option(help: "Repeat after completing: day:N, week:N or month:N, or none.") var recur: String?
    @Option(help: "All of the above as one JSON object (keys: title, status, priority, due, labels, addLabels, removeLabels, project, parent, cycle, description, recur).") var json: String?

    func input() throws -> IssueInput {
        if let json { return try IssueInput.parse(json: json) }
        var i = IssueInput()
        i.title = title; i.status = status; i.priority = priority; i.due = due; i.project = project; i.parent = parent
        i.cycle = cycle; i.description = description; i.recur = recur
        i.labels = label.isEmpty ? nil : label
        i.addLabels = addLabel.isEmpty ? nil : addLabel
        i.removeLabels = removeLabel.isEmpty ? nil : removeLabel
        return i
    }
}

// MARK: issues

struct IssueGroup: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "issue", abstract: "Issues.", subcommands: [List.self, Show.self, Create.self, Edit.self, Delete.self])

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List issues (newest first within the manual order). Filters combine.")
        @OptionGroup var global: GlobalOptions
        @Option(help: "Status; repeat for several.") var status: [String] = []
        @Option(help: "Label name; repeat to match any of them.") var label: [String] = []
        @Option(help: "Priority (none, urgent, high, medium, low); repeat for several.") var priority: [String] = []
        @Option(help: "Project name.") var project: String?
        @Option(help: "Cycle number or current.") var cycle: String?
        @Option(help: "Parent issue, like MOR-12.") var parent: String?
        @Option(name: .customLong("due-before"), help: "Due on or before this date.") var dueBefore: String?
        @Option(help: "Words to search for in title and description.") var search: String?
        @Flag(help: "Include archived issues.") var archived = false
        @Option(help: "Most issues to return.") var limit = 100

        func run() throws {
            let ledger = try global.open()
            var f = IssueFilter()
            if !status.isEmpty {
                f.statuses = Set(try status.map { s in
                    guard let v = Status(rawValue: s.lowercased()) else { throw LedgerError.invalid("status must be one of \(Status.allCases.map(\.rawValue).joined(separator: ", "))") }
                    return v
                })
            }
            f.labelIds = try ids(label, ledger)
            if !priority.isEmpty { f.priorities = Set(try priority.map { Int(try IssueInput.priority($0)) }) }
            if let project { f.projectId = try ledger.project(named: project).id }
            if let cycle { f.cycleId = try ledger.cycleId(cycle) }
            if let parent { f.parentId = try ledger.issue(parent).id }
            if let dueBefore {
                guard Ledger.date(fromDay: dueBefore) != nil, dueBefore.count == 10 else { throw LedgerError.invalid("--due-before must look like 2026-11-15") }
                f.dueOnOrBefore = dueBefore
            }
            f.text = search
            f.includeArchived = archived
            f.limit = limit
            try Output.json(try ledger.views(try ledger.issues(f)))
        }
    }

    struct Show: ParsableCommand {
        @OptionGroup var global: GlobalOptions
        @Argument(help: "MOR-12, 12 or an id.") var ref: String
        func run() throws {
            let ledger = try global.open()
            try Output.json(try ledger.views([try ledger.issue(ref)], withSubIssues: true)[0])
        }
    }

    struct Create: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Create an issue (in the current cycle unless --cycle says otherwise). Needs a title.")
        @OptionGroup var global: GlobalOptions
        @OptionGroup var flags: IssueFlags
        func run() throws {
            let ledger = try global.open()
            var input = try flags.input()
            guard let title = input.title else { throw LedgerError.invalid("an issue needs a title: --title \"...\"") }
            if input.cycle == nil { input.cycle = "current" }
            input.title = nil
            let made = try ledger.createIssue(title: title, try input.fields(ledger))
            try global.settle(ledger)
            try Output.json(try ledger.views([try ledger.issue(made.id)])[0])
        }
    }

    struct Edit: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Change fields of an issue. Setting --status also stamps its dates, and completing a recurring issue makes the next one.")
        @OptionGroup var global: GlobalOptions
        @Argument(help: "MOR-12, 12 or an id.") var ref: String
        @OptionGroup var flags: IssueFlags
        func run() throws {
            let ledger = try global.open()
            let input = try flags.input()
            guard !input.isEmpty else { throw LedgerError.invalid("nothing to change: give at least one of --title, --status, --priority, --due, --label, --project, --parent, --cycle, --description, --recur") }
            let current = try ledger.issue(ref)
            let edited = try ledger.edit(ref, try input.fields(ledger, current: current))
            try global.settle(ledger)
            try Output.json(try ledger.views([try ledger.issue(edited.id)])[0])
        }
    }

    struct Delete: ParsableCommand {
        @OptionGroup var global: GlobalOptions
        @Argument(help: "MOR-12, 12 or an id.") var ref: String
        func run() throws {
            let ledger = try global.open()
            let i = try ledger.issue(ref)
            try ledger.deleteIssue(ref)
            try global.settle(ledger)
            try Output.json(["deleted": i.identifier, "title": i.title])
        }
    }
}

// MARK: labels, projects, views

struct LabelGroup: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "label", abstract: "Labels (named on the command line).", subcommands: [List.self, Put.self, Delete.self])

    struct List: ParsableCommand {
        @OptionGroup var global: GlobalOptions
        func run() throws { try Output.json(try global.open().labels()) }
    }

    struct Put: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Create a label, or change the color or name of the one with this name.")
        @OptionGroup var global: GlobalOptions
        @Argument var name: String
        @Option(help: "Color like #ffc83d.") var color: String?
        @Option(help: "New name.") var rename: String?
        func run() throws {
            let ledger = try global.open()
            let existing = try ledger.labels().first { $0.name.lowercased() == name.lowercased() }
            let made = try ledger.putLabel(id: existing?.id, name: rename ?? existing?.name ?? name, color: color)
            try global.settle(ledger)
            try Output.json(made)
        }
    }

    struct Delete: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Delete a label and take it off every issue that has it.")
        @OptionGroup var global: GlobalOptions
        @Argument var name: String
        func run() throws {
            let ledger = try global.open()
            try ledger.delete(.labels, id: try ledger.labelId(name))
            try global.settle(ledger)
            try Output.json(["deleted": name])
        }
    }
}

struct ProjectGroup: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "project", abstract: "Projects (named on the command line).", subcommands: [List.self, Put.self, Delete.self])

    struct List: ParsableCommand {
        @OptionGroup var global: GlobalOptions
        func run() throws { try Output.json(try global.open().projects()) }
    }

    struct Put: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Create a project, or change the fields of the one with this name.")
        @OptionGroup var global: GlobalOptions
        @Argument var name: String
        @Option(help: "Color like #ffc83d.") var color: String?
        @Option(help: "Description.") var description: String?
        @Option(help: "Status, like active.") var status: String?
        @Option(help: "New name.") var rename: String?
        func run() throws {
            let ledger = try global.open()
            let existing = try ledger.projects().first { $0.name.lowercased() == name.lowercased() }
            var f: [String: SyncValue] = ["name": .text(rename ?? existing?.name ?? name)]
            if let color { f["color"] = .text(color) }
            if let description { f["description"] = .text(description) }
            if let status { f["status"] = .text(status) }
            let made = try ledger.putProject(id: existing?.id, f)
            try global.settle(ledger)
            try Output.json(made)
        }
    }

    struct Delete: ParsableCommand {
        @OptionGroup var global: GlobalOptions
        @Argument var name: String
        func run() throws {
            let ledger = try global.open()
            try ledger.delete(.projects, id: try ledger.project(named: name).id)
            try global.settle(ledger)
            try Output.json(["deleted": name])
        }
    }
}

struct ViewGroup: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "view", abstract: "Saved views (named on the command line).", subcommands: [List.self, Put.self, Delete.self])

    static func find(_ name: String, _ f: Ledger) throws -> SavedView? { try f.savedViews().first { $0.name.lowercased() == name.lowercased() } }

    struct List: ParsableCommand {
        @OptionGroup var global: GlobalOptions
        func run() throws { try Output.json(try global.open().savedViews()) }
    }

    struct Put: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Create a saved view, or change the one with this name.")
        @OptionGroup var global: GlobalOptions
        @Argument var name: String
        @Option(help: "The filter as a JSON object.") var filter: String?
        @Option(help: "list or board.") var layout: String?
        @Option(help: "New name.") var rename: String?
        func run() throws {
            let ledger = try global.open()
            if let filter, (try? JSONSerialization.jsonObject(with: Data(filter.utf8))) as? [String: Any] == nil { throw LedgerError.invalid("--filter must be a JSON object") }
            if let layout, !["list", "board"].contains(layout) { throw LedgerError.invalid("layout must be list or board") }
            let existing = try ViewGroup.find(name, ledger)
            var f: [String: SyncValue] = ["name": .text(rename ?? existing?.name ?? name)]
            if let filter { f["filter"] = .text(filter) }
            if let layout { f["layout"] = .text(layout) }
            let made = try ledger.putView(id: existing?.id, f)
            try global.settle(ledger)
            try Output.json(made)
        }
    }

    struct Delete: ParsableCommand {
        @OptionGroup var global: GlobalOptions
        @Argument var name: String
        func run() throws {
            let ledger = try global.open()
            guard let v = try ViewGroup.find(name, ledger) else { throw LedgerError.notFound("no view '\(name)'") }
            try ledger.delete(.savedViews, id: v.id)
            try global.settle(ledger)
            try Output.json(["deleted": name])
        }
    }
}

// MARK: cycles, summary

struct CycleGroup: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "cycle", abstract: "Two-week cycles.", subcommands: [List.self, Roll.self])

    struct List: ParsableCommand {
        @OptionGroup var global: GlobalOptions
        func run() throws { try Output.json(try global.open().cycles()) }
    }

    struct Roll: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Make sure the current and next cycles exist and move unfinished work out of ended cycles. Prints the current cycle.")
        @OptionGroup var global: GlobalOptions
        func run() throws {
            let ledger = try global.open()
            let current = try ledger.rollCycles()
            try global.settle(ledger)
            try Output.json(current)
        }
    }
}

struct SummaryCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "summary", abstract: "Issue counts per status, what's in Today, and the current cycle.")
    @OptionGroup var global: GlobalOptions

    struct CycleSummary: Encodable { var number: Int; var startsAt: String; var endsAt: String; var open: Int; var done: Int }
    struct Summary: Encodable { var counts: [String: Int]; var today: [IssueView]; var cycle: CycleSummary }

    func run() throws {
        let ledger = try global.open()
        let cycle = try ledger.rollCycles()
        try global.settle(ledger)
        var counts = Dictionary(uniqueKeysWithValues: Status.allCases.map { ($0.rawValue, 0) })
        for i in try ledger.issues({ var f = IssueFilter(); f.limit = Int.max; return f }()) { counts[i.status.rawValue, default: 0] += 1 }
        var t = IssueFilter(); t.statuses = [.today]
        var c = IssueFilter(); c.cycleId = cycle.id; c.limit = Int.max
        let inCycle = try ledger.issues(c)
        try Output.json(Summary(counts: counts, today: try ledger.views(try ledger.issues(t)),
                                cycle: CycleSummary(number: cycle.number, startsAt: cycle.startsAt, endsAt: cycle.endsAt,
                                                    open: inCycle.filter { !$0.status.isClosed }.count, done: inCycle.filter { $0.status == .done }.count)))
    }
}

// MARK: sql

struct SQLCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "sql", abstract: "Run one read-only SELECT. Times are ISO strings, dates yyyy-MM-dd; call `ledger schema` for the tables.")
    @OptionGroup var global: GlobalOptions
    @Option(help: "Most rows to return.") var limit = 500
    @Argument(help: "A SELECT statement.") var query: String
    func run() throws { try Output.json(try global.open().query(sql: query, limit: limit)) }
}

struct SchemaCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "schema", abstract: "The database tables, for writing `ledger sql` queries.")
    @OptionGroup var global: GlobalOptions
    func run() throws {
        try Output.json(try global.open().query(sql: "select name, sql from sqlite_master where type = 'table' and name not like 'sqlite_%' and name not like 'grdb_%' and name not like 'issues_ft%' order by name"))
    }
}
