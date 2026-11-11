#!/bin/sh
# Generates App/Ledger.xcodeproj, injecting machine-specific values from .env (see .env.example).
set -e
root="$(cd "$(dirname "$0")/.." && pwd)"
if [ -f "$root/.env" ]; then set -a; . "$root/.env"; set +a; fi
export DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-}" LEDGER_HUB_URL="${LEDGER_HUB_URL:-}" LEDGER_HUB_TOKEN="${LEDGER_HUB_TOKEN:-}" LEDGER_HUB_HOST="${LEDGER_HUB_HOST:-}"
cd "$root/App"
xcodegen generate "$@"
