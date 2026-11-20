#!/bin/bash
# install.sh — symlink lease / lease-supabase / lease-heartbeat into a PATH dir.
#
#   ./install.sh                      symlinks only (idempotent)
#   ./install.sh --bin-dir DIR        choose the directory
#   ./install.sh --print-hook         print the Claude Code hooks JSON snippet
#   ./install.sh --settings FILE ...  ALSO merge the heartbeat hook into that
#                                     settings.json (backup + diff; idempotent).
#                                     Repeatable. Never done without this flag.
#   ./install.sh --uninstall [--settings FILE ...]
set -eu

REPO=$(cd "$(dirname "$0")" && pwd -P)
HOOK_CMD="$REPO/hooks/lease-heartbeat.sh"
BIN_DIR='' UNINSTALL=0 PRINT=0 FORCE=0 SETTINGS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --bin-dir) BIN_DIR=$2; shift 2;;
    --settings) SETTINGS+=("$2"); shift 2;;
    --print-hook) PRINT=1; shift;;
    --uninstall) UNINSTALL=1; shift;;
    --force) FORCE=1; shift;;
    -h|--help) sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *) echo "unknown option: $1" >&2; exit 1;;
  esac
done

hook_entry() {
  printf '{"matcher":"*","hooks":[{"type":"command","command":"%s","timeout":5}]}' "$HOOK_CMD"
}

if [ "$PRINT" = 1 ]; then
  cat <<EOF
{
  "hooks": {
    "PreToolUse":  [ $(hook_entry) ],
    "PostToolUse": [ $(hook_entry) ]
  }
}
EOF
  exit 0
fi

in_path() { case ":$PATH:" in *":$1:"*) return 0;; *) return 1;; esac; }

if [ -z "$BIN_DIR" ]; then
  for d in "$HOME/.local/bin" /opt/homebrew/bin /usr/local/bin; do
    if [ -d "$d" ] && [ -w "$d" ] && in_path "$d"; then BIN_DIR=$d; break; fi
  done
  if [ -z "$BIN_DIR" ]; then
    BIN_DIR="$HOME/.local/bin"
    echo "warning: no writable directory of \$PATH found; using $BIN_DIR — add it to PATH" >&2
  fi
fi
in_path "$BIN_DIR" || echo "warning: $BIN_DIR is not in this shell's PATH" >&2

link() { # src name
  local dst="$BIN_DIR/$2"
  if [ -e "$dst" ] && [ ! -L "$dst" ] && [ "$FORCE" = 0 ]; then
    echo "refusing to overwrite non-symlink $dst (use --force)" >&2; exit 1
  fi
  if [ "$(readlink "$dst" 2>/dev/null)" = "$1" ]; then echo "ok      $dst"; return; fi
  ln -sfn "$1" "$dst"; echo "linked  $dst -> $1"
}
unlink_ours() {
  local dst="$BIN_DIR/$1"
  case "$(readlink "$dst" 2>/dev/null)" in "$REPO"/*) rm -f "$dst"; echo "removed $dst";; esac
}

# Settings: remove our hook everywhere, then (unless uninstalling) add it to
# PreToolUse + PostToolUse. Leaves every other hook untouched.
patch_settings() {
  local f=$1 tmp
  command -v jq >/dev/null || { echo "jq is required to edit $f; add this by hand:" >&2; "$0" --print-hook; return 1; }
  [ -f "$f" ] || echo '{}' > "$f"
  tmp=$(mktemp)
  jq --arg cmd "$HOOK_CMD" --argjson add "$([ "$UNINSTALL" = 1 ] && echo false || echo true)" '
    def strip: map(.hooks |= map(select(.command != $cmd))) | map(select((.hooks | length) > 0));
    .hooks = (.hooks // {})
    | .hooks |= with_entries(.value |= strip)
    | if $add then
        reduce ("PreToolUse", "PostToolUse") as $e (.;
          .hooks[$e] = ((.hooks[$e] // []) + [{matcher: "*", hooks: [{type: "command", command: $cmd, timeout: 5}]}]))
      else . end
    | .hooks |= with_entries(select((.value | length) > 0))
  ' "$f" > "$tmp"
  if cmp -s "$f" "$tmp"; then echo "ok      $f (no change)"; rm -f "$tmp"; return; fi
  local bak; bak="$f.bak-lease-$(date +%Y%m%d%H%M%S)"
  cp -p "$f" "$bak"
  diff -u "$f" "$tmp" | sed 's/^/  /' || true
  cat "$tmp" > "$f"; rm -f "$tmp"
  echo "patched $f (backup: $bak)"
}

if [ "$UNINSTALL" = 1 ]; then
  for n in lease lease-supabase lease-heartbeat; do unlink_ours "$n"; done
else
  mkdir -p "$BIN_DIR" "${XDG_STATE_HOME:-$HOME/.local/state}/lease"
  chmod +x "$REPO/bin/lease" "$REPO/bin/lease-supabase" "$REPO/hooks/lease-heartbeat.sh"
  link "$REPO/bin/lease" lease
  link "$REPO/bin/lease-supabase" lease-supabase
  link "$REPO/hooks/lease-heartbeat.sh" lease-heartbeat
fi

for f in ${SETTINGS[@]+"${SETTINGS[@]}"}; do patch_settings "$f"; done

if [ "$UNINSTALL" = 0 ] && [ ${#SETTINGS[@]} -eq 0 ]; then
  echo
  echo "Hook not installed (settings untouched). To see it:  $0 --print-hook"
  echo "To install it:  $0 --settings <path/to/settings.json>"
fi
