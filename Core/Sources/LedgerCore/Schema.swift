import GRDB

/// The synced tables. Every one also has the common columns below, so sync can treat them all the same way.
public enum Table: String, CaseIterable, Sendable {
    case issues, labels, cycles, projects, savedViews

    public var columns: [(name: String, type: String)] {
        switch self {
        case .issues: return [
            ("number", "INTEGER"), ("title", "TEXT NOT NULL DEFAULT ''"), ("description", "TEXT NOT NULL DEFAULT ''"),
            ("status", "TEXT NOT NULL DEFAULT 'inbox'"), ("priority", "INTEGER NOT NULL DEFAULT 0"), ("dueDate", "TEXT"),
            ("cycleId", "TEXT"), ("projectId", "TEXT"), ("parentId", "TEXT"), ("labels", "TEXT NOT NULL DEFAULT '[]'"),
            ("recur", "TEXT"), ("sortOrder", "REAL NOT NULL DEFAULT 0"), ("createdAt", "TEXT NOT NULL DEFAULT ''"),
            ("startedAt", "TEXT"), ("completedAt", "TEXT"), ("canceledAt", "TEXT"), ("archivedAt", "TEXT"), ("linearId", "TEXT"),
        ]
        case .labels: return [("name", "TEXT NOT NULL DEFAULT ''"), ("color", "TEXT NOT NULL DEFAULT '#98a2c4'")]
        case .cycles: return [("number", "INTEGER NOT NULL DEFAULT 0"), ("startsAt", "TEXT NOT NULL DEFAULT ''"), ("endsAt", "TEXT NOT NULL DEFAULT ''"), ("title", "TEXT")]
        case .projects: return [
            ("name", "TEXT NOT NULL DEFAULT ''"), ("color", "TEXT NOT NULL DEFAULT '#ffc83d'"),
            ("description", "TEXT NOT NULL DEFAULT ''"), ("status", "TEXT NOT NULL DEFAULT 'active'"),
        ]
        case .savedViews: return [
            ("name", "TEXT NOT NULL DEFAULT ''"), ("filter", "TEXT NOT NULL DEFAULT '{}'"),
            ("layout", "TEXT NOT NULL DEFAULT 'list'"), ("sortOrder", "REAL NOT NULL DEFAULT 0"),
        ]
        }
    }

    public var dataColumnNames: Set<String> { Set(columns.map(\.name)) }
    static let commonColumns: Set<String> = ["id", "ts", "device", "deleted", "seq", "dirty"]
}

enum Schema {
    static func migrate(_ db: Database) throws {
        for t in Table.allCases {
            let cols = t.columns.map { "\"\($0.name)\" \($0.type)" }.joined(separator: ", ")
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS "\(t.rawValue)" (
                    id TEXT PRIMARY KEY, ts INTEGER NOT NULL DEFAULT 0, device TEXT NOT NULL DEFAULT '',
                    deleted INTEGER NOT NULL DEFAULT 0, seq INTEGER, dirty INTEGER NOT NULL DEFAULT 0, \(cols))
                """)
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS \"\(t.rawValue)_seq\" ON \"\(t.rawValue)\"(seq)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS \"\(t.rawValue)_dirty\" ON \"\(t.rawValue)\"(dirty) WHERE dirty = 1")
        }
        try db.execute(sql: "CREATE UNIQUE INDEX IF NOT EXISTS issues_number ON issues(number) WHERE number IS NOT NULL")
        try db.execute(sql: "CREATE INDEX IF NOT EXISTS issues_linear ON issues(linearId) WHERE linearId IS NOT NULL")
        try db.execute(sql: "CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
        if try !db.tableExists("issues_ft") {
            try db.create(virtualTable: "issues_ft", using: FTS5()) { t in
                t.synchronize(withTable: "issues")
                t.column("title")
                t.column("description")
            }
        }
    }
}
