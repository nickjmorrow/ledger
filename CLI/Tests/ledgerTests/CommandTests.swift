import Foundation
import Testing
import LedgerCore
@testable import ledger

private func tempDB() -> String { NSTemporaryDirectory() + "ledger-test-\(UUID().uuidString)/ledger.sqlite" }

/// A database the way the CLI would open it, for tests that use Core directly.
private func open(_ path: String, device: String) throws -> Ledger {
    try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    return try Ledger(path: path, device: device)
}

private func json(_ s: String) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any])
}

private func jsonList(_ s: String) throws -> [[String: Any]] {
    try #require(JSONSerialization.jsonObject(with: Data(s.utf8)) as? [[String: Any]])
}

private func run(_ args: String..., db: String, device: String = "dev1") async -> RunResult {
    await Runner.run(args + ["--db", db, "--device", device])
}

@Suite struct IssueCommandTests {
    @Test func createEditListRoundTrip() async throws {
        let db = tempDB()
        #expect(await run("label", "put", "Home", "--color", "#6fd3a0", db: db).code == 0)
        #expect(await run("project", "put", "Garden", db: db).code == 0)
        let made = await run("issue", "create", "--title", "Buy soil", "--status", "todo", "--priority", "high", "--due", "2026-11-20",
                             "--label", "home", "--project", "garden", "--description", "peat free", "--recur", "week:2", db: db)
        #expect(made.code == 0, Comment(rawValue: made.err))
        let issue = try json(made.out)
        #expect(issue["title"] as? String == "Buy soil")
        #expect(issue["status"] as? String == "todo")
        #expect(issue["priority"] as? Int == 2)
        #expect(issue["labelNames"] as? [String] == ["Home"])
        #expect(issue["project"] as? String == "Garden")
        #expect(issue["cycle"] as? Int == Ledger.cycleNumber(on: Ledger.day()))
        #expect((issue["recur"] as? String)?.contains("\"week\"") == true)
        let id = try #require(issue["id"] as? String)

        let edited = await run("issue", "edit", id, "--status", "today", "--priority", "urgent", "--add-label", "Home", "--due", "none", db: db)
        #expect(edited.code == 0, Comment(rawValue: edited.err))
        let e = try json(edited.out)
        #expect(e["status"] as? String == "today" && e["priority"] as? Int == 1 && e["dueDate"] == nil)
        #expect(e["startedAt"] is String)

        let list = try jsonList(await run("issue", "list", "--status", "today", "--label", "Home", "--project", "Garden", "--search", "soil", db: db).out)
        #expect(list.count == 1 && list[0]["id"] as? String == id)
        #expect(try jsonList(await run("issue", "list", "--status", "done", db: db).out).isEmpty)

        let done = try json(await run("issue", "edit", id, "--json", "{\"status\":\"done\",\"labels\":[]}", db: db).out)
        #expect(done["completedAt"] is String && (done["labelNames"] as? [String])?.isEmpty == true)
        // completing a recurring issue made the next one
        let all = try jsonList(await run("issue", "list", db: db).out)
        #expect(all.count == 2 && all.contains { $0["status"] as? String == "todo" })

        #expect(await run("issue", "delete", id, db: db).code == 0)
        #expect(try jsonList(await run("issue", "list", db: db).out).count == 1)
    }

    @Test func createFromJSONWithParentAndShow() async throws {
        let db = tempDB()
        let ledger = try open(db, device: "dev1")
        let parent = try ledger.createIssue(title: "Parent")
        _ = try ledger.edit(parent.id, ["number": .int(7)])
        let r = await run("issue", "create", "--json", "{\"title\":\"Child\",\"parent\":\"MOR-7\",\"priority\":\"low\",\"cycle\":\"none\"}", db: db)
        #expect(r.code == 0, Comment(rawValue: r.err))
        let child = try json(r.out)
        #expect(child["parent"] as? String == "MOR-7" && child["priority"] as? Int == 4 && child["cycleId"] == nil)
        let shown = try json(await run("issue", "show", "MOR-7", db: db).out)
        #expect(shown["subIssues"] as? [String] == ["MOR-? Child"])
        let bySub = try jsonList(await run("issue", "list", "--parent", "7", db: db).out)
        #expect(bySub.count == 1)
    }

    @Test func namesResolveCaseInsensitivelyAndUnknownNamesListTheChoices() async throws {
        let db = tempDB()
        _ = await run("label", "put", "Errands", db: db)
        _ = await run("project", "put", "House", db: db)
        let ok = await run("issue", "create", "--title", "x", "--label", "ERRANDS", "--project", "house", db: db)
        #expect(ok.code == 0)
        let badLabel = await run("issue", "create", "--title", "y", "--label", "Errnds", db: db)
        #expect(badLabel.code == 1 && badLabel.out.isEmpty)
        let msg = try #require(try json(badLabel.err)["error"] as? String)
        #expect(msg.contains("Errnds") && msg.contains("Errands"))
        let badProject = await run("issue", "list", "--project", "Nope", db: db)
        #expect(badProject.code == 1 && badProject.err.contains("House"))
        #expect(await run("issue", "list", "--cycle", "999", db: db).err.contains("no cycle 999"))
        // nothing was created by the failed commands
        #expect(try jsonList(await run("issue", "list", db: db).out).count == 1)
    }

    @Test func badInputGivesJSONErrors() async throws {
        let db = tempDB()
        let cases: [([String], String)] = [
            (["issue", "create"], "needs a title"),
            (["issue", "create", "--title", "x", "--status", "blocked"], "status must be one of"),
            (["issue", "create", "--title", "x", "--priority", "5"], "priority must be"),
            (["issue", "create", "--title", "x", "--due", "tomorrow"], "dueDate must look like"),
            (["issue", "create", "--title", "x", "--recur", "yearly:1"], "recur must look like"),
            (["issue", "create", "--json", "not json"], "--json must be an object"),
            (["issue", "create", "--json", "{\"title\":\"x\",\"colour\":1}"], "unknown field colour"),
            (["issue", "show", "MOR-404"], "no issue MOR-404"),
            (["issue", "edit", "MOR-404", "--title", "x"], "no issue MOR-404"),
            (["issue", "delete", "MOR-404"], "no issue MOR-404"),
            (["issue", "list", "--status", "nope"], "status must be one of"),
            (["issue", "list", "--due-before", "soon"], "--due-before"),
            (["issue", "bogus"], "Usage: ledger issue"),
        ]
        for (args, expected) in cases {
            let r = await Runner.run(args + ["--db", db, "--device", "d"])
            #expect(r.code == 1 && r.out.isEmpty, Comment(rawValue: "\(args)"))
            #expect(try json(r.err)["error"] as? String != nil)
            #expect(r.err.contains(expected), Comment(rawValue: "\(args): \(r.err)"))
        }
        let ledger = try open(db, device: "d")
        let i = try ledger.createIssue(title: "x")
        #expect(await run("issue", "edit", i.id, db: db).err.contains("nothing to change"))
        #expect(await run("issue", "edit", i.id, "--parent", i.id, db: db).err.contains("own parent"))
    }

    @Test func labelProjectViewCrud() async throws {
        let db = tempDB()
        #expect(await run("label", "put", "Work", db: db).code == 0)
        #expect(await run("label", "put", "work", "--color", "#111111", "--rename", "Job", db: db).code == 0)
        let labels = try jsonList(await run("label", "list", db: db).out)
        #expect(labels.count == 1 && labels[0]["name"] as? String == "Job" && labels[0]["color"] as? String == "#111111")
        _ = await run("issue", "create", "--title", "t", "--label", "job", db: db)
        #expect(await run("label", "delete", "Job", db: db).code == 0)
        #expect(try jsonList(await run("issue", "list", db: db).out)[0]["labelNames"] as? [String] == [])

        #expect(await run("project", "put", "P", "--description", "d", db: db).code == 0)
        #expect(try jsonList(await run("project", "list", db: db).out)[0]["description"] as? String == "d")
        #expect(await run("project", "delete", "p", db: db).code == 0)
        #expect(try jsonList(await run("project", "list", db: db).out).isEmpty)

        #expect(await run("view", "put", "Mine", "--filter", "{\"status\":[\"today\"]}", "--layout", "board", db: db).code == 0)
        #expect(try jsonList(await run("view", "list", db: db).out)[0]["layout"] as? String == "board")
        #expect(await run("view", "put", "Mine", "--layout", "grid", db: db).err.contains("list or board"))
        #expect(await run("view", "put", "Mine", "--filter", "[1]", db: db).err.contains("JSON object"))
        #expect(await run("view", "delete", "Mine", db: db).code == 0)
        #expect(await run("view", "delete", "Mine", db: db).code == 1)
    }

    @Test func summaryCyclesAndSQL() async throws {
        let db = tempDB()
        _ = await run("issue", "create", "--title", "a", "--status", "today", db: db)
        _ = await run("issue", "create", "--title", "b", db: db)
        let s = try json(await run("summary", db: db).out)
        let counts = try #require(s["counts"] as? [String: Int])
        #expect(counts["today"] == 1 && counts["inbox"] == 1 && counts["done"] == 0)
        #expect((s["today"] as? [[String: Any]])?.count == 1)
        let cycle = try #require(s["cycle"] as? [String: Any])
        #expect(cycle["number"] as? Int == Ledger.cycleNumber(on: Ledger.day()) && cycle["open"] as? Int == 2)
        #expect(try jsonList(await run("cycle", "list", db: db).out).count == 2)
        #expect(await run("cycle", "roll", db: db).code == 0)

        let q = try json(await run("sql", "select count(*) as n from issues", db: db).out)
        #expect((q["rows"] as? [[Int]]) == [[2]])
        #expect(await run("sql", "delete from issues", db: db).err.contains("read-only"))
        #expect(await run("sql", "select 1; delete from issues", db: db).code == 1)
        #expect(try #require(try json(await run("schema", db: db).out)["rows"] as? [[Any]]).count >= 5)
    }

    @Test func dbFlagWinsOverEnvironmentAndHubNumbersItsOwnWrites() async throws {
        let db = tempDB()
        let r = await run("issue", "create", "--title", "hub made", db: db, device: "hub")
        #expect(try json(r.out)["identifier"] as? String == "MOR-1")
        let next = await run("issue", "create", "--title", "second", db: db, device: "hub")
        #expect(try json(next.out)["number"] as? Int == 2)
        // the device name stuck, so later runs without --device still are the hub
        #expect(try Ledger(path: db).device == "hub")
    }

    @Test func importLinearDump() async throws {
        let dir = NSTemporaryDirectory() + "ledger-import-\(UUID().uuidString)/"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try Data("""
        {"issues":[{"id":"MOR-41","uuid":"u1","title":"Old","priority":{"value":3},"createdAt":"2026-10-01T10:00:00.000Z","status":"Done","completedAt":"2026-10-02T10:00:00.000Z","labels":["Home"],"cycleId":"c1"},
                   {"id":"MOR-42","uuid":"u2","title":"New","priority":{"value":0},"createdAt":"2026-10-03T10:00:00.000Z","status":"Todo","labels":[],"parentId":"MOR-41"}]}
        """.utf8).write(to: URL(fileURLWithPath: dir + "i.json"))
        try Data("[{\"id\":\"c1\",\"number\":28,\"startsAt\":\"2026-10-19T00:00:00.000Z\",\"endsAt\":\"2026-11-02T00:00:00.000Z\"}]".utf8).write(to: URL(fileURLWithPath: dir + "c.json"))
        let db = tempDB()
        let r = await run("import-linear", "--issues", dir + "i.json", "--cycles", dir + "c.json", db: db, device: "hub")
        #expect(r.code == 0, Comment(rawValue: r.err))
        #expect(try json(r.out)["issues"] as? Int == 2)
        let again = try json(await run("import-linear", "--issues", dir + "i.json", "--cycles", dir + "c.json", db: db, device: "hub").out)
        #expect(again["skipped"] as? Int == 2 && again["issues"] as? Int == 0)
        let shown = try json(await run("issue", "show", "MOR-42", db: db).out)
        #expect(shown["parent"] as? String == "MOR-41")
        // a new issue continues the numbering
        #expect(try json(await run("issue", "create", "--title", "n", db: db, device: "hub").out)["number"] as? Int == 43)
        #expect(await run("import-linear", "--issues", "/nope.json", "--cycles", dir + "c.json", db: db).err.contains("can't read"))
        #expect(await run("import-linear", "--issues", dir + "c.json", "--cycles", dir + "c.json", db: db).err.contains("Linear dump shape"))
    }
}

@Suite struct SyncCommandTests {
    private func hub() throws -> (SyncServer, Ledger, UInt16) {
        let hubLedger = try open(tempDB(), device: "hub")
        let server = try SyncServer(http: SyncHTTP(hub: SyncHub(ledger: hubLedger), tokens: ["tok": "anyone"]))
        return (server, hubLedger, try server.start())
    }

    @Test func twoDevicesShareThroughARealServer() async throws {
        let (server, hubLedger, port) = try hub()
        defer { server.stop() }
        let a = tempDB(), b = tempDB()
        let url = "http://127.0.0.1:\(port)"
        for (db, dev) in [(a, "a"), (b, "b")] { #expect(await run("sync-setup", "--url", url, "--token", "tok", db: db, device: dev).code == 0) }
        let made = try json(await run("issue", "create", "--title", "from a", db: a, device: "a").out)
        #expect(made["identifier"] as? String == "MOR-?")
        let first = try json(await run("sync", db: a, device: "a").out)
        #expect((first["pushed"] as? Int ?? 0) >= 1)
        // the hub numbered it, and a learned the number on its pull
        #expect(try hubLedger.issue("MOR-1").title == "from a")
        #expect(try json(await run("sync", db: a, device: "a").out)["pushed"] as? Int == 0)
        #expect(try json(await run("issue", "show", made["id"] as! String, db: a, device: "a").out)["identifier"] as? String == "MOR-1")
        // b gets it with its number, and its own new issue continues the numbering
        #expect(await run("sync", db: b, device: "b").code == 0)
        #expect(try json(await run("issue", "show", "MOR-1", db: b, device: "b").out)["title"] as? String == "from a")
        _ = await run("issue", "create", "--title", "from b", db: b, device: "b")
        #expect(await run("sync", db: b, device: "b").code == 0)
        #expect(try hubLedger.issue("MOR-2").title == "from b")
        // an edit on b reaches a
        #expect(await run("issue", "edit", "MOR-1", "--status", "done", db: b, device: "b").code == 0)
        #expect(await run("sync", db: b, device: "b").code == 0)
        #expect(await run("sync", db: a, device: "a").code == 0)
        #expect(try json(await run("issue", "show", "MOR-1", db: a, device: "a").out)["status"] as? String == "done")
    }

    @Test func aDeviceSyncsThroughHTTPSyncTransport() async throws {
        let (server, hubLedger, port) = try hub()
        defer { server.stop() }
        let dev = try open(tempDB(), device: "phone")
        let made = try dev.createIssue(title: "typed on phone")
        let transport = HTTPSyncTransport(baseURL: URL(string: "http://127.0.0.1:\(port)")!, token: "tok")
        let report = try await dev.sync(with: transport)
        #expect(report.pushed >= 1 && report.pulled >= 1)
        #expect(try dev.issue(made.id).number == 1)
        #expect(try hubLedger.issue("MOR-1").title == "typed on phone")
        // a hub-side CLI write (as the hub device) is numbered and reaches the phone
        let viaCLI = try json(await Runner.run(["issue", "create", "--title", "by claude", "--db", hubLedger.db.path, "--device", "hub"]).out)
        #expect(viaCLI["number"] as? Int == 2)
        _ = try await dev.sync(with: transport)
        #expect(try dev.issue("MOR-2").title == "by claude")
    }

    @Test func serverRefusesWithoutAValidToken() async throws {
        let (server, _, port) = try hub()
        defer { server.stop() }
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/sync/pull?since=0")!)
        req.httpMethod = "POST"
        #expect((try await URLSession.shared.data(for: req).1 as? HTTPURLResponse)?.statusCode == 401)
        req.setValue("Bearer wrong", forHTTPHeaderField: "Authorization")
        #expect((try await URLSession.shared.data(for: req).1 as? HTTPURLResponse)?.statusCode == 401)
        req.setValue("Bearer tok", forHTTPHeaderField: "Authorization")
        #expect((try await URLSession.shared.data(for: req).1 as? HTTPURLResponse)?.statusCode == 200)
    }

    @Test func syncNeedsSetupFirstAndWrongTokenIsClear() async throws {
        let r = await run("sync", db: tempDB())
        #expect(r.code == 1 && r.err.contains("sync-setup"))
        let (server, _, port) = try hub()
        defer { server.stop() }
        let db = tempDB()
        _ = await run("sync-setup", "--url", "http://127.0.0.1:\(port)", "--token", "wrong", "--host-header", "x.ts.net:1", db: db)
        _ = await run("issue", "create", "--title", "t", db: db)
        let bad = await run("sync", db: db)
        #expect(bad.code == 1 && bad.err.contains("401"))
        let cfg = try #require(SyncConfig.load(besideDatabaseAt: db))
        #expect(cfg.hostHeader == "x.ts.net:1")
        let mode = try FileManager.default.attributesOfItem(atPath: SyncConfig.file(besideDatabaseAt: db).path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        #expect(await run("sync-setup", "--url", "nonsense", "--token", "t", db: db).err.contains("--url"))
    }
}
