#!/bin/sh
# Claude Code hook (PreToolUse / PostToolUse): heartbeat for `lease`.
#
# Renews every lease held by this agent (same holder id AND same agent PID),
# so an active agent keeps its leases alive without remembering to, and an
# idle / dead agent lets them expire.
#
# If one of this agent's leases was reaped and taken by someone else, it
# prints hook JSON with `additionalContext` so the model is told it LOST it.
#
# Contract: fast (~10-30 ms), silent otherwise, ALWAYS exits 0.

# Read (and so drain) the hook payload; we only need hook_event_name.
payload=$(cat 2>/dev/null) || payload=''
LEASE_HOOK_EVENT=$(printf '%s' "$payload" | sed -n 's/.*"hook_event_name" *: *"\([A-Za-z]*\)".*/\1/p' | head -n 1)
LEASE_HOOK_EVENT=${LEASE_HOOK_EVENT:-PostToolUse}
export LEASE_HOOK_EVENT

LEASE_BIN=${LEASE_BIN:-}
if [ -z "$LEASE_BIN" ]; then
  # Resolve bin/lease next to this script (works through the install symlink).
  self=$0
  while [ -L "$self" ]; do
    link=$(readlink "$self")
    case "$link" in /*) self=$link ;; *) self=$(dirname "$self")/$link ;; esac
  done
  LEASE_BIN=$(cd "$(dirname "$self")/.." 2>/dev/null && pwd)/bin/lease
  [ -x "$LEASE_BIN" ] || LEASE_BIN=$(command -v lease 2>/dev/null)
fi
[ -n "$LEASE_BIN" ] && [ -x "$LEASE_BIN" ] || exit 0

# Owner PID: CLAUDE_PID if exported, else `lease` walks up the process tree
# to the nearest `claude` process (this hook is its descendant).
"$LEASE_BIN" renew-mine --hook 2>/dev/null || :
exit 0
