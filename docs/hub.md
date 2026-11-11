# Running the sync hub

The hub is a Ledger database plus an HTTP front door. The Mac app, the iPhone app and the `ledger` CLI on each machine sync through it. The CLI and MCP server on the hub server work on the hub's database directly (`LEDGER_DEVICE=hub`), and their changes are numbered MOR-n straight away.

Changes carry a logical timestamp; per row (issue, label, project...) the newest write wins, the same way everywhere. The hub gives every issue its MOR number (highest number + 1), so two devices never clash.

What runs on the hub server:

| | |
| --- | --- |
| Source | `~/Projects/ledger` (a checkout of this repo) |
| CLI | `~/.local/bin/ledger` linked to `~/Projects/ledger/CLI/.build/release/ledger` |
| Database | `~/ledger-hub/ledger.sqlite` (device name `hub`) |
| Tokens | `~/ledger-hub/tokens.json`, mode 600: one per device, e.g. `mac`, `iphone` |
| Hub job | launchd `com.nicholai.ledger-hub`, `ledger sync-serve` on `127.0.0.1:8793`, log `~/Library/Logs/ledger-hub.log` |
| Tailnet | `tailscale serve --bg --http=8455 http://127.0.0.1:8793`: `http://<hub-host>:8455` (tailnet only, plain HTTP inside the tunnel, no Funnel) |
| Backup | launchd `com.nicholai.ledger-backup` at 03:15 runs `scripts/backup-hub.sh`: `~/ledger-hub/backups/ledger-YYYY-MM-DD.sqlite`, newest 30 kept; log `~/Library/Logs/ledger-backup.log` |

## Set it up

```bash
# build and link the CLI
swift build --package-path CLI -c release
mkdir -p ~/.local/bin && ln -sf "$PWD/CLI/.build/release/ledger" ~/.local/bin/ledger

# database (the first open names the device) and tokens, one per device
mkdir -p ~/ledger-hub ~/ledger-hub/backups
LEDGER_DEVICE=hub ledger summary --db ~/ledger-hub/ledger.sqlite > /dev/null
printf '{"%s": "mac", "%s": "iphone"}\n' "$(uuidgen)" "$(uuidgen)" > ~/ledger-hub/tokens.json
chmod 600 ~/ledger-hub/tokens.json

# jobs: copy scripts/*.plist to ~/Library/LaunchAgents/, replace CHANGEME with your user name, then
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.nicholai.ledger-hub.plist
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.nicholai.ledger-backup.plist

# tailnet-only front door. Check `tailscale serve status` first: serving a port that is already used replaces its target.
/Applications/Tailscale.app/Contents/MacOS/Tailscale serve --bg --http=8455 http://127.0.0.1:8793
```

The hub listens on 127.0.0.1 only; every request needs `Authorization: Bearer <token>`.

## Connect a device

- **CLI:** `ledger sync-setup --url http://<hub-host>:8455 --token <token>`, then `ledger sync`.
- Where Tailscale DNS is off on a device, use the hub's tailnet IP and pass the name as the Host header, because Tailscale's front door routes by name: `ledger sync-setup --url http://<hub-tailnet-ip>:8455 --token <token> --host-header <hub-host>:8455`.
- **Apps:** Settings → Sync, same address, token and optional Host header. The apps allow plain HTTP for this reason; the traffic is inside Tailscale's encrypted tunnel.

The setup is saved in `sync.json` beside the database (mode 600).

## Claude on the server

```bash
LEDGER_DB=~/ledger-hub/ledger.sqlite LEDGER_DEVICE=hub python3 mcp/ledger_mcp.py
```

## Import from Linear (once)

```bash
LEDGER_DEVICE=hub ledger import-linear --db ~/ledger-hub/ledger.sqlite --issues import/issues-*.json --cycles import/cycles.json
```

Re-running skips issues already imported (`--overwrite` replaces them).

## Restore

Stop the job (`launchctl bootout gui/$(id -u)/com.nicholai.ledger-hub`), copy a file from `~/ledger-hub/backups/` over `ledger.sqlite`, start the job again. Devices catch up on their next sync.
