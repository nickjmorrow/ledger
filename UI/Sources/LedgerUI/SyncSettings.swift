import Foundation
import LedgerCore

/// Where this device syncs to. Resolved from, in order: what the user saved in Settings, the Info.plist keys injected from .env at project
/// generation (LedgerHubURL / LedgerHubToken / LedgerHubHost), and on the Mac ~/Library/Application Support/Ledger/sync.json.
public struct SyncSettings: Equatable, Codable, Sendable {
    public var url: String
    public var token: String
    public var hostHeader: String?

    public init(url: String, token: String, hostHeader: String? = nil) {
        self.url = url.trimmingCharacters(in: .whitespacesAndNewlines)
        self.token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let h = hostHeader?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.hostHeader = (h?.isEmpty ?? true) ? nil : h
    }

    public var isValid: Bool { !token.isEmpty && URL(string: url)?.host != nil }
    public func transport() -> HTTPSyncTransport? { URL(string: url).map { HTTPSyncTransport(baseURL: $0, token: token, hostHeader: hostHeader) } }

    enum Key { static let url = "hubURL", token = "hubToken", host = "hubHost" }

    public static func saved(_ d: UserDefaults) -> SyncSettings? {
        guard let u = d.string(forKey: Key.url), let t = d.string(forKey: Key.token) else { return nil }
        let s = SyncSettings(url: u, token: t, hostHeader: d.string(forKey: Key.host))
        return s.isValid ? s : nil
    }

    public func save(to d: UserDefaults) {
        d.set(url, forKey: Key.url); d.set(token, forKey: Key.token); d.set(hostHeader, forKey: Key.host)
    }

    public static func clear(_ d: UserDefaults) { [Key.url, Key.token, Key.host].forEach { d.removeObject(forKey: $0) } }

    public static func fromInfo(_ info: [String: Any]?) -> SyncSettings? {
        guard let u = info?["LedgerHubURL"] as? String, let t = info?["LedgerHubToken"] as? String else { return nil }
        let s = SyncSettings(url: u, token: t, hostHeader: info?["LedgerHubHost"] as? String)
        return s.isValid ? s : nil
    }

    /// {"url": "...", "token": "...", "hostHeader": "..."}
    public static func fromFile(_ url: URL?) -> SyncSettings? {
        guard let url, let data = try? Data(contentsOf: url), let s = try? JSONDecoder().decode(SyncSettings.self, from: data) else { return nil }
        let clean = SyncSettings(url: s.url, token: s.token, hostHeader: s.hostHeader)
        return clean.isValid ? clean : nil
    }

    public static func resolve(defaults: UserDefaults, info: [String: Any]? = Bundle.main.infoDictionary, file: URL? = Self.defaultFile) -> SyncSettings? {
        saved(defaults) ?? fromInfo(info) ?? fromFile(file)
    }

    public static var defaultFile: URL? {
        #if os(macOS)
        return supportDirectory().appendingPathComponent("sync.json")
        #else
        return nil
        #endif
    }

    /// ~/Library/Application Support/Ledger (the app's own on iOS).
    public static func supportDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Ledger", isDirectory: true)
    }
}
