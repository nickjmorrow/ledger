import LedgerCore
import Foundation
import Network

/// The hub's network side: one HTTP/1.1 request per connection on 127.0.0.1 (put `tailscale serve` in front for the tailnet).
final class SyncServer: @unchecked Sendable {
    let http: SyncHTTP
    private let listener: NWListener
    private let queue = DispatchQueue(label: "ledger-sync")

    init(http: SyncHTTP, port: UInt16 = 0) throws {
        self.http = http
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        listener = port == 0 ? try NWListener(using: params) : try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        listener.newConnectionHandler = { [http, queue] conn in Connection(conn, http: http, queue: queue).start() }
    }

    /// Starts listening and returns the port (useful when asked for port 0).
    func start() throws -> UInt16 {
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success, let port = listener.port else { throw LedgerError.invalid("could not start the sync server") }
        return port.rawValue
    }

    func stop() { listener.cancel() }
}

private final class Connection {
    let conn: NWConnection, http: SyncHTTP, queue: DispatchQueue
    var buffer = Data()
    var responded = false

    init(_ c: NWConnection, http: SyncHTTP, queue: DispatchQueue) { conn = c; self.http = http; self.queue = queue }

    func start() { conn.start(queue: queue); receive() }

    func receive() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [self] data, _, done, error in
            if responded { return }
            if let data { buffer.append(data) }
            if error != nil { conn.cancel(); return }
            if let req = parse() { respond(req) } else if responded { return } else if done { conn.cancel() }
            else if buffer.count > SyncHTTP.maxBody + 65536 { send(413, "too large") } else { receive() }
        }
    }

    struct Request { var method: String; var path: String; var query: [String: String]; var auth: String?; var body: Data }

    func parse() -> Request? {
        guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let parts = head[0].split(separator: " ")
        guard parts.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for l in head.dropFirst() { if let i = l.firstIndex(of: ":") { headers[l[..<i].lowercased()] = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces) } }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        guard http.isAuthorized(headers["authorization"]) else { send(401, "unauthorized"); return nil }
        guard length <= SyncHTTP.maxBody else { send(413, "too large"); return nil }
        guard buffer.count >= end.upperBound + length else { return nil }
        let body = buffer[end.upperBound..<(end.upperBound + length)]
        let comps = URLComponents(string: String(parts[1]))
        var q: [String: String] = [:]
        comps?.queryItems?.forEach { q[$0.name] = $0.value }
        return Request(method: String(parts[0]), path: comps?.path ?? String(parts[1]), query: q, auth: headers["authorization"], body: Data(body))
    }

    func respond(_ r: Request) {
        let res = http.handle(method: r.method, path: r.path, query: r.query, authorization: r.auth, body: r.body)
        send(res.status, nil, res)
    }

    func send(_ status: Int, _ text: String?, _ res: SyncHTTP.Response? = nil) {
        responded = true
        let body = res?.body ?? Data((text ?? "").utf8)
        let head = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Status")\r\nContent-Type: \(res?.contentType ?? "text/plain")\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        conn.send(content: Data(head.utf8) + body, completion: .contentProcessed { [conn] _ in conn.cancel() })
    }
}
