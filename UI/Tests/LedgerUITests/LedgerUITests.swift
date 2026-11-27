import Foundation
import LedgerCore
import Observation
import Testing
@testable import LedgerUI

final class Tick: @unchecked Sendable { var now: Int64 = 1_000_000; func next() -> Int64 { now += 1000; return now } }

func makeLedger(_ device: String = "dev", tick: Tick = Tick()) throws -> Ledger { try Ledger(path: ":memory:", device: device, clock: { tick.next() }) }

func day(_ s: String) -> Date { Ledger.date(fromDay: s)! }

typealias Issue = LedgerCore.Issue
typealias Label = LedgerCore.Label

/// Core's records have no public initializer, so tests build them the way the database does: from JSON.
func make<T: Decodable>(_ json: [String: Any]) -> T { try! JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: json)) }

func issue(_ title: String, _ status: Status = .todo, priority: Int = 0, order: Double = 0, number: Int? = nil, done: String? = nil) -> Issue {
    var j: [String: Any] = ["id": UUID().uuidString, "title": title, "description": "", "status": status.rawValue, "priority": priority, "labels": [String](),
                            "sortOrder": order, "createdAt": "2026-11-01T00:00:00Z"]
    if let number { j["number"] = number }
    if let done { j["completedAt"] = done }
    return make(j)
}

func label(_ id: String, _ name: String) -> Label { make(["id": id, "name": name, "color": "#ffffff"]) }

@Suite struct GroupingTests {
    @Test func groupsInLinearOrderAndOmitsEmpty() {
        let g = IssueGrouping.group([issue("a", .done), issue("b", .inbox), issue("c", .today), issue("d", .todo), issue("e", .duplicate), issue("f", .canceled)])
        #expect(g.map(\.status) == [.today, .todo, .inbox, .done, .canceled, .duplicate])
        #expect(IssueGrouping.group([issue("a", .todo)]).map(\.status) == [.todo])
        #expect(IssueGrouping.group([], keepEmpty: true).count == 6)
    }

    @Test func openIssuesSortByPriorityThenOrderThenNewest() {
        let s = IssueGrouping.sorted([issue("none", priority: 0, order: -5), issue("low", priority: 4, order: 3), issue("urgent", priority: 1, order: 9),
                                      issue("med-b", priority: 3, order: 2, number: 1), issue("med-a", priority: 3, order: 1)], closed: false)
        #expect(s.map(\.title) == ["urgent", "med-a", "med-b", "low", "none"])
        let same = IssueGrouping.sorted([issue("old", number: 1), issue("new", number: 9)], closed: false)
        #expect(same.map(\.title) == ["new", "old"])
    }

    @Test func closedIssuesSortByFinishDate() {
        let s = IssueGrouping.sorted([issue("first", .done, done: "2026-10-01T00:00:00Z"), issue("last", .done, done: "2026-11-01T00:00:00Z")], closed: true)
        #expect(s.map(\.title) == ["last", "first"])
    }
}

@Suite struct FilterTests {
    @Test func roundTripsThroughJSON() {
        var f = ViewFilter()
        f.statuses = ["today", "todo"]; f.labels = ["l1"]; f.priorities = [1, 2]; f.project = "p"; f.due = .overdue
        #expect(ViewFilter.decode(f.encoded()) == f)
        #expect(f.encoded() == f.encoded())
        #expect(ViewFilter.decode("{}").isEmpty)
        #expect(ViewFilter.decode("not json").isEmpty)
        #expect(ViewFilter.decode(#"{"priorities":[1],"unknown":3}"#).priorities == [1])
    }

    @Test func matchesEachProperty() {
        var a = issue("a", .today, priority: 1)
        a.labels = ["x"]; a.projectId = "p1"; a.dueDate = "2026-11-01"
        var f = ViewFilter()
        #expect(f.matches(a, today: "2026-11-03"))
        f.statuses = ["todo"]; #expect(!f.matches(a, today: "2026-11-03"))
        f.statuses = ["today", "todo"]; #expect(f.matches(a, today: "2026-11-03"))
        f.labels = ["y"]; #expect(!f.matches(a, today: "2026-11-03"))
        f.labels = ["x", "y"]; #expect(f.matches(a, today: "2026-11-03"))
        f.priorities = [2]; #expect(!f.matches(a, today: "2026-11-03"))
        f.priorities = [1]; f.project = "p2"; #expect(!f.matches(a, today: "2026-11-03"))
        f.project = "p1"; f.due = .overdue; #expect(f.matches(a, today: "2026-11-03"))
        f.due = .today; #expect(!f.matches(a, today: "2026-11-03"))
        f.due = .noDate; #expect(!f.matches(a, today: "2026-11-03"))
        a.status = .done; f.statuses = []; f.due = .overdue; #expect(!f.matches(a, today: "2026-11-03"))
    }

    @Test func dueWeekAndAny() {
        var a = issue("a"); var f = ViewFilter(); f.due = .week
        #expect(!f.matches(a, today: "2026-11-03"))
        a.dueDate = "2026-11-09"; #expect(f.matches(a, today: "2026-11-03"))
        a.dueDate = "2026-11-12"; #expect(!f.matches(a, today: "2026-11-03"))
        f.due = .any; #expect(f.matches(a, today: "2026-11-03"))
    }
}

@Suite struct PaletteTests {
    func item(_ title: String, _ sub: String = "", number: Int? = nil) -> PaletteItem {
        PaletteItem(id: title + sub, kind: number == nil ? .action : .issue, title: title, subtitle: sub, symbol: "circle", number: number, run: {})
    }

    @Test func fuzzyScoring() {
        #expect(Fuzzy.score("", in: "x") == 0)
        #expect(Fuzzy.score("zzz", in: "Go to Inbox") == nil)
        #expect(Fuzzy.score("go", in: "Go to Inbox")! > Fuzzy.score("inb", in: "Go to Inbox")!)
        #expect(Fuzzy.score("inb", in: "Go to Inbox")! > Fuzzy.score("nbo", in: "Go to Inbox")!)
        #expect(Fuzzy.score("gtib", in: "Go to Inbox") != nil)
        #expect(Fuzzy.score("GO TO", in: "go to inbox") != nil)
    }

    @Test func ranksPrefixFirstAndFindsByNumber() {
        let items = [item("Fix the sync bug", "MOR-12", number: 12), item("Sync now"), item("Buy milk", "MOR-123", number: 123), item("Plan trip", "MOR-1", number: 1)]
        #expect(Palette.rank(items, query: "sync").map(\.title) == ["Sync now", "Fix the sync bug"])
        #expect(Palette.rank(items, query: "123").first?.title == "Buy milk")
        #expect(Palette.rank(items, query: "mor-1").map(\.title).prefix(1) == ["Plan trip"])
        #expect(Palette.rank(items, query: "12").map(\.title).prefix(2) == ["Fix the sync bug", "Buy milk"])
        #expect(Palette.rank(items, query: "").count == 4)
        #expect(Palette.rank(items, query: "qqq").isEmpty)
    }
}

@Suite struct QuickAddTests {
    let labels = [label("l1", "Errands"), label("l2", "Deep Work")]
    // Tuesday 2026-11-03.
    let today = day("2026-11-03")

    @Test func parsesDuePriorityAndLabels() {
        let q = QuickAdd.parse("Call the dentist due:tomorrow p:high #errands", labels: labels, today: today)
        #expect(q.title == "Call the dentist")
        #expect(q.due == "2026-11-04")
        #expect(q.priority == 2)
        #expect(q.labelIds == ["l1"])
    }

    @Test func dueFormats() {
        func due(_ s: String) -> String? { QuickAdd.parse("x due:\(s)", labels: [], today: today).due }
        #expect(due("today") == "2026-11-03")
        #expect(due("fri") == "2026-11-06")
        #expect(due("tue") == "2026-11-10")
        #expect(due("monday") == "2026-11-09")
        #expect(due("nextweek") == "2026-11-09")
        #expect(due("3d") == "2026-11-06")
        #expect(due("2w") == "2026-11-17")
        #expect(due("2026-12-25") == "2026-12-25")
        #expect(due("soon") == nil)
    }

    @Test func priorityWordsAndNumbers() {
        func p(_ s: String) -> Int? { QuickAdd.parse("x p:\(s)", labels: [], today: today).priority }
        #expect(p("urgent") == 1); #expect(p("1") == 1); #expect(p("medium") == 3); #expect(p("low") == 4); #expect(p("none") == 0); #expect(p("huge") == nil)
    }

    @Test func unknownShorthandStaysInTheTitle() {
        let q = QuickAdd.parse("Fix #bug due:soon p:huge", labels: labels, today: today)
        #expect(q.title == "Fix #bug due:soon p:huge")
        #expect(q.due == nil && q.priority == nil && q.labelIds.isEmpty)
    }

    @Test func multiWordLabelsUseHyphens() {
        let q = QuickAdd.parse("#deep-work Write #DEEP-WORK #errands", labels: labels, today: today)
        #expect(q.labelIds == ["l2", "l1"])
        #expect(q.title == "Write")
    }

    @Test func onlyShorthandLeavesEmptyTitle() {
        #expect(QuickAdd.parse("p:high", labels: [], today: today).title == "")
    }

    @Test func plainLanguageAtTheEnd() {
        let q = QuickAdd.parse("Call the dentist tomorrow high priority #errands", labels: labels, today: today)
        #expect(q.title == "Call the dentist")
        #expect(q.due == "2026-11-04")
        #expect(q.priority == 2)
        #expect(q.labelIds == ["l1"])
    }

    @Test func plainDates() {
        func due(_ s: String) -> String? { QuickAdd.parse("x \(s)", labels: [], today: today).due }
        #expect(due("today") == "2026-11-03")
        #expect(due("friday") == "2026-11-06")
        #expect(due("this friday") == "2026-11-06")
        #expect(due("next friday") == "2026-11-13")
        #expect(due("next monday") == "2026-11-09")
        #expect(due("next week") == "2026-11-09")
        #expect(due("in 3 days") == "2026-11-06")
        #expect(due("in a week") == "2026-11-10")
        #expect(due("nov 30") == "2026-11-30")
        #expect(due("November 30th") == "2026-11-30")
        #expect(due("january 5") == "2027-01-05")
        #expect(due("12/25") == "2026-12-25")
        #expect(due("2026-12-25") == "2026-12-25")
        #expect(due("feb 30") == nil)
    }

    @Test func markedDatesWorkMidSentence() {
        let q = QuickAdd.parse("Submit report by Friday to the team", labels: [], today: today)
        #expect(q.title == "Submit report to the team")
        #expect(q.due == "2026-11-06")
        #expect(QuickAdd.parse("Lunch on fri", labels: [], today: today).due == "2026-11-06")
        #expect(QuickAdd.parse("File taxes due nov 30 low priority", labels: [], today: today) == QuickAdd(title: "File taxes", due: "2026-11-30", priority: 4))
    }

    @Test func repeats() {
        func q(_ s: String) -> QuickAdd { QuickAdd.parse(s, labels: [], today: today) }
        #expect(q("Pay rent every month") == QuickAdd(title: "Pay rent", recurrence: Recurrence(every: .month)))
        #expect(q("Water plants every 2 weeks") == QuickAdd(title: "Water plants", recurrence: Recurrence(every: .week, interval: 2)))
        #expect(q("Water plants every other day").recurrence == Recurrence(every: .day, interval: 2))
        #expect(q("Stretch daily").recurrence == Recurrence(every: .day))
        #expect(q("Take out the bins every thursday") == QuickAdd(title: "Take out the bins", due: "2026-11-05", recurrence: Recurrence(every: .week)))
        #expect(q("Every week review the budget tomorrow") == QuickAdd(title: "review the budget", due: "2026-11-04", recurrence: Recurrence(every: .week)))
    }

    @Test func ordinaryWordsStayInTheTitle() {
        for t in ["Plan Friday dinner", "Fix high CPU usage", "Fix high priority bugs", "Sit in the sun", "Weekly review notes", "Clean every room", "Ask Tom", "Work on the deck"] {
            #expect(QuickAdd.parse(t, labels: [], today: today) == QuickAdd(title: t))
        }
    }

    @Test func ignoredFieldsStayInTheTitle() {
        let q = QuickAdd.parse("Email report friday high priority", labels: [], today: today, ignoring: [.due])
        #expect(q == QuickAdd(title: "Email report friday", priority: 2))
        #expect(QuickAdd.parse("Stretch daily", labels: [], today: today, ignoring: [.repeats]) == QuickAdd(title: "Stretch daily"))
        #expect(QuickAdd.parse("x due:tomorrow", labels: [], today: today, ignoring: [.due]).due == "2026-11-04")
    }
}

@Suite struct SettingsTests {
    func defaults() -> UserDefaults { let d = UserDefaults(suiteName: UUID().uuidString)!; return d }

    @Test func savedBeatsInfoBeatsFile() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("sync-\(UUID().uuidString).json")
        try Data(#"{"url":"http://file:1","token":"f"}"#.utf8).write(to: file)
        let info: [String: Any] = ["LedgerHubURL": "http://plist:2", "LedgerHubToken": "p", "LedgerHubHost": "h"]
        let d = defaults()
        #expect(SyncSettings.resolve(defaults: d, info: info, file: file)?.url == "http://plist:2")
        #expect(SyncSettings.resolve(defaults: d, info: info, file: file)?.hostHeader == "h")
        #expect(SyncSettings.resolve(defaults: d, info: nil, file: file)?.url == "http://file:1")
        SyncSettings(url: "http://saved:3", token: "s").save(to: d)
        #expect(SyncSettings.resolve(defaults: d, info: info, file: file)?.url == "http://saved:3")
        SyncSettings.clear(d)
        #expect(SyncSettings.resolve(defaults: d, info: info, file: file)?.url == "http://plist:2")
        #expect(SyncSettings.resolve(defaults: d, info: nil, file: nil) == nil)
    }

    @Test func emptyInjectedKeysAreIgnored() {
        #expect(SyncSettings.fromInfo(["LedgerHubURL": "", "LedgerHubToken": ""]) == nil)
        #expect(SyncSettings.fromInfo(["LedgerHubURL": "http://x:1", "LedgerHubToken": "t", "LedgerHubHost": ""])?.hostHeader == nil)
    }
}

struct FailingTransport: SyncTransport {
    func pull(since: Int64) async throws -> [SyncRow] { throw SyncHTTPError.status(401, "unauthorized") }
    func push(device: String, rows: [SyncRow]) async throws { throw SyncHTTPError.status(401, "unauthorized") }
}

@MainActor @Suite struct ModelTests {
    func model(_ transport: SyncTransport? = nil, delay: Duration = .seconds(60)) throws -> LedgerModel {
        LedgerModel(ledger: try makeLedger(), transport: transport, defaults: UserDefaults(suiteName: UUID().uuidString)!, syncDelay: delay)
    }

    @Test func issueLookupRedrawsWhenTheIssueChanges() throws {
        let m = try model()
        let i = try #require(m.create(title: "Gift"))
        m.load(try LedgerModel.snapshot(m.ledger.db))
        var redrawn = false
        withObservationTracking { _ = m.issue(i.id); _ = m.children(of: i.id) } onChange: { redrawn = true }
        m.setCycle(i, m.currentCycleID)
        m.load(try LedgerModel.snapshot(m.ledger.db))
        #expect(redrawn)
        #expect(m.issue(i.id)?.cycleId == m.currentCycleID)
    }

    @Test func opensOnTheCurrentCycleAndInboxIsAPlainList() throws {
        let m = try model()
        #expect(m.scope == .cycle(nil))
        #expect(!m.isPlainList)
        m.go(.inbox)
        #expect(m.isPlainList)
        m.searchText = "x"
        #expect(!m.isPlainList)
    }

    @Test func renamesAndRecoloursLabels() throws {
        let m = try model()
        m.createLabel("Home")
        m.load(try LedgerModel.snapshot(m.ledger.db))
        let id = try #require(m.labels.first?.id)
        m.updateLabel(id, name: "  House ", color: "#7ee0a1")
        m.updateLabel(id, name: "   ")
        m.load(try LedgerModel.snapshot(m.ledger.db))
        #expect(m.label(id)?.name == "House")
        #expect(m.label(id)?.color == "#7ee0a1")
    }

    @Test func opensWithCyclesRolled() throws {
        let m = try model()
        #expect(m.currentCycle != nil)
        #expect(m.cycles.count == 2)
    }

    @Test func notConfiguredStatus() async throws {
        let m = try model()
        #expect(!m.syncConfigured)
        #expect(m.syncLabel.hasPrefix("Not synced"))
        await m.syncNow()
        #expect(m.lastSync == nil)
    }

    @Test func syncSucceedsAndShowsTime() async throws {
        let hub = SyncHub(ledger: try makeLedger("hub"))
        let m = try model(DirectTransport(hub: hub))
        #expect(m.syncLabel == "Not synced yet")
        let i = m.create(title: "Write tests")!
        await m.syncNow()
        #expect(m.syncError == nil)
        #expect(m.lastSync != nil)
        #expect(m.syncLabel.hasPrefix("Synced"))
        #expect(!m.syncing)
        #expect(try hub.ledger.issues(.init()).contains { $0.title == "Write tests" })
        // The hub numbered it, and the pull brought the number back into the lists.
        #expect(m.issue(i.id)?.number != nil)
    }

    @Test func syncFailureIsReportedAndRecovers() async throws {
        let m = try model(FailingTransport())
        await m.syncNow()
        #expect(m.syncError == "the hub refused the token")
        #expect(m.syncLabel == "Sync failed: the hub refused the token")
        #expect(m.lastSync == nil)
        m.transport = DirectTransport(hub: SyncHub(ledger: try makeLedger("hub")))
        await m.syncNow()
        #expect(m.syncError == nil && m.lastSync != nil)
    }

    @Test func localEditSyncsAfterTheDelay() async throws {
        let hub = SyncHub(ledger: try makeLedger("hub"))
        let m = try model(DirectTransport(hub: hub), delay: .milliseconds(50))
        m.create(title: "Soon on the hub")
        #expect(try hub.ledger.issues(.init()).isEmpty)
        try await Task.sleep(for: .milliseconds(600))
        #expect(try hub.ledger.issues(.init()).count == 1)
        #expect(m.lastSync != nil)
    }

    @Test func editsKeepListsCurrent() throws {
        let m = try model()
        let i = m.create(title: "a", status: .todo)!
        #expect(m.issues.map(\.id) == [i.id])
        m.setStatus(i, .today)
        #expect(m.issue(i.id)?.status == .today)
        m.go(.today)
        #expect(m.visible.map(\.id) == [i.id])
        m.go(.inbox)
        #expect(m.visible.isEmpty)
        m.delete(m.issue(i.id)!)
        #expect(m.issues.isEmpty)
    }

    @Test func quickCreateAppliesShorthand() throws {
        let m = try model()
        let l = try m.ledger.putLabel(name: "Errands")
        m.load(try LedgerModel.snapshot(m.ledger.db))
        let i = m.quickCreate("Buy stamps due:2026-12-01 p:urgent #errands")!
        #expect(i.title == "Buy stamps" && i.dueDate == "2026-12-01" && i.priority == 1 && i.labels == [l.id] && i.status == .inbox)
    }

    @Test func quickCreateAppliesPlainLanguage() throws {
        let m = try model()
        let i = m.quickCreate("Water plants every 2 weeks low priority")!
        #expect(i.title == "Water plants" && i.priority == 4 && i.recurrence == Recurrence(every: .week, interval: 2))
        let kept = m.quickCreate("Stretch daily", ignoring: [.repeats])!
        #expect(kept.title == "Stretch daily" && kept.recurrence == nil)
    }

    @Test func savedViewKeepsFilterAndLayout() throws {
        let m = try model()
        m.filter.priorities = [1]
        m.layout = .board
        m.saveView(name: "Urgent")
        guard case let .view(id) = m.scope else { #expect(Bool(false)); return }
        #expect(m.views.first?.name == "Urgent")
        m.go(.all)
        #expect(m.filter.isEmpty)
        m.go(.view(id))
        #expect(m.filter.priorities == [1] && m.layout == .board && !m.viewChanged)
        m.filter.priorities = [2]
        #expect(m.viewChanged)
    }

    @Test func searchUsesFullText() throws {
        let m = try model()
        m.create(title: "Renew passport"); m.create(title: "Buy milk")
        m.searchText = "pass"
        #expect(m.visible.map(\.title) == ["Renew passport"])
        m.searchText = ""
        #expect(m.visible.count == 0 || m.scope == .today)
    }

    @Test func keysWalkAndEdit() throws {
        let m = try model()
        let a = m.create(title: "a", status: .today)!, b = m.create(title: "b", status: .today)!
        m.go(.today)
        #expect(m.handle(.char("j")))
        let first = m.selectedID
        #expect(first != nil)
        m.handle(.char("j")); #expect(m.selectedID != first)
        m.handle(.char("k")); #expect(m.selectedID == first)
        // Priority picker: P opens it, 1 chooses urgent.
        m.handle(.char("p")); #expect(m.picker == .priority)
        m.handle(.char("1")); #expect(m.picker == nil)
        #expect(m.issue(first)?.priority == 1)
        // Status picker: S, then Return on the highlighted row (the current status, so choose row 2 with a digit).
        m.handle(.char("s")); #expect(m.picker == .status)
        m.handle(.char("6")); #expect(m.issue(first)?.status == .duplicate)
        // Escape closes detail, then clears selection.
        m.handle(.return); #expect(m.detailOpen)
        m.handle(.escape); #expect(!m.detailOpen && m.selectedID != nil)
        m.handle(.escape); #expect(m.selectedID == nil)
        // Delete asks first.
        m.select(a.id); m.handle(.delete); #expect(m.deleting?.id == a.id)
        _ = b
    }

    @Test func keysIgnoredWhileComposing() throws {
        let m = try model()
        m.composing = true
        #expect(!m.handle(.char("c")))
        m.composing = false
        m.handle(.char("c")); #expect(m.composing)
    }

    @Test func paletteJumpsToIssuesAndRunsActions() throws {
        let m = try model()
        let i = m.create(title: "Renew passport", status: .done)!
        let hits = Palette.rank(m.paletteItems(), query: "passport")
        #expect(hits.first?.kind == .issue)
        hits.first?.run()
        #expect(m.selectedID == i.id && m.detailOpen)
        #expect(m.scope == .all)
        let status = Palette.rank(m.paletteItems(), query: "status today").first
        #expect(status?.title == "Status: Today")
        status?.run()
        #expect(m.issue(i.id)?.status == .today)
    }
}

@Suite struct BoardColumnTests {
    @Test func cycleStartsWithWorkingColumnsOthersWithAll() {
        #expect(BoardColumns.defaults(for: "cycle") == [.todo, .today, .done])
        #expect(BoardColumns.defaults(for: "all") == IssueGrouping.order)
        #expect(BoardColumns.hidden([.todo, .today, .done]) == [.inbox, .canceled, .duplicate])
    }

    @Test func droppingAColumnTakesTheTargetsPlace() {
        let c: [Status] = [.todo, .today, .done]
        #expect(BoardColumns.moving(.todo, to: .done, in: c) == [.today, .done, .todo])
        #expect(BoardColumns.moving(.done, to: .todo, in: c) == [.done, .todo, .today])
        #expect(BoardColumns.moving(.inbox, to: .today, in: c) == [.todo, .inbox, .today, .done])
        #expect(BoardColumns.moving(.inbox, to: nil, in: c) == [.todo, .today, .done, .inbox])
        #expect(BoardColumns.moving(.today, to: .today, in: c) == c)
    }

    @Test func shiftingStopsAtTheEdges() {
        let c: [Status] = [.todo, .today, .done]
        #expect(BoardColumns.shifting(.today, by: -1, in: c) == [.today, .todo, .done])
        #expect(BoardColumns.shifting(.todo, by: -1, in: c) == c)
        #expect(BoardColumns.shifting(.done, by: 1, in: c) == c)
    }
}

@MainActor @Suite struct BoardColumnModelTests {
    @Test func columnsAreKeptPerScreenAndReset() throws {
        let d = UserDefaults(suiteName: UUID().uuidString)!
        let m = LedgerModel(ledger: try makeLedger(), defaults: d, syncDelay: .seconds(60))
        m.go(.cycle(nil))
        #expect(m.boardColumns == [.todo, .today, .done])
        m.hideColumn(.done); m.showColumn(.inbox); m.shiftColumn(.inbox, by: -1)
        #expect(m.boardColumns == [.todo, .inbox, .today])
        m.go(.all)
        #expect(m.boardColumns == IssueGrouping.order)
        let again = LedgerModel(ledger: try makeLedger(), defaults: d, syncDelay: .seconds(60))
        again.go(.cycle("other"))
        #expect(again.boardColumns == [.todo, .inbox, .today])
        again.resetColumns()
        #expect(again.boardColumns == [.todo, .today, .done])
    }
}
