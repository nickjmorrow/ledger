#!/bin/bash
# Nightly copy of the hub database (a consistent snapshot, safe while the hub runs). Keeps the newest 30.
set -euo pipefail
hub="$HOME/ledger-hub"
dir="$hub/backups"
mkdir -p "$dir"
/usr/bin/sqlite3 "$hub/ledger.sqlite" ".timeout 10000" ".backup '$dir/ledger-$(date +%F).sqlite'"
ls -1t "$dir"/ledger-*.sqlite | tail -n +31 | while read -r old; do rm -- "$old"; done
echo "$(date '+%F %T') backed up to $dir/ledger-$(date +%F).sqlite"
