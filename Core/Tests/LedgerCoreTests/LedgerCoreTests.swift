import Foundation
import GRDB
import Testing
@testable import LedgerCore

final class TestClock: @unchecked Sendable {
    var now: Int64 = 1_000_000
    func tick(_ n: Int64 = 1000) -> Int64 { now += n; return now }
}

func make(_ device: String, clock: TestClock = TestClock()) throws -> Ledger {
    try Ledger(path: ":memory:", device: device, clock: { clock.tick() })
}

@Suite struct OpsTests {
    @Test func createsAndFindsByIdentifier() throws {
        let f = try make("hub")
        let i = try f.createIssue(title: "Buy milk")
        #expect(i.status == .inbox)
        #expect(i.number == nil)
        let hub = SyncHub(ledger: f)
        _ = try hub.pull(since: 0)
        #expect(try f.issue("MOR-1").title == "Buy milk")
        #expect(try f.issue("1").id == i.id)
    }

    @Test func statusStampsDates() throws {
        let f = try make("hub")
        let i = try f.createIssue(title: "a")
        let today = try f.edit(i.id, ["status": .text("today")])
        #expect(today.startedAt != nil)
        let done = try f.edit(i.id, ["status": .text("done")])
        #expect(done.completedAt != nil && done.canceledAt == nil)
        let reopened = try f.edit(i.id, ["status": .text("todo")])
        #expect(reopened.completedAt == nil)
        let canceled = try f.edit(i.id, ["status": .text("canceled")])
        #expect(canceled.canceledAt != nil)
    }

    @Test func rejectsBadInput() throws {
        let f = try make("hub")
        let i = try f.createIssue(title: "a")
        #expect(throws: LedgerError.self) { try f.edit(i.id, ["status": .text("blocked")]) }
        #expect(throws: LedgerError.self) { try f.edit(i.id, ["priority": .int(9)]) }
        #expect(throws: LedgerError.self) { try f.edit(i.id, ["dueDate": .text("tomorrow")]) }
        #expect(throws: LedgerError.self) { try f.edit(i.id, ["ts": .int(1)]) }
        #expect(throws: LedgerError.self) { try f.createIssue(title: "  ") }
    }

    @Test func completingRecurringIssueMakesNext() throws {
        let f = try make("hub")
        let i = try f.createIssue(title: "Water plants", ["recur": .text(#"{"every":"week","interval":1}"#), "dueDate": .text("2020-01-06"), "status": .text("todo")])
        _ = try f.edit(i.id, ["status": .text("done")])
        let open = try f.issues(.init()).filter { $0.status == .todo }
        #expect(open.count == 1)
        #expect(open[0].title == "Water plants")
        #expect(open[0].dueDate! > Ledger.day())
        #expect(open[0].recur == i.recur)
    }

    @Test func filtersAndSearch() throws {
        let f = try make("hub")
        let l = try f.putLabel(name: "Home")
        let a = try f.createIssue(title: "Fix the kitchen faucet", ["labels": .text("[\"\(l.id)\"]"), "priority": .int(2), "status": .text("todo")])
        _ = try f.createIssue(title: "Read a novel", ["priority": .int(4)])
        var q = IssueFilter(); q.labelIds = [l.id]
        #expect(try f.issues(q).map(\.id) == [a.id])
        q = IssueFilter(); q.priorities = [2]
        #expect(try f.issues(q).count == 1)
        q = IssueFilter(); q.text = "faucet"
        #expect(try f.issues(q).count == 1)
        q = IssueFilter(); q.text = "fau"
        #expect(try f.issues(q).count == 1)
        q = IssueFilter(); q.statuses = [.todo]
        #expect(try f.issues(q).count == 1)
        try f.deleteIssue(a.id)
        #expect(try f.issues(.init()).count == 1)
        q = IssueFilter(); q.text = "faucet"
        #expect(try f.issues(q).isEmpty)
    }

    @Test func deletingLabelRemovesItFromIssues() throws {
        let f = try make("hub")
        let l = try f.putLabel(name: "Buy")
        let i = try f.createIssue(title: "x", ["labels": .text("[\"\(l.id)\"]")])
        try f.delete(.labels, id: l.id)
        #expect(try f.issue(i.id).labels.isEmpty)
        #expect(try f.labels().isEmpty)
    }

    @Test func cycleNumbersMatchLinear() {
        #expect(Ledger.cycleNumber(on: "2026-11-02") == 29)
        #expect(Ledger.cycleNumber(on: "2026-11-15") == 29)
        #expect(Ledger.cycleNumber(on: "2026-11-16") == 30)
        #expect(Ledger.cycleNumber(on: "2026-10-19") == 28)
        #expect(Ledger.cycleDates(30).start == "2026-11-16")
    }

    @Test func rollCyclesMovesUnfinishedWork() throws {
        let f = try make("hub")
        _ = try f.rollCycles(today: "2026-11-03")
        let open = try f.createIssue(title: "open", ["status": .text("todo"), "cycleId": .text("cycle-28")])
        let finished = try f.createIssue(title: "done", ["status": .text("done"), "cycleId": .text("cycle-28")])
        try f.db.write { try $0.execute(sql: "INSERT OR REPLACE INTO cycles (id, number, startsAt, endsAt) VALUES ('cycle-28', 28, '2026-10-19', '2026-11-02')") }
        let current = try f.rollCycles(today: "2026-11-03")
        #expect(current.number == 29)
        #expect(try f.issue(open.id).cycleId == "cycle-29")
        #expect(try f.issue(finished.id).cycleId == "cycle-28")
        #expect(try f.cycles().map(\.number).contains(30))
    }
}

@Suite struct SyncTests {
    func setup() throws -> (hub: SyncHub, a: Ledger, b: Ledger, ta: DirectTransport, tb: DirectTransport, clock: TestClock) {
        let clock = TestClock()
        let hub = SyncHub(ledger: try make("hub", clock: clock))
        let a = try make("A", clock: clock), b = try make("B", clock: clock)
        let t = DirectTransport(hub: hub)
        return (hub, a, b, t, t, clock)
    }

    @Test func newIssueGetsHubNumberAndReachesOtherDevice() async throws {
        let s = try setup()
        let i = try s.a.createIssue(title: "From phone")
        let r = try await s.a.sync(with: s.ta)
        #expect(r.pushed == 1)
        #expect(try s.a.issue(i.id).number == 1)
        _ = try await s.b.sync(with: s.tb)
        let seen = try s.b.issue("MOR-1")
        #expect(seen.title == "From phone")
    }

    @Test func newestEditWinsOnEveryDevice() async throws {
        let s = try setup()
        let i = try s.a.createIssue(title: "t")
        _ = try await s.a.sync(with: s.ta)
        _ = try await s.b.sync(with: s.tb)
        _ = try s.a.edit(i.id, ["title": .text("from A")])
        _ = try s.b.edit(i.id, ["title": .text("from B")])   // later in time
        _ = try await s.a.sync(with: s.ta)
        _ = try await s.b.sync(with: s.tb)
        _ = try await s.a.sync(with: s.ta)
        #expect(try s.a.issue(i.id).title == "from B")
        #expect(try s.b.issue(i.id).title == "from B")
        #expect(try s.hub.ledger.issue(i.id).title == "from B")
    }

    @Test func oldEditPushedLateLoses() async throws {
        let s = try setup()
        let i = try s.a.createIssue(title: "t")
        _ = try await s.a.sync(with: s.ta)
        _ = try await s.b.sync(with: s.tb)
        _ = try s.a.edit(i.id, ["title": .text("old")])
        _ = try s.b.edit(i.id, ["title": .text("new")])
        _ = try await s.b.sync(with: s.tb)          // new reaches the hub first
        _ = try await s.a.sync(with: s.ta)          // old arrives later and loses
        #expect(try s.a.issue(i.id).title == "new")
    }

    @Test func deleteReachesOtherDevice() async throws {
        let s = try setup()
        let i = try s.a.createIssue(title: "t")
        _ = try await s.a.sync(with: s.ta)
        _ = try await s.b.sync(with: s.tb)
        try s.a.deleteIssue(i.id)
        _ = try await s.a.sync(with: s.ta)
        _ = try await s.b.sync(with: s.tb)
        #expect(try s.b.issues(.init()).isEmpty)
    }

    @Test func numberSurvivesALocalEditMadeBeforeItArrived() async throws {
        let s = try setup()
        let i = try s.a.createIssue(title: "t")
        _ = try await s.a.sync(with: s.ta)          // hub numbers it
        let again = try s.b.createIssue(title: "other")
        _ = try await s.b.sync(with: s.tb)
        #expect(try s.b.issue(again.id).number == 2)
        _ = try s.a.edit(i.id, ["title": .text("edited before pulling")])
        _ = try await s.a.sync(with: s.ta)
        #expect(try s.a.issue(i.id).number == 1)
        #expect(try s.hub.ledger.issue(i.id).number == 1)
    }

    @Test func writesOnTheHubItselfReachDevices() async throws {
        let s = try setup()
        _ = try s.hub.ledger.createIssue(title: "from Claude on the hub")
        _ = try await s.a.sync(with: s.ta)
        #expect(try s.a.issue("MOR-1").title == "from Claude on the hub")
        _ = try s.hub.ledger.edit("MOR-1", ["status": .text("today")])
        _ = try await s.a.sync(with: s.ta)
        #expect(try s.a.issue("MOR-1").status == .today)
    }

    @Test func manyRowsPage() async throws {
        let s = try setup()
        try await s.hub.ledger.db.write { db in
            for n in 1...2500 { try s.hub.ledger.put(.issues, ["title": .text("t\(n)"), "number": .int(Int64(n))], in: db) }
        }
        let r = try await s.a.sync(with: s.ta)
        #expect(r.pulled == 2500)
        #expect(try s.a.issues({ var f = IssueFilter(); f.limit = 5000; return f }()).count == 2500)
    }
}

@Suite struct ImportTests {
    let issues = Data("""
    {"issues":[
     {"id":"MOR-222","uuid":"u-222","title":"Parent","description":"d","priority":{"value":2,"name":"High"},"createdAt":"2026-10-01T05:00:00.000Z","archivedAt":null,"completedAt":null,"startedAt":null,"canceledAt":null,"dueDate":"2026-11-11","status":"Todo","labels":["Home","Buy"],"cycleId":"c-29"},
     {"id":"MOR-69","uuid":"u-69","title":"Child","description":null,"priority":{"value":0,"name":"No priority"},"createdAt":"2026-10-02T05:00:00.000Z","archivedAt":"2026-10-20T05:00:00.000Z","completedAt":"2026-10-10T05:00:00.000Z","startedAt":null,"canceledAt":null,"dueDate":null,"status":"Done","labels":[],"cycleId":null,"parentId":"MOR-222"}
    ],"hasNextPage":false}
    """.utf8)
    let cycles = Data(#"[{"id":"c-29","number":29,"startsAt":"2026-11-02T06:00:00.000Z","endsAt":"2026-11-16T06:00:00.000Z"}]"#.utf8)

    @Test func importsAndIsRepeatable() throws {
        let f = try make("hub")
        let r = try f.importLinear(issuePages: [issues], cycles: cycles)
        #expect(r == ImportReport(issues: 2, skipped: 0, labels: 2, cycles: 1))
        let parent = try f.issue("MOR-222")
        #expect(parent.status == .todo && parent.priority == 2 && parent.cycleId == "cycle-29" && parent.labels.count == 2)
        let child = try f.issue("MOR-69")
        #expect(child.parentId == parent.id && child.status == .done && child.archivedAt != nil && child.completedAt != nil)
        #expect(try f.cycles().first?.startsAt == "2026-11-02")
        let again = try f.importLinear(issuePages: [issues], cycles: cycles)
        #expect(again.issues == 0 && again.skipped == 2)
        #expect(try f.issues({ var q = IssueFilter(); q.includeArchived = true; return q }()).count == 2)
    }

    @Test func newIssuesContinueNumbering() async throws {
        let hub = SyncHub(ledger: try make("hub"))
        _ = try hub.ledger.importLinear(issuePages: [issues], cycles: cycles)
        let a = try make("A")
        let t = DirectTransport(hub: hub)
        _ = try await a.sync(with: t)
        let i = try a.createIssue(title: "new")
        _ = try await a.sync(with: t)
        #expect(try a.issue(i.id).number == 223)
    }
}
