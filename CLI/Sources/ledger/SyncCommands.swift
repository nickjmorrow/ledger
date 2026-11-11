import ArgumentParser
import LedgerCore
import Foundation

/// Where and as whom this install syncs. It holds a token, so it lives in its own file (mode 600) next to the database.
/// Keys: url, token, hostHeader.
struct SyncConfig: Codable, Equatable {
    var url: URL
    var token: String
    /// Sent as the Host header, to reach the hub by its tailnet IP while Tailscale routes by name.
    var hostHeader: String?

    static func file(besideDatabaseAt path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).deletingLastPathComponent).appendingPathComponent("sync.json")
    }

    static func load(besideDatabaseAt path: String) -> SyncConfig? {
        try? JSONDecoder().decode(SyncConfig.self, from: Data(contentsOf: file(besideDatabaseAt: path)))
    }

    func save(besideDatabaseAt path: String) throws {
        let url = Self.file(besideDatabaseAt: path)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func transport() -> HTTPSyncTransport { HTTPSyncTransport(baseURL: url, token: token, hostHeader: hostHeader) }
}

struct SyncSetup: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "sync-setup", abstract: "Save the hub address and token for this database (kept in sync.json beside it, readable only by you).")
    @OptionGroup var global: GlobalOptions
    @Option(help: "Hub URL, like http://hub.example.ts.net:8455.") var url: String
    @Option(help: "This install's token from the hub's tokens file.") var token: String
    @Option(name: .customLong("host-header"), help: "Send this Host header (to reach the hub by its tailnet IP while Tailscale routes by name).") var hostHeader: String?
    func run() throws {
        guard let parsed = URL(string: url), parsed.scheme != nil, parsed.host != nil else { throw LedgerError.invalid("--url must look like http://host:port") }
        let ledger = try global.open()
        try SyncConfig(url: parsed, token: token, hostHeader: hostHeader).save(besideDatabaseAt: global.databasePath)
        try Output.json(["configured": "true", "device": ledger.device, "file": SyncConfig.file(besideDatabaseAt: global.databasePath).path])
    }
}

struct SyncCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "sync", abstract: "Send this database's changes to the hub and apply everyone else's.")
    @OptionGroup var global: GlobalOptions
    func run() async throws {
        guard let config = SyncConfig.load(besideDatabaseAt: global.databasePath) else {
            throw LedgerError.invalid("sync isn't set up here: run ledger sync-setup --url <hub url> --token <token>")
        }
        let ledger = try global.open()
        try ledger.rollCycles()
        try Output.json(try await ledger.sync(with: config.transport()))
    }
}

struct SyncServe: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "sync-serve", abstract: "Run the sync hub on 127.0.0.1 over this database (put `tailscale serve` in front of it).")
    @OptionGroup var global: GlobalOptions
    @Option(help: "JSON file mapping tokens to a label, e.g. {\"<token>\": \"iphone\"}.") var tokens: String
    @Option(help: "Port on 127.0.0.1.") var port: UInt16 = 8793

    func run() async throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: (tokens as NSString).expandingTildeInPath))
        guard let map = try JSONSerialization.jsonObject(with: data) as? [String: String], !map.isEmpty else {
            throw LedgerError.invalid("tokens file must be a non-empty JSON object of token → label")
        }
        let server = try SyncServer(http: SyncHTTP(hub: SyncHub(ledger: try global.open()), tokens: map), port: port)
        let actual = try server.start()
        print("ledger sync hub listening on 127.0.0.1:\(actual), \(map.count) token(s)")
        fflush(stdout)
        while true { try await Task.sleep(nanoseconds: 3_600_000_000_000) }
    }
}

struct ImportLinear: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "import-linear", abstract: "Import a Linear dump (list_issues pages and list_cycles) into this database. Re-running skips issues already imported.")
    @OptionGroup var global: GlobalOptions
    @Option(parsing: .upToNextOption, help: "One or more list_issues result files.") var issues: [String]
    @Option(help: "The list_cycles result file.") var cycles: String
    @Flag(help: "Replace issues that were already imported.") var overwrite = false
    func run() throws {
        func read(_ p: String) throws -> Data {
            do { return try Data(contentsOf: URL(fileURLWithPath: (p as NSString).expandingTildeInPath)) } catch { throw LedgerError.invalid("can't read \(p)") }
        }
        let ledger = try global.open()
        let report: ImportReport
        do { report = try ledger.importLinear(issuePages: try issues.map(read), cycles: try read(cycles), overwrite: overwrite) }
        catch is DecodingError { throw LedgerError.invalid("those files aren't in the Linear dump shape (list_issues pages and a list_cycles array)") }
        try global.settle(ledger)
        try Output.json(report)
    }
}
