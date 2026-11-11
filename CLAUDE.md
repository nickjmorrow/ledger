# Ledger

A personal Linear-style task tracker; see `docs/design.md` (design) and `docs/hub.md` (running the sync hub). Swift packages `Core`, `CLI`, `UI`, an XcodeGen project in `App/`, and an MCP server in `mcp/`.

- Test: `swift test --package-path Core`, `swift test --package-path CLI`, `swift test --package-path UI`; MCP: `python3 -m unittest discover -s mcp` (needs the release CLI built).
- Machine-specific values (team id, hub URL and token) come from the gitignored `.env` via `scripts/generate-project.sh`; device ids and hosts live in the gitignored `CLAUDE.local.md`.
- This repo is public: tests, fixtures, sample data, docs and comments must be generic, with no personal data (real names, personal media or reading lists, calendars, health, money, machine names).
