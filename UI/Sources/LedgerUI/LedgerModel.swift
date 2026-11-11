import Foundation
import LedgerCore
import GRDB
import Observation

public enum Scope: Hashable, Sendable {
    case inbox, today, cycle(String?), all, projects, project(String), label(String), view(String)
}

public enum Layout: String, Sendable { case list, board }
public enum PickerKind: String, CaseIterable, Sendable { case status, priority, label, due }

/// The app's state: the database, lists kept current by GRDB, what's selected and open, and sync.
@MainActor @Observable
public final class LedgerModel {
    public let ledger: Ledger

    // Data, kept current by observation.
    public private(set) var issues: [Issue] = []
    public private(set) var labels: [Label] = []
    public private(set) var projects: [Project] = []
    public private(set) var cycles: [Cycle] = []
    public private(set) var views: [SavedView] = []
    public private(set) var currentCycleID: String?
    @ObservationIgnored private var byID: [String: Issue] = [:]
    @ObservationIgnored private var childrenOf: [String: [Issue]] = [:]

    // What's on screen.
    public var scope: Scope = .today
    public var layout: Layout = .list { didSet { defaults.set(layout.rawValue, forKey: "layout") } }
    public var filter = ViewFilter()
    public var selectedID: String?
    public var detailOpen = false
    public var searchText = "" { didSet { refreshSearch() } }
    public var searchFocus = 0
    public var searchFocused = false
    public var collapsed: Set<Status> = IssueGrouping.collapsedByDefault
    public var palette = false
    public var picker: PickerKind?
    public var pickerIndex = 0
    public var composing = false
    public var composeStatus: Status = .inbox
    public var deleting: Issue?
    public var error: String?
    @ObservationIgnored private var searchHits: Set<String> = []

    // Sync.
    public private(set) var syncing = false
    public private(set) var lastSync: Date?
    public private(set) var syncError: String?
    public private(set) var settings: SyncSettings?
    @ObservationIgnored var transport: SyncTransport?
    @ObservationIgnored let defaults: UserDefaults
    @ObservationIgnored private let syncDelay: Duration
    @ObservationIgnored private var debounce: Task<Void, Never>?
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var observation: AnyDatabaseCancellable?

    public init(ledger: Ledger, settings: SyncSettings? = nil, transport: SyncTransport? = nil, defaults: UserDefaults = .standard, syncDelay: Duration = .seconds(2)) {
        self.ledger = ledger
        self.defaults = defaults
        self.syncDelay = syncDelay
        self.settings = settings
        self.transport = transport ?? settings?.transport()
        layout = Layout(rawValue: defaults.string(forKey: "layout") ?? "") ?? .list
        currentCycleID = (try? ledger.rollCycles())?.id
        if let s = try? Self.snapshot(ledger.db) { load(s) }
        observation = ValueObservation.tracking { try Self.snapshot($0) }
            .start(in: ledger.db, onError: { [weak self] e in Task { @MainActor in self?.error = "\(e)" } }, onChange: { [weak self] s in MainActor.assumeIsolated { self?.load(s) } })
    }

    /// The database at $LEDGER_DB, else the app's Application Support folder, with sync from Settings, Info.plist or sync.json.
    /// A $LEDGER_DB database is a scratch copy: it doesn't sync (so it can't reach the real hub) unless $LEDGER_SYNC=1.
    public static func openDefault(defaults: UserDefaults = .standard) throws -> LedgerModel {
        let path: String
        let env = ProcessInfo.processInfo.environment
        let scratch = !(env["LEDGER_DB"] ?? "").isEmpty && env["LEDGER_SYNC"] != "1"
        if let p = env["LEDGER_DB"], !p.isEmpty { path = p } else {
            let dir = SyncSettings.supportDirectory()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            path = dir.appendingPathComponent("ledger.sqlite").path
        }
        return LedgerModel(ledger: try Ledger(path: path), settings: scratch ? nil : SyncSettings.resolve(defaults: defaults), defaults: defaults)
    }

    struct Snapshot { var issues: [Issue], labels: [Label], projects: [Project], cycles: [Cycle], views: [SavedView] }

    nonisolated static func snapshot(_ db: DatabaseQueue) throws -> Snapshot { try db.read { try snapshot($0) } }
    nonisolated static func snapshot(_ db: Database) throws -> Snapshot {
        Snapshot(
            issues: try Issue.fetchAll(db, sql: "SELECT * FROM issues WHERE deleted = 0 AND archivedAt IS NULL"),
            labels: try Label.fetchAll(db, sql: "SELECT * FROM labels WHERE deleted = 0 ORDER BY name"),
            projects: try Project.fetchAll(db, sql: "SELECT * FROM projects WHERE deleted = 0 ORDER BY name"),
            cycles: try Cycle.fetchAll(db, sql: "SELECT * FROM cycles WHERE deleted = 0 ORDER BY number DESC"),
            views: try SavedView.fetchAll(db, sql: "SELECT * FROM savedViews WHERE deleted = 0 ORDER BY sortOrder, name"))
    }

    func load(_ s: Snapshot) {
        issues = s.issues; labels = s.labels; projects = s.projects; cycles = s.cycles; views = s.views
        byID = Dictionary(uniqueKeysWithValues: s.issues.map { ($0.id, $0) })
        childrenOf = Dictionary(grouping: s.issues.filter { $0.parentId != nil }, by: { $0.parentId! })
        if let id = selectedID, byID[id] == nil { selectedID = nil; detailOpen = false }
        refreshSearch()
    }

    // MARK: lookups

    public func issue(_ id: String?) -> Issue? { id.flatMap { byID[$0] } }
    public func label(_ id: String) -> Label? { labels.first { $0.id == id } }
    public func project(_ id: String?) -> Project? { id.flatMap { id in projects.first { $0.id == id } } }
    public func cycle(_ id: String?) -> Cycle? { id.flatMap { id in cycles.first { $0.id == id } } }
    public func children(of id: String) -> [Issue] { IssueGrouping.sorted(childrenOf[id] ?? [], closed: false) }
    public var selected: Issue? { issue(selectedID) }
    public var currentCycle: Cycle? { cycle(currentCycleID) }
    public func projectCounts(_ id: String) -> (open: Int, total: Int) {
        let mine = issues.filter { $0.projectId == id }
        return (mine.filter { !$0.status.isClosed }.count, mine.count)
    }

    // MARK: what the list shows

    public var searching: Bool { !searchText.trimmingCharacters(in: .whitespaces).isEmpty }

    func refreshSearch() {
        let t = searchText.trimmingCharacters(in: .whitespaces)
        var f = IssueFilter(); f.text = t; f.limit = 1000
        searchHits = t.isEmpty ? [] : Set((try? ledger.issues(f))?.map(\.id) ?? [])
    }

    public var scopeIssues: [Issue] {
        switch scope {
        case .inbox: return issues.filter { $0.status == .inbox }
        case .today: return issues.filter { $0.status == .today }
        case let .cycle(id): let c = id ?? currentCycleID; return issues.filter { $0.cycleId == c }
        case let .project(id): return issues.filter { $0.projectId == id }
        case let .label(id): return issues.filter { $0.labels.contains(id) }
        case .all, .projects, .view: return issues
        }
    }

    public var visible: [Issue] {
        let today = Ledger.day()
        let base = searching ? issues.filter { searchHits.contains($0.id) } : scopeIssues
        return filter.isEmpty ? base : base.filter { filter.matches($0, today: today) }
    }

    public var groups: [IssueGrouping.Group] { IssueGrouping.group(visible) }
    /// Issue ids in the order J and K walk them: expanded groups only.
    public var navigationOrder: [String] { groups.filter { !collapsed.contains($0.status) }.flatMap { $0.issues.map(\.id) } }

    public var title: String {
        if searching { return "Search" }
        switch scope {
        case .inbox: return "Inbox"
        case .today: return "Today"
        case let .cycle(id): return cycle(id ?? currentCycleID).map { "Cycle \($0.number)" } ?? "Cycle"
        case .all: return "All issues"
        case .projects: return "Projects"
        case let .project(id): return project(id)?.name ?? "Project"
        case let .label(id): return label(id)?.name ?? "Label"
        case let .view(id): return views.first { $0.id == id }?.name ?? "View"
        }
    }

    public func count(_ s: Scope) -> Int {
        switch s {
        case .inbox: return issues.filter { $0.status == .inbox }.count
        case .today: return issues.filter { $0.status == .today }.count
        default: return 0
        }
    }

    // MARK: navigation

    public func go(_ s: Scope) {
        scope = s
        searchText = ""
        filter = ViewFilter()
        if case let .view(id) = s, let v = views.first(where: { $0.id == id }) {
            filter = ViewFilter.decode(v.filter)
            layout = Layout(rawValue: v.layout) ?? layout
        }
        selectedID = nil; detailOpen = false
    }

    public func select(_ id: String?, open: Bool = false) {
        selectedID = id
        if open { detailOpen = id != nil } else if id == nil { detailOpen = false }
    }

    public func move(_ by: Int) {
        let order = navigationOrder
        guard !order.isEmpty else { return }
        let i = selectedID.flatMap { order.firstIndex(of: $0) }
        select(order[min(max((i ?? (by > 0 ? -1 : order.count)) + by, 0), order.count - 1)], open: detailOpen)
    }

    public func compose(status: Status? = nil) {
        composeStatus = status ?? { if case .today = scope { return .today } else { return .inbox } }()
        composing = true
    }

    public func toggleCollapsed(_ s: Status) { if collapsed.contains(s) { collapsed.remove(s) } else { collapsed.insert(s) } }

    // MARK: edits (each one is written, then synced shortly after)

    @discardableResult
    public func edit(_ id: String, _ fields: [String: SyncValue]) -> Issue? {
        do { let i = try ledger.edit(id, fields); localEdit(); return i } catch { self.error = "\(error)"; return nil }
    }

    public func setStatus(_ i: Issue, _ s: Status) { edit(i.id, ["status": .text(s.rawValue)]) }
    public func setPriority(_ i: Issue, _ p: Int) { edit(i.id, ["priority": .int(Int64(p))]) }
    public func setDue(_ i: Issue, _ day: String?) { edit(i.id, ["dueDate": day.map { .text($0) } ?? .null]) }
    public func setProject(_ i: Issue, _ id: String?) { edit(i.id, ["projectId": id.map { .text($0) } ?? .null]) }
    public func setCycle(_ i: Issue, _ id: String?) { edit(i.id, ["cycleId": id.map { .text($0) } ?? .null]) }
    public func setParent(_ i: Issue, _ id: String?) { edit(i.id, ["parentId": id.map { .text($0) } ?? .null]) }
    public func setRecurrence(_ i: Issue, _ r: Recurrence?) {
        edit(i.id, ["recur": r.flatMap { try? String(decoding: JSONEncoder().encode($0), as: UTF8.self) }.map { .text($0) } ?? .null])
    }
    public func toggleLabel(_ i: Issue, _ lid: String) {
        var l = i.labels
        if let at = l.firstIndex(of: lid) { l.remove(at: at) } else { l.append(lid) }
        edit(i.id, ["labels": .text(String(decoding: (try? JSONEncoder().encode(l)) ?? Data("[]".utf8), as: UTF8.self))])
    }

    @discardableResult
    public func create(title: String, status: Status = .inbox, _ more: [String: SyncValue] = [:]) -> Issue? {
        var f = more
        f["status"] = .text(status.rawValue)
        do {
            let i = try ledger.createIssue(title: title, f)
            localEdit()
            return i
        } catch { self.error = "\(error)"; return nil }
    }

    /// A new issue from the composer or quick add; `title` may carry `due:`, `p:` and `#label` shorthand.
    @discardableResult
    public func quickCreate(_ text: String, status: Status = .inbox, notes: String = "", projectID: String? = nil, parentID: String? = nil, extra: [String: SyncValue] = [:]) -> Issue? {
        let q = QuickAdd.parse(text, labels: labels)
        var f = extra
        if !notes.isEmpty { f["description"] = .text(notes) }
        if let d = q.due { f["dueDate"] = .text(d) }
        if let p = q.priority { f["priority"] = .int(Int64(p)) }
        if let projectID { f["projectId"] = .text(projectID) }
        if let parentID { f["parentId"] = .text(parentID) }
        if case .project(let pid) = scope, projectID == nil { f["projectId"] = .text(pid) }
        let ids = Array(Set(q.labelIds + (extra["labels"]?.string.flatMap { try? JSONDecoder().decode([String].self, from: Data($0.utf8)) } ?? []))).sorted()
        if !ids.isEmpty { f["labels"] = .text(String(decoding: (try? JSONEncoder().encode(ids)) ?? Data("[]".utf8), as: UTF8.self)) }
        if case let .label(lid) = scope, !ids.contains(lid) { f["labels"] = .text(String(decoding: (try? JSONEncoder().encode(ids + [lid])) ?? Data("[]".utf8), as: UTF8.self)) }
        return create(title: q.title.isEmpty ? text : q.title, status: status, f)
    }

    public func delete(_ i: Issue) {
        let order = navigationOrder
        let next = order.firstIndex(of: i.id).flatMap { order.indices.contains($0 + 1) ? order[$0 + 1] : ($0 > 0 ? order[$0 - 1] : nil) }
        do { try ledger.deleteIssue(i.id); localEdit(); if selectedID == i.id { select(next, open: detailOpen) } } catch { self.error = "\(error)" }
    }

    public func createLabel(_ name: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        _ = try? ledger.putLabel(name: n, color: Theme.swatches[labels.count % Theme.swatches.count]); localEdit()
    }

    public func deleteLabel(_ id: String) { try? ledger.delete(.labels, id: id); if scope == .label(id) { go(.all) }; localEdit() }

    public func saveProject(id: String? = nil, name: String, color: String, description: String, status: String) {
        do {
            _ = try ledger.putProject(id: id, ["name": .text(name), "color": .text(color), "description": .text(description), "status": .text(status)])
            localEdit()
        } catch { self.error = "\(error)" }
    }

    public func deleteProject(_ id: String) { try? ledger.delete(.projects, id: id); if scope == .project(id) { go(.projects) }; localEdit() }

    public func saveView(name: String) {
        if let v = try? ledger.putView(["name": .text(name), "filter": .text(filter.encoded()), "layout": .text(layout.rawValue), "sortOrder": .double(Double(views.count))]) {
            localEdit(); go(.view(v.id))
        }
    }

    public func updateView(_ id: String) {
        _ = try? ledger.putView(id: id, ["filter": .text(filter.encoded()), "layout": .text(layout.rawValue)]); localEdit()
    }

    public func deleteView(_ id: String) { try? ledger.delete(.savedViews, id: id); if scope == .view(id) { go(.all) }; localEdit() }

    /// True when the open saved view's filter or layout differs from what's stored.
    public var viewChanged: Bool {
        guard case let .view(id) = scope, let v = views.first(where: { $0.id == id }) else { return false }
        return ViewFilter.decode(v.filter) != filter || v.layout != layout.rawValue
    }

    // MARK: sync

    public var syncConfigured: Bool { transport != nil }

    public var syncLabel: String {
        if transport == nil { return "Not synced: set up the hub in Settings" }
        if syncing { return "Syncing…" }
        if let e = syncError { return "Sync failed: \(e)" }
        return lastSync.map { "Synced \(Format.ago($0))" } ?? "Not synced yet"
    }

    public func localEdit() {
        if let s = try? Self.snapshot(ledger.db) { load(s) }
        guard transport != nil else { return }
        debounce?.cancel()
        debounce = Task { [weak self, syncDelay] in
            try? await Task.sleep(for: syncDelay)
            guard !Task.isCancelled else { return }
            await self?.syncNow()
        }
    }

    public func syncNow() async {
        guard let transport else { return }
        if syncing { return }
        syncing = true
        do {
            _ = try await ledger.sync(with: transport)
            lastSync = Date(); syncError = nil
            currentCycleID = (try? ledger.rollCycles())?.id ?? currentCycleID
        } catch { syncError = Self.describe(error) }
        syncing = false
    }

    static func describe(_ e: Error) -> String {
        if case let SyncHTTPError.status(code, body) = e { return code == 401 ? "the hub refused the token" : "hub answered \(code) \(body.prefix(60))" }
        if let u = e as? URLError { return u.localizedDescription }
        return "\(e)"
    }

    /// Syncs on launch, on foreground (call `start()` again) and every minute while the app is open.
    public func start(interval: Duration = .seconds(60)) {
        currentCycleID = (try? ledger.rollCycles())?.id ?? currentCycleID
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.syncNow()
                try? await Task.sleep(for: interval)
            }
        }
    }

    public func stop() { loop?.cancel(); loop = nil }

    public func saveSettings(_ s: SyncSettings) {
        s.save(to: defaults)
        settings = s; transport = s.transport(); syncError = nil
        Task { await syncNow() }
    }

    public func clearSettings() {
        SyncSettings.clear(defaults)
        settings = SyncSettings.resolve(defaults: defaults); transport = settings?.transport(); syncError = nil
    }
}
