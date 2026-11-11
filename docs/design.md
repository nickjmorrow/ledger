# Ledger: design

A personal task tracker in the style of Linear. Native Swift app for Mac and iPhone, one SQLite database on a home server as the hub, a CLI and MCP server for Claude.

Scope of the first version: native Swift; a hub reached over Tailscale; no login (the tailnet is the lock, plus one bearer token per device); list and board views, ⌘K, Linear's shortcuts, Markdown descriptions, labels, priority, due dates, cycles, sub-issues, search, filters, saved views, projects, recurring tasks; six fixed statuses; automatic 2-week cycles; MOR-n issue numbers; a one-time import from Linear's API (or a Linear connector dump); CLI and MCP for Claude; Midnight Sun look; nightly backup copy on the hub.

## Layout

| Folder | What |
| --- | --- |
| `Core/` | `LedgerCore` (Swift 6, GRDB): schema, store, operations, import, sync client and hub logic |
| `CLI/` | `ledger`: JSON command line over Core, plus `sync-serve` (the hub) and `import-linear` |
| `UI/` | `LedgerUI`: SwiftUI screens shared by Mac and iPhone |
| `App/` | XcodeGen project: macOS and iOS apps |
| `mcp/` | stdio MCP server wrapping the CLI |

## Data model (`Core/Sources/LedgerCore/Schema.swift`)

Every synced table has `id TEXT PRIMARY KEY` (UUID), `ts INTEGER` (logical timestamp), `device TEXT`, `deleted INTEGER`, `seq INTEGER` (hub order; NULL on a device until the hub numbers it), `dirty INTEGER` (device only: changed since last push).

- `issues`: number (INTEGER, hub-assigned, unique, nullable until assigned), title, description (Markdown), status (one of inbox, todo, today, done, canceled, duplicate), priority (0 none, 1 urgent, 2 high, 3 medium, 4 low), dueDate (yyyy-MM-dd), cycleId, projectId, parentId, labels (JSON array of label ids), recur (JSON `{"every":"day|week|month","interval":N}` or null), sortOrder (REAL, within status), createdAt, startedAt, completedAt, canceledAt, archivedAt (ISO strings), linearId (original Linear id, for re-running the import).
- `labels`: name, color.
- `cycles`: number, startsAt, endsAt, title.
- `projects`: name, color, description, status.
- `views`: name, filter (JSON), grouping (list|board), sort.
- `meta`: lamport clock, device id, hub seq cursor, next issue number (hub).

Statuses stay a fixed enum in code (changing them is a code change, on purpose).

## Sync

Row-level last-writer-wins, per row, ordered by (ts, device). Device: write sets `dirty = 1`, bumps the Lamport clock. `sync` pushes dirty rows, then pulls rows with `seq > cursor`. Hub: accepts a row if its (ts, device) beats the stored one, then stamps `seq = ++head`; assigns `number` to an issue that lacks one. A device applying a pulled row keeps its own copy if its dirty copy is newer, but always takes a hub-assigned number. Deletes are tombstones (`deleted = 1`). HTTP: `POST /sync/pull?since=N`, `POST /sync/push`, bearer token per device, listening on 127.0.0.1, Tailscale in front.

The `ledger` CLI on the hub works on the hub database directly; rows it writes get their `seq` the next time anyone syncs.

## Operations (Core): one place, used by app, CLI and MCP

create / update / delete issue; set status (stamps completedAt, canceledAt, startedAt; completing a recurring issue creates the next occurrence, same labels and project, due date advanced); move to cycle; sub-issue; label, project and view CRUD; search (SQLite FTS5 over title and description); filters; cycle rollover (on sync and on app open: cycles exist for the current and next; an unfinished issue in an ended cycle moves to the current one). No CLI undo in v1.

## Import

`ledger import-linear` reads Linear (API key `LINEAR_API_KEY`, or a JSON dump file made through the Linear connector) and upserts by `linearId`, so it can be re-run until cutover. Keeps number, status, priority, labels, dueDate, cycle (with its number and dates), parent, created/started/completed/canceled/archived dates. Comments and attachments are not imported.

## App

Mac: sidebar (Inbox, Today, Cycle, Projects, Views, Labels), list and board, detail pane, ⌘K. iPhone: tabs, list, detail sheet, quick add. Shortcuts as Linear: C create, S status, P priority, L label, D due, A assignee not needed. Midnight Sun colors (deep navy surfaces, one sunshine-yellow accent; see `UI/Sources/LedgerUI/Theme.swift`).

## Claude

`mcp/ledger_mcp.py` wraps the CLI, so Claude can read and change issues the same way the CLI does.

## Ops

Hub on the server: launchd `com.nicholai.ledger-hub`, database `~/ledger-hub/ledger.sqlite`, tokens `~/ledger-hub/tokens.json` (mode 600), tailnet-only. Backup: nightly `sqlite3 .backup` to `~/ledger-hub/backups/`, keep 30.
