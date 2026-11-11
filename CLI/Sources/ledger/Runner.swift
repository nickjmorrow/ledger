import ArgumentParser
import LedgerCore
import Foundation

struct RunResult {
    var code: Int32
    var out: String
    var err: String
}

final class OutputBuffer: @unchecked Sendable {
    var text = ""
}

enum Output {
    /// Each invocation of `Runner.run` gets its own buffer, so concurrent runs (tests) never mix their output.
    @TaskLocal static var current = OutputBuffer()

    static func json<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        current.text += String(decoding: try encoder.encode(value), as: UTF8.self) + "\n"
    }
}

/// Parses and runs one invocation; success prints JSON to out, failure prints {"error": ...} to err with code 1.
enum Runner {
    static func run(_ args: [String]) async -> RunResult {
        let buffer = OutputBuffer()
        return await Output.$current.withValue(buffer) { await execute(args, buffer) }
    }

    private static func execute(_ args: [String], _ buffer: OutputBuffer) async -> RunResult {
        var command: ParsableCommand
        do {
            command = try LedgerCommand.parseAsRoot(args)
        } catch {
            let code = LedgerCommand.exitCode(for: error).rawValue
            let message = LedgerCommand.fullMessage(for: error) + "\n"
            return code == 0 ? RunResult(code: 0, out: message, err: "") : RunResult(code: 1, out: "", err: errorJSON(message))
        }
        do {
            if var async = command as? AsyncParsableCommand { try await async.run() } else { try command.run() }
            return RunResult(code: 0, out: buffer.text, err: "")
        } catch {
            return RunResult(code: 1, out: "", err: errorJSON("\(error)"))
        }
    }

    private static func errorJSON(_ message: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: ["error": message.trimmingCharacters(in: .whitespacesAndNewlines)], options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self) + "\n"
    }
}

struct GlobalOptions: ParsableArguments {
    @Option(help: "Database file. Defaults to $LEDGER_DB, else ~/Library/Application Support/Ledger/ledger.sqlite.")
    var db: String?

    @Option(help: "This database's device name. Defaults to $LEDGER_DEVICE, else a random one kept in the database. The hub's is `hub`.")
    var device: String?

    var databasePath: String {
        let p = db ?? ProcessInfo.processInfo.environment["LEDGER_DB"] ?? (NSHomeDirectory() + "/Library/Application Support/Ledger/ledger.sqlite")
        return (p as NSString).expandingTildeInPath
    }

    func open() throws -> Ledger {
        try FileManager.default.createDirectory(atPath: (databasePath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let name = device ?? ProcessInfo.processInfo.environment["LEDGER_DEVICE"].flatMap { $0.isEmpty ? nil : $0 }
        let ledger = try Ledger(path: databasePath, device: name)
        if let name, try ledger.meta("device") == nil { try ledger.setMeta("device", name) }  // so the name sticks without the variable
        return ledger
    }

    /// On the hub itself, a change made here is numbered and ordered straight away (elsewhere that waits for the next sync).
    func settle(_ ledger: Ledger) throws {
        guard ledger.device == "hub" else { return }
        let hub = SyncHub(ledger: ledger)
        _ = try hub.pull(since: try hub.head(), limit: 1)
    }
}
