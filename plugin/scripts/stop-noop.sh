#!/usr/bin/env bash
# U1 — wiring spike. Proves the Stop hook fires at all. No reconcile logic.
# Exit 0 with no JSON => allows the session to stop normally; we only log.
set -euo pipefail

DATA="${CLAUDE_PLUGIN_DATA:-$HOME/.research-graph-data}"
mkdir -p "$DATA"

# Drain stdin so the hook does not block on the JSON payload.
payload="$(cat || true)"

printf '%s  stop-hook fired  cwd=%s\n' "$(date -Is 2>/dev/null || date)" "${PWD}" >> "$DATA/wiring.log"
exit 0
