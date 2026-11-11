# ledger-mcp

MCP server for Claude (stdio). Wraps the `ledger` CLI, so every tool behaves exactly like the command line. Tools: `ledger_issues`, `ledger_issue`, `ledger_create_issue`, `ledger_edit_issue` (also sets status), `ledger_delete_issue`, `ledger_labels`, `ledger_projects`, `ledger_cycles`, `ledger_summary`.

Needs `ledger` on PATH or at `~/.local/bin/ledger`: `swift build --package-path CLI -c release`, then link `CLI/.build/release/ledger` to `~/.local/bin/ledger` (or set `LEDGER_BIN`). The database defaults to `~/Library/Application Support/Ledger/ledger.sqlite`, the same file the Mac app opens (override with `LEDGER_DB`). Before and after each call it runs `ledger sync` when sync is set up (`LEDGER_AUTOSYNC=0` turns that off).

Register it:

- On a device: `claude mcp add ledger -- python3 <repo>/mcp/ledger_mcp.py` (after `ledger sync-setup`, so it syncs).
- On the hub server, straight on the hub database: `claude mcp add ledger -e LEDGER_DB=$HOME/ledger-hub/ledger.sqlite -e LEDGER_DEVICE=hub -- python3 <repo>/mcp/ledger_mcp.py`, or run `LEDGER_DB=~/ledger-hub/ledger.sqlite LEDGER_DEVICE=hub python3 mcp/ledger_mcp.py` from a connector. Writes on the hub are numbered (MOR-n) immediately.

Tests (need the release CLI built): `python3 -m unittest discover -s mcp`
