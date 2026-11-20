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
# Contract: fast (~30 ms), silent otherwise, ALWAYS exits 0. Avoids forks on
# the hot path.

# Read (and so drain) the hook payload; we only need hook_event_name.
payload=$(cat 2>/dev/null) || payload=''
case "$payload" in
  *'"hook_event_name":"PreToolUse"'*|*'"hook_event_name": "PreToolUse"'*) LEASE_HOOK_EVENT=PreToolUse ;;
  *) LEASE_HOOK_EVENT=PostToolUse ;;
esac
export LEASE_HOOK_EVENT

if [ -z "${LEASE_BIN:-}" ]; then
  case "$0" in
    */hooks/lease-heartbeat.sh) LEASE_BIN=${0%/hooks/lease-heartbeat.sh}/bin/lease ;;
    *) # invoked through a symlink (e.g. ~/.local/bin/lease-heartbeat)
      self=$0
      while [ -L "$self" ]; do
        link=$(readlink "$self")
        case "$link" in /*) self=$link ;; *) self=${self%/*}/$link ;; esac
      done
      LEASE_BIN=${self%/hooks/*}/bin/lease ;;
  esac
  [ -x "$LEASE_BIN" ] || LEASE_BIN=$(command -v lease 2>/dev/null)
fi
[ -n "$LEASE_BIN" ] && [ -x "$LEASE_BIN" ] || exit 0

# Owner PID: CLAUDE_PID if exported, else `lease` walks up the process tree
# to the nearest `claude` process (this hook is its descendant).
"$LEASE_BIN" renew-mine --hook 2>/dev/null || :
exit 0
