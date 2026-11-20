#!/bin/bash
# Test suite for `lease` — plain bash (bats is not required).
#   tests/run.sh            run everything
#   tests/run.sh steal      run tests whose name matches "steal"
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
LEASE="$ROOT/bin/lease"
HOOK="$ROOT/hooks/lease-heartbeat.sh"
FILTER=${1-}

TMP=$(mktemp -d "${TMPDIR:-/tmp}/lease-tests.XXXXXX")
trap 'jobs -p | xargs kill 2>/dev/null; rm -rf "$TMP"' EXIT

# Hermetic environment: never inherit the real agent identity.
unset CLAUDE_PID ORCA_PANE_KEY ORCA_TERMINAL_HANDLE CLAUDE_CODE_SESSION_ID ORCA_WORKTREE_ID \
      LEASE_HOLDER LEASE_PID LEASE_LABEL LEASE_TTL LEASE_DB
export LEASE_AGENT_PROCS=__no_such_agent__

pass=0 fail=0 failed=()
CUR=''

ok()   { :; }
bad()  { echo "    ✗ $*"; CUR_FAILED=1; }
eq()   { [ "$1" = "$2" ] || bad "${3:-assert}: expected [$2] got [$1]"; }
has()  { case "$1" in *"$2"*) ;; *) bad "${3:-assert}: [$1] does not contain [$2]";; esac; }
rc()   { "$@" >/dev/null 2>&1; echo $?; }

# Run lease as holder $1 (with LEASE_PID=0 unless overridden) — prints stdout.
as() { local h=$1; shift; LEASE_HOLDER=$h LEASE_PID=${LEASE_PID:-0} LEASE_LABEL=$h "$LEASE" "$@"; }
q()  { sqlite3 -batch -noheader "$LEASE_DB" "$1"; }

run_test() {
  local name=$1
  [ -n "$FILTER" ] && case "$name" in *"$FILTER"*) ;; *) return;; esac
  export LEASE_DB="$TMP/$name.db"
  CUR_FAILED=0
  ( set +e; "test_$name" ) > "$TMP/$name.out" 2>&1
  local r=$?
  if [ $r -eq 0 ] && ! grep -q '✗' "$TMP/$name.out"; then
    pass=$((pass+1)); echo "ok   $name"
  else
    fail=$((fail+1)); failed+=("$name"); echo "FAIL $name"; sed 's/^/    /' "$TMP/$name.out"
  fi
}

# ------------------------------------------------------------------ tests ---

test_acquire_release() {
  local out tok slot
  out=$(as A acquire db); eq $? 0 "acquire rc"
  read -r tok slot <<<"$out"
  eq ${#tok} 24 "token length"; eq "$slot" 0 "slot"
  eq "$(q "SELECT holder FROM leases WHERE resource='db'")" A "row holder"
  out=$(as A release db "$tok"); eq $? 0 "release rc"; has "$out" "RELEASED db slot 0"
  eq "$(q "SELECT count(*) FROM leases")" 0 "no leases after release"
  # release without token uses the holder's own lease
  as A acquire db >/dev/null; eq "$(rc as A release db)" 0 "release w/o token"
}

test_busy() {
  as A acquire db >/dev/null
  local err; err=$(as B acquire db 2>&1 >/dev/null); local r=$?
  eq $r 2 "busy exit code"
  has "$err" "BUSY db"; has "$err" "slot 0: A"
}

test_idempotent_same_holder() {
  local t1 t2 e1 e2
  t1=$(as A acquire db --ttl 100s | cut -d' ' -f1)
  e1=$(q "SELECT expires_at FROM leases"); sleep 1
  t2=$(as A acquire db --ttl 100s | cut -d' ' -f1)
  e2=$(q "SELECT expires_at FROM leases")
  eq "$t2" "$t1" "same token"
  [ "$e2" -gt "$e1" ] || bad "expires_at not extended ($e1 -> $e2)"
  eq "$(q "SELECT count(*) FROM leases")" 1 "one row"
  has "$(as A log db)" "re-acquire (idempotent)"
}

test_ttl_expiry_and_steal() {
  local told tnew
  told=$(as A acquire db --ttl 1s | cut -d' ' -f1)
  eq "$(rc as B acquire db)" 2 "busy before expiry"
  sleep 2
  has "$(as A ls)" "expired" "ls shows expired"
  tnew=$(as B acquire db | cut -d' ' -f1); eq $? 0 "steal after ttl"
  [ "$tnew" != "$told" ] || bad "steal must mint a new token"
  local log; log=$(as B log db)
  has "$log" "steal"; has "$log" "from A (ttl)"
  # fencing: the old token is LOST everywhere
  eq "$(rc as A renew db "$told")" 3 "renew stale token -> LOST"
  eq "$(rc as A release db "$told")" 3 "release stale token -> LOST"
  eq "$(rc as A meta db "$told")" 3 "meta stale token -> LOST"
  has "$(as A renew db "$told" 2>&1)" "LOST"
  eq "$(q "SELECT holder FROM leases")" B "B still holds it"
}

test_dead_pid() {
  sleep 300 & local p=$!
  LEASE_PID=$p as A acquire db --ttl 1h >/dev/null
  eq "$(rc as B acquire db)" 2 "busy while owner alive"
  kill $p; wait $p 2>/dev/null
  has "$(as B ls)" "dead" "ls shows dead"
  eq "$(rc as B acquire db)" 0 "steal after owner died (ttl not expired)"
  has "$(as B log db)" "from A (pid)"
}

test_pid_reuse_guard() {
  sleep 300 & local p=$!
  LEASE_PID=$p as A acquire db --ttl 1h >/dev/null
  # simulate PID reuse: same pid, different process start time
  q "UPDATE leases SET pid_start='Thu Jan  1 00:00:00 1970'"
  eq "$(rc as B acquire db)" 0 "start-time mismatch counts as dead"
  kill $p
}

test_same_holder_reacquire_after_death() {
  # A restarted agent in the same pane (same holder) re-acquires its lease:
  # same token, owner pid updated.
  sleep 300 & local p1=$!
  local t1 t2
  t1=$(LEASE_PID=$p1 as A acquire db | cut -d' ' -f1)
  kill $p1; wait $p1 2>/dev/null
  sleep 300 & local p2=$!
  t2=$(LEASE_PID=$p2 as A acquire db | cut -d' ' -f1)
  eq "$t2" "$t1" "same token"
  eq "$(q "SELECT pid FROM leases")" "$p2" "pid updated"
  kill $p2
}

test_renew() {
  local tok; tok=$(as A acquire db --ttl 10s | cut -d' ' -f1)
  local out; out=$(as A renew db "$tok" --ttl 1h); eq $? 0 "renew rc"; has "$out" "OK db slot 0"
  eq "$(q "SELECT ttl FROM leases")" 3600 "ttl updated"
  eq "$(rc as A renew db nonsense)" 3 "bogus token LOST"
  eq "$(rc as B renew db)" 3 "renew without lease LOST"
}

test_capacity_slots() {
  as A capacity db 3 >/dev/null
  eq "$(as A capacity db)" 3 "capacity read"
  eq "$(as A acquire db | cut -d' ' -f2)" 0 "A slot 0"
  eq "$(as B acquire db | cut -d' ' -f2)" 1 "B slot 1"
  eq "$(as C acquire db | cut -d' ' -f2)" 2 "C slot 2"
  eq "$(rc as D acquire db)" 2 "D busy"
  as B release db >/dev/null
  eq "$(as D acquire db | cut -d' ' -f2)" 1 "D gets lowest free slot (1)"
  # shrink capacity: held slots >= N survive, but no new slot >= N is handed out
  local err; err=$(as A capacity db 1 2>&1); has "$err" "slots 1,2 are >= new capacity"
  as A release db >/dev/null
  eq "$(as E acquire db | cut -d' ' -f2)" 0 "E gets slot 0"
  eq "$(rc as F acquire db)" 2 "F busy (capacity 1)"
  has "$(as A ls db)" "held*" "over-capacity slot flagged"
}

test_concurrency_capacity_1() { concurrency 1 20; }
test_concurrency_capacity_3() { concurrency 3 24; }
concurrency() {
  local cap=$1 n=$2 i
  as X capacity db "$cap" >/dev/null
  mkdir -p "$TMP/race$cap"
  for i in $(seq 1 "$n"); do
    ( out=$(as "P$i" acquire db 2>/dev/null); echo "$? $out" > "$TMP/race$cap/$i" ) &
  done
  wait
  local wins slots
  wins=$(cat "$TMP/race$cap"/* | awk '$1==0' | wc -l | tr -d ' ')
  eq "$wins" "$cap" "exactly capacity winners"
  eq "$(cat "$TMP/race$cap"/* | awk '$1==2' | wc -l | tr -d ' ')" $((n - cap)) "the rest busy (exit 2)"
  slots=$(cat "$TMP/race$cap"/* | awk '$1==0{print $3}' | sort -n | paste -sd, -)
  eq "$slots" "$(seq 0 $((cap-1)) | paste -sd, -)" "distinct slots 0..N-1"
  eq "$(q "SELECT count(*) FROM leases")" "$cap" "rows in db"
}

test_concurrency_mixed_ops() {
  # acquire/renew/release storm on capacity 2: invariants must hold throughout
  as X capacity db 2 >/dev/null
  local i
  for i in $(seq 1 12); do
    ( for k in 1 2 3; do
        if as "W$i" acquire db --ttl 30s >/dev/null 2>&1; then
          as "W$i" renew db >/dev/null 2>&1; as "W$i" release db >/dev/null 2>&1
        fi
      done ) &
  done
  wait
  eq "$(q "SELECT count(*) FROM leases")" 0 "all released"
  eq "$(q "SELECT count(*) FROM log WHERE action='acquire'")" \
     "$(q "SELECT count(*) FROM log WHERE action='release'")" "acquires == releases"
  # never more than 2 holders at once: replay the log
  local maxheld
  maxheld=$(q "SELECT action FROM log WHERE action IN ('acquire','release') ORDER BY id" |
    awk '/acquire/{c++; if(c>m)m=c} /release/{c--} END{print m}')
  [ "$maxheld" -le 2 ] || bad "more than capacity held at once: $maxheld"
}

test_wait() {
  as A acquire db --ttl 2s >/dev/null
  local t0 out; t0=$(date +%s)
  out=$(as B wait db --timeout 15s --interval 1s 2>/dev/null); eq $? 0 "wait succeeds after expiry"
  [ $(( $(date +%s) - t0 )) -ge 1 ] || bad "wait returned too early"
  eq "$(q "SELECT holder FROM leases")" B "B holds it"
  eq "$(rc as C wait db --timeout 2s --interval 1s)" 4 "timeout exit 4"
}

test_hold_pid() {
  as A acquire db --ttl 2s >/dev/null
  sleep 300 & local p=$!
  LEASE_HOLDER=A LEASE_PID=0 "$LEASE" hold db --pid $p --interval 1s & local h=$!
  sleep 4
  eq "$(rc as B acquire db)" 2 "still held thanks to hold (ttl 2s, 4s elapsed)"
  kill $p; wait $p 2>/dev/null
  wait $h; eq $? 0 "hold exits 0 when pid dies"
  sleep 3
  eq "$(rc as B acquire db)" 0 "expires after hold stops"
}

test_hold_cmd_and_lost() {
  as A acquire db --ttl 2s >/dev/null
  LEASE_HOLDER=A LEASE_PID=0 "$LEASE" hold db --interval 1s -- sh -c 'sleep 3; exit 7'
  eq $? 7 "hold -- cmd propagates exit code"
  # LOST while holding: the command is killed, exit 3
  LEASE_HOLDER=A LEASE_PID=0 "$LEASE" hold db --interval 1s -- sleep 30 & local h=$!
  sleep 1
  q "DELETE FROM leases"   # simulate a steal
  wait $h; eq $? 3 "hold exits 3 on LOST"
}

test_renew_mine() {
  sleep 300 & local me=$!
  sleep 300 & local other=$!
  as Z capacity r2 2 >/dev/null
  LEASE_PID=$me as A acquire r1 --ttl 3s >/dev/null
  LEASE_PID=$me as A acquire r2 --ttl 3s >/dev/null
  LEASE_PID=$other as B acquire r2 --ttl 3s >/dev/null
  # a stale lease from a *previous* agent in the same pane (same holder, other pid)
  q "INSERT INTO leases(resource,slot,holder,token,pid,ttl,acquired_at,renewed_at,expires_at) VALUES ('r3',0,'A','oldtok',$other,3,0,0,$(( $(date +%s) + 3 )))"
  local before; before=$(q "SELECT expires_at FROM leases WHERE resource='r1'")
  sleep 1.5
  LEASE_HOLDER=A LEASE_PID=$me "$LEASE" renew-mine; eq $? 0 "renew-mine rc"
  [ "$(q "SELECT expires_at FROM leases WHERE resource='r1'")" -gt "$before" ] || bad "r1 not renewed"
  eq "$(q "SELECT expires_at - renewed_at FROM leases WHERE resource='r2' AND holder='A'")" 3 "r2 renewed with its ttl"
  eq "$(q "SELECT renewed_at FROM leases WHERE resource='r3'")" 0 "other agent's lease (same holder, other pid) untouched"
  eq "$(q "SELECT renewed_at > acquired_at FROM leases WHERE resource='r2' AND holder='B'")" 0 "other holder untouched"
  # no DB at all: silent success
  LEASE_DB="$TMP/none/x.db" LEASE_HOLDER=A "$LEASE" renew-mine; eq $? 0 "no db -> 0"
  kill $me $other
}

test_lost_notice_via_hook() {
  sleep 300 & local me=$!
  LEASE_PID=$me as A acquire db --ttl 1s >/dev/null
  sleep 2
  as B acquire db >/dev/null   # steals from A
  local out
  out=$(echo '{"hook_event_name":"PostToolUse"}' | LEASE_HOLDER=A LEASE_PID=$me "$HOOK"); eq $? 0 "hook rc 0"
  has "$out" '"hookEventName":"PostToolUse"'
  has "$out" '"additionalContext":"lease: you LOST'
  has "$out" "db slot 0"
  [ "$(sqlite3 :memory: "SELECT json_valid('$(printf '%s' "$out" | sed "s/'/''/g")')")" = 1 ] || bad "hook output is not valid JSON"
  # delivered once
  out=$(echo '{}' | LEASE_HOLDER=A LEASE_PID=$me "$HOOK"); eq "$out" "" "notice delivered only once"
  # the event name follows the payload
  LEASE_PID=$me as A acquire x --ttl 1s >/dev/null; sleep 2; as B acquire x >/dev/null
  out=$(echo '{"hook_event_name": "PreToolUse"}' | LEASE_HOLDER=A LEASE_PID=$me "$HOOK")
  has "$out" '"hookEventName":"PreToolUse"'
  kill $me
}

test_hook_never_fails() {
  local out
  out=$(echo '{}' | LEASE_DB=/nonexistent/dir/x.db "$HOOK"); eq $? 0 "missing db"
  eq "$out" "" "silent"
  echo garbage > "$LEASE_DB"
  out=$(echo '{}' | LEASE_HOLDER=A "$HOOK" 2>&1); eq $? 0 "corrupt db"
  eq "$out" "" "silent on corrupt db"
  out=$(LEASE_BIN=/nonexistent "$HOOK" </dev/null); eq $? 0 "missing binary"
}

test_meta_and_slot_meta() {
  as A capacity db 2 >/dev/null
  as A acquire db --meta '{"repo":"r","n":1}' >/dev/null
  eq "$(as A meta db --set '{"n":2,"x":true}')" '{"repo":"r","n":2,"x":true}' "lease meta merge"
  eq "$(rc as A meta db --set 'not json')" 1 "invalid json rejected"
  eq "$(rc as A acquire y --meta '{bad')" 1 "invalid --meta rejected"
  eq "$(as A slot-meta db 0 --set '{"project_id":"p0"}')" '{"project_id":"p0"}' "slot-meta set"
  eq "$(rc as B slot-meta db 0 --set '{"project_id":"evil"}')" 3 "cannot set meta on a slot you don't hold"
  eq "$(rc as A slot-meta db 1 --set '{}')" 3 "nor on a free slot"
  as A release db >/dev/null
  eq "$(as B slot-meta db 0)" '{"project_id":"p0"}' "slot meta survives release"
  eq "$(as B slot-meta db 1)" '{}' "empty slot meta"
  has "$(as B ls db)" '(last: {"project_id":"p0"})' "ls shows last slot meta"
}

test_ls_json() {
  as A capacity db 2 >/dev/null
  as A acquire db --meta '{"k":"v"}' >/dev/null
  local j; j=$(as A ls --json)
  eq "$(sqlite3 :memory: "SELECT json_valid('$j')")" 1 "valid json"
  eq "$(sqlite3 :memory: "SELECT json_array_length('$j')")" 2 "two slots"
  eq "$(sqlite3 :memory: "SELECT json_extract('$j','\$[0].state') || json_extract('$j','\$[1].state')")" "heldfree" "states"
  eq "$(sqlite3 :memory: "SELECT json_array_length('$(as A ls --mine --json)')")" 1 "--mine"
  eq "$(LEASE_DB="$TMP/empty.db" "$LEASE" ls --json)" "[]" "no db -> []"
}

test_holder_inference() {
  local w
  w=$(ORCA_PANE_KEY=tab:pane CLAUDE_CODE_SESSION_ID=s "$LEASE" whoami | head -1)
  has "$w" "orca:tab:pane"; has "$w" "ORCA_PANE_KEY"
  w=$(ORCA_TERMINAL_HANDLE=term_1 "$LEASE" whoami | head -1); has "$w" "orca:term_1"
  w=$(CLAUDE_CODE_SESSION_ID=s1 "$LEASE" whoami | head -1); has "$w" "claude:s1"
  w=$(LEASE_HOLDER=me ORCA_PANE_KEY=x "$LEASE" whoami | head -1); has "$w" "me	(from LEASE_HOLDER)"
  w=$("$LEASE" whoami | head -1); has "$w" "pid:"
}

test_owner_pid_inference() {
  local w
  w=$(LEASE_PID=0 "$LEASE" whoami | sed -n 2p); has "$w" "0	(from LEASE_PID)"
  sleep 300 & local p=$!
  w=$(CLAUDE_PID=$p "$LEASE" whoami | sed -n 2p); has "$w" "$p	(from CLAUDE_PID)"
  kill $p; wait $p 2>/dev/null
  w=$(CLAUDE_PID=$p "$LEASE" whoami | sed -n 2p); has "$w" "(from PPID)" "dead CLAUDE_PID ignored"
  # ancestor walk: run through a process literally named "fakeagent"
  ln -s /bin/bash "$TMP/fakeagent"
  w=$(LEASE_AGENT_PROCS=fakeagent "$TMP/fakeagent" -c "'$LEASE' whoami | sed -n 2p; true")
  has "$w" "(from ancestor)"
}

test_usage_errors() {
  eq "$(rc "$LEASE")" 1 "no args"
  eq "$(rc "$LEASE" bogus)" 1 "unknown cmd"
  eq "$(rc as A acquire)" 1 "missing resource"
  eq "$(rc as A acquire 'bad name')" 1 "bad resource name"
  eq "$(rc as A acquire db --ttl 5x)" 1 "bad ttl"
  eq "$(rc as A capacity db 0)" 1 "capacity 0"
  eq "$(rc as A token db)" 3 "token without lease"
  as A acquire db >/dev/null; eq "$(as A token db | cut -d' ' -f2)" 0 "token prints slot"
  has "$(as A acquire "it's" 2>&1)" "invalid resource name"
}

# ------------------------------------------------------------------- main ---
for t in $(declare -F | awk '{print $3}' | grep '^test_' | sed 's/^test_//'); do
  run_test "$t"
done
echo
echo "$pass passed, $fail failed"
[ $fail -eq 0 ] || { echo "failed: ${failed[*]}"; exit 1; }
