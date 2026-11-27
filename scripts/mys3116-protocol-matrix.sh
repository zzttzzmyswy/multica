#!/usr/bin/env bash
# HTTP-contract checks for a fork sync's daemon API.
#
# SCOPE — read this before citing any number below.
#
# This script drives the daemon HTTP API with curl and inspects the server's
# tables. It therefore proves things about the SERVER's contract: which status a
# route returns, how a registration is keyed, that a terminal report is
# idempotent, that a limiter triggers and recovers. It does NOT prove that a
# daemon BINARY performs those calls — no daemon process here claims a task, backs
# off on a retry, or produces a terminal side effect on its own. Registration is
# the one lifecycle step a real binary performs, because `daemon start` does it.
#
# Evidence about the two daemon binaries (claim, backoff, single terminal effect)
# is delivered by the separate sub-issue MYS-3119, which owns that executor. The
# operating card cites that issue for those rows rather than this script. An
# earlier version of this script claimed those rows as "measured" while driving
# them with curl; that was wrong and is what this rewrite removes.
#
# What it CAN honestly measure, and does:
#   * registration by the real binaries (both versions), and heartbeat advance
#   * the register/heartbeat/claim/complete/fail HTTP contract, status + effect
#   * idempotency of a replayed terminal report, counted per task
#   * concurrent registration with distinct identities, and duplicate identity
#   * the invitation limiter's trigger and recovery
#   * invalid credentials
#
# Process handling: daemons are started with setsid and their PIDs recorded in a
# FILE, because this script's callers run parts of it inside command
# substitution and a subshell cannot mutate a parent's array. Cleanup kills only
# the PIDs this run recorded, never by executable name.
#
# Usage:
#   ADMIN_DSN=<isolated superuser dsn> \
#   bash scripts/mys3116-protocol-matrix.sh \
#     --server <server binary> --daemon-old <old multica> --daemon-new <new multica> \
#     [--label-old v0.11.1-myswy.1] [--label-new v0.13.0-myswy.1]
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SERVER_BIN=""
DAEMON_OLD=""
DAEMON_NEW=""
LABEL_OLD="previous release"
LABEL_NEW="candidate"
ADMIN_DSN="${ADMIN_DSN:?set ADMIN_DSN to an isolated superuser DSN}"
OUT_DIR="${OUT_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/protocol-matrix.XXXXXX")}"
RUN_ID="$(date +%s)-$$"
DB_NAME="protocol_matrix_${RUN_ID//-/_}"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --server) SERVER_BIN=$2; shift 2 ;;
    --daemon-old) DAEMON_OLD=$2; shift 2 ;;
    --daemon-new) DAEMON_NEW=$2; shift 2 ;;
    --label-old) LABEL_OLD=$2; shift 2 ;;
    --label-new) LABEL_NEW=$2; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
for pair in "server:$SERVER_BIN" "daemon-old:$DAEMON_OLD" "daemon-new:$DAEMON_NEW"; do
  name=${pair%%:*}; path=${pair#*:}
  [ -n "$path" ] && [ -x "$path" ] || { echo "--$name must be an executable, got '$path'" >&2; exit 2; }
done

mkdir -p "$OUT_DIR"
LOG="$OUT_DIR/matrix.log"
: >"$LOG"
PID_FILE="$OUT_DIR/pids"
: >"$PID_FILE"
PASS_FILE="$OUT_DIR/pass.count"; : >"$PASS_FILE"
FAIL_FILE="$OUT_DIR/fail.count"; : >"$FAIL_FILE"
FAIL_LIST="$OUT_DIR/failures"; : >"$FAIL_LIST"

# Counters are files, not shell variables: parts of this script run inside
# command substitution, and a subshell cannot update a parent's variables. An
# assertion that runs in a subshell would otherwise be silently discarded — the
# exact "pass counted in a subshell" bug that made an earlier version report
# success for work it had not done.
bump() { printf x >>"$1"; }
pass_count() { wc -c <"$PASS_FILE" | tr -d ' '; }
fail_count() { wc -c <"$FAIL_FILE" | tr -d ' '; }

ok()   { bump "$PASS_FILE"; printf '    \033[32m✓\033[0m %s\n' "$1"; printf 'PASS %s\n' "$1" >>"$LOG"; }
bad()  { bump "$FAIL_FILE"; printf '%s\n' "$1" >>"$FAIL_LIST"; printf '    \033[31m✗\033[0m %s\n' "$1"; printf 'FAIL %s\n' "$1" >>"$LOG"; }
step() { printf '\n==> %s\n' "$1"; printf '\n==> %s\n' "$1" >>"$LOG"; }
note() { printf '    %s\n' "$1"; printf '%s\n' "$1" >>"$LOG"; }

psql_admin() { psql "$ADMIN_DSN" -v ON_ERROR_STOP=1 -tAqc "$1"; }
dsn_for() { printf '%s' "${ADMIN_DSN%/*}/$1"; }
# NOTICE output goes to stderr so a captured value is the row, not a notice + row.
db() { psql "$(dsn_for "$DB_NAME")" -tAqc "$1" 2>>"$LOG"; }

SERVER_PID=""
cleanup() {
  # The last command in an EXIT trap sets the script's exit status, so this
  # function must preserve it explicitly. Without the capture below, a run that
  # called `exit 1` still exited 0 because the final `note` succeeded — a failure
  # that reports success at the process level, which is the worst kind.
  local status=$?
  # Kill only PIDs this run recorded, and only if they are still ours. Never by
  # executable name: `pkill multica` would take down the workspace daemon.
  if [ -s "$PID_FILE" ]; then
    while read -r pid; do
      [ -n "$pid" ] || continue
      kill "$pid" 2>/dev/null || true
    done <"$PID_FILE"
  fi
  [ -n "$SERVER_PID" ] && { kill "$SERVER_PID" 2>/dev/null; wait "$SERVER_PID" 2>/dev/null; }
  psql_admin "DROP DATABASE IF EXISTS \"$DB_NAME\"" >/dev/null 2>&1
  note "artifacts: $OUT_DIR"
  return "$status"
}
trap cleanup EXIT

API_PORT="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')"
BASE_URL="http://127.0.0.1:$API_PORT"

step "Isolated database"
psql_admin "CREATE DATABASE \"$DB_NAME\"" >/dev/null || { echo "could not create $DB_NAME" >&2; exit 1; }
psql "$(dsn_for "$DB_NAME")" -q -v ON_ERROR_STOP=1 \
  -c "CREATE EXTENSION IF NOT EXISTS vector; CREATE EXTENSION IF NOT EXISTS pg_trgm; CREATE EXTENSION IF NOT EXISTS pgcrypto;" \
  >>"$LOG" 2>&1 || { echo "could not create extensions" >&2; exit 1; }
( cd "$ROOT_DIR/server" && DATABASE_URL="$(dsn_for "$DB_NAME")" go run ./cmd/migrate up ) >>"$LOG" 2>&1 \
  || { echo "migrations failed (see $LOG)" >&2; exit 1; }
ok "created $DB_NAME and applied the candidate migration tree"

step "Seed account, workspace and token"
TOKEN="mul_$(python3 -c 'import secrets;print(secrets.token_hex(24))')"
TOKEN_HASH="$(python3 -c "import hashlib,sys;print(hashlib.sha256(sys.argv[1].encode()).hexdigest())" "$TOKEN")"
USER_ID="$(db "INSERT INTO \"user\" (name,email) VALUES ('Matrix','matrix-$RUN_ID@multica.test') RETURNING id" | tail -1)"
WS_ID="$(db "INSERT INTO workspace (name,slug,issue_prefix) VALUES ('Matrix WS','matrix-$RUN_ID','MTX') RETURNING id" | tail -1)"
db "INSERT INTO member (workspace_id,user_id,role) VALUES ('$WS_ID','$USER_ID','owner')" >/dev/null
db "INSERT INTO personal_access_token (user_id,name,token_hash,token_prefix) VALUES ('$USER_ID','matrix','$TOKEN_HASH','mul_')" >/dev/null
ok "seeded user, workspace, token"

start_server() {
  local logfile=$1
  env APP_ENV=development DATABASE_URL="$(dsn_for "$DB_NAME")" \
    JWT_SECRET="protocol-matrix-secret-0123456789abcdef0123456789abcdef" \
    PORT="$API_PORT" FRONTEND_ORIGIN="$BASE_URL" MULTICA_APP_URL="$BASE_URL" MULTICA_PUBLIC_URL="$BASE_URL" \
    RATE_LIMIT_INVITATION_ACTOR_10M="${INVITE_LIMIT:-10}" \
    FF_DOCS_V1=true "$SERVER_BIN" >>"$logfile" 2>&1 &
  SERVER_PID=$!
  local i
  for i in $(seq 1 60); do
    curl -fsS "$BASE_URL/health" >/dev/null 2>&1 && return 0
    kill -0 "$SERVER_PID" 2>/dev/null || return 1
    sleep 1
  done
  return 1
}

step "Candidate server"
start_server "$OUT_DIR/server.log" || { echo "server never became healthy" >&2; exit 1; }
ok "candidate server healthy at $BASE_URL"

api() { # api METHOD PATH [BODY] -> "status<TAB>body"
  local method=$1 path=$2 body=${3:-}
  if [ -n "$body" ]; then
    curl -s -o "$OUT_DIR/.body" -w '%{http_code}' -X "$method" "$BASE_URL$path" \
      -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d "$body"
  else
    curl -s -o "$OUT_DIR/.body" -w '%{http_code}' -X "$method" "$BASE_URL$path" \
      -H "Authorization: Bearer $TOKEN"
  fi
  printf '\t%s' "$(cat "$OUT_DIR/.body")"
}

# start_daemon LABEL BINARY DAEMON_ID: run the real binary so IT performs
# registration and heartbeats. Prints "label<TAB>runtime_id" on success so the
# caller can use the id the SERVER recorded. Daemon PIDs go to $PID_FILE, which
# survives the command substitution this is called from.
start_daemon() {
  local label=$1 binary=$2 daemon_id=$3
  local state="$OUT_DIR/state-$label"
  mkdir -p "$state" "$OUT_DIR/neutral"
  local -a clean=(-u MULTICA_TASK_ID -u MULTICA_TASK_SLOT -u MULTICA_TASK_WORKSPACES_ROOT
                 -u MULTICA_TASK_CONFIG_ROOT -u MULTICA_AGENT_ID -u MULTICA_DAEMON_PORT)

  # login and daemon start both refuse to run inside a daemon-managed task (they
  # look for a marker in the CWD), so the child runs from a neutral directory
  # with the task identity cleared — an ordinary shell on the machine.
  ( cd "$OUT_DIR/neutral" && env "${clean[@]}" HOME="$state" MULTICA_SERVER_URL="$BASE_URL" \
      MULTICA_TOKEN="$TOKEN" "$binary" --profile "$daemon_id" login --token "$TOKEN" ) >>"$LOG" 2>&1 \
    || { echo "LOGIN_FAILED"; return 1; }

  ( cd "$OUT_DIR/neutral" && exec setsid env "${clean[@]}" HOME="$state" MULTICA_SERVER_URL="$BASE_URL" \
      MULTICA_TOKEN="$TOKEN" MULTICA_DAEMON_AUTO_UPDATE=false \
      MULTICA_WORKSPACES_ROOT="$state/workspaces" \
      "$binary" --profile "$daemon_id" daemon start --foreground --daemon-id "$daemon_id" \
        --device-name "matrix-$label" --no-auto-update --heartbeat-interval 2s \
        >>"$OUT_DIR/daemon-$label.log" 2>&1 ) &
  local pid=$!
  printf '%s\n' "$pid" >>"$PID_FILE"

  local n=""
  local _i
  for _i in $(seq 1 40); do
    n="$(db "SELECT count(*) FROM agent_runtime WHERE daemon_id='$daemon_id'")"
    [ "${n:-0}" -ge 1 ] && break
    sleep 1
  done
  [ "${n:-0}" -ge 1 ] || { echo "REGISTER_FAILED"; return 1; }
  local runtime
  runtime="$(db "SELECT id FROM agent_runtime WHERE daemon_id='$daemon_id' ORDER BY id LIMIT 1" | tail -1)"
  printf '%s\t%s\n' "$label" "$runtime"
}

random_suffix() { printf '%s' "$(python3 -c 'import secrets;print(secrets.token_hex(4))')"; }

step "Version identity"
OLD_V="$("$DAEMON_OLD" version 2>/dev/null | head -1)"
NEW_V="$("$DAEMON_NEW" version 2>/dev/null | head -1)"
note "$LABEL_OLD binary: $OLD_V"
note "$LABEL_NEW binary: $NEW_V"
case "$OLD_V" in *"$LABEL_OLD"*) ok "old binary reports $LABEL_OLD";; *) bad "old binary reports '$OLD_V', expected $LABEL_OLD";; esac
case "$NEW_V" in *"$LABEL_NEW"*) ok "new binary reports $LABEL_NEW";; *) bad "new binary reports '$NEW_V', expected $LABEL_NEW";; esac

step "Real daemon binaries: registration and heartbeat advance"
# The only lifecycle steps a real binary performs are these two, so they are the
# only ones this script attributes to it.
for pair in "old:$DAEMON_OLD:$LABEL_OLD" "new:$DAEMON_NEW:$LABEL_NEW"; do
  key=${pair%%:*}; rest=${pair#*:}; binary=${rest%%:*}; label=${rest#*:}
  daemon_id="matrix-$key-$RUN_ID"
  result="$(start_daemon "$key" "$binary" "$daemon_id")"
  case "$result" in
    LOGIN_FAILED) bad "$label: the binary's own login failed"; continue ;;
    REGISTER_FAILED) bad "$label: the binary never registered"; continue ;;
  esac
  ok "$label: the real binary registered (daemon_id $daemon_id)"

  # Runtime rows are one per provider the binary found, so the count is a property
  # of the machine, not a fixed 1; no duplicates is the actual invariant.
  runtimes="$(db "SELECT count(*) FROM agent_runtime WHERE daemon_id='$daemon_id'")"
  providers="$(db "SELECT count(DISTINCT provider) FROM agent_runtime WHERE daemon_id='$daemon_id'")"
  if [ "$runtimes" = "$providers" ] && [ "${runtimes:-0}" -ge 1 ]; then
    ok "$label: $runtimes runtime(s), one per provider, no duplicates"
  else
    bad "$label: $runtimes runtime rows but $providers distinct providers"
  fi

  # Heartbeat advance. The steady-state bump is coalesced by a 30s batch
  # scheduler, so a shorter wait measures nothing — the earlier version's missing
  # assertion is why this one waits past a full tick.
  before="$(db "SELECT coalesce(max(last_seen_at)::text,'') FROM agent_runtime WHERE daemon_id='$daemon_id'")"
  sleep 40
  after="$(db "SELECT coalesce(max(last_seen_at)::text,'') FROM agent_runtime WHERE daemon_id='$daemon_id'")"
  if [ -n "$after" ] && [ "$after" != "$before" ]; then
    ok "$label: heartbeat advanced last_seen_at within 40s"
  else
    bad "$label: heartbeat did not advance last_seen_at ($before -> $after)"
  fi
done

# ------------------------------------------------------- HTTP contract ------
# Everything below is the SERVER's contract, exercised with curl. It is not
# evidence about a daemon binary; MYS-3119 owns that.
step "HTTP contract: claim -> complete/fail, and replay idempotency"
CONTRACT_RUNTIME="$(db "SELECT id FROM agent_runtime WHERE daemon_id='matrix-new-$RUN_ID' ORDER BY id LIMIT 1" | tail -1)"
CONTRACT_AGENT=""
if [ -n "$CONTRACT_RUNTIME" ]; then
  CONTRACT_AGENT="$(db "INSERT INTO agent (workspace_id,name,runtime_id,owner_id,runtime_mode,runtime_config)
      VALUES ('$WS_ID','matrix-contract-agent','$CONTRACT_RUNTIME','$USER_ID','local','{}'::jsonb) RETURNING id" | tail -1)"
fi

seed_task() {
  local runtime=$1 agent=$2 issue task
  issue="$(db "INSERT INTO issue (workspace_id,number,title,status,priority,creator_type,creator_id)
      VALUES ('$WS_ID',(SELECT coalesce(max(number),0)+1 FROM issue WHERE workspace_id='$WS_ID'),
              'matrix task','todo','none','member','$USER_ID') RETURNING id" | tail -1)"
  task="$(db "INSERT INTO agent_task_queue (agent_id,issue_id,status,runtime_id)
      VALUES ('$agent','$issue','queued','$runtime') RETURNING id" | tail -1)"
  printf '%s' "$task"
}
terminal_status() { db "SELECT status FROM agent_task_queue WHERE id='$1'"; }
# Counted per TASK rather than by sweeping the table: a sweep would count rows
# other tests in this same database created.
terminal_rows() { db "SELECT count(*) FROM agent_task_queue WHERE id='$1' AND status IN ('completed','failed','cancelled')"; }

if [ -z "$CONTRACT_RUNTIME" ] || [ -z "$CONTRACT_AGENT" ]; then
  bad "no runtime/agent available for the HTTP contract checks"
else
  # success + replay
  T="$(seed_task "$CONTRACT_RUNTIME" "$CONTRACT_AGENT")"
  S="$(api POST "/api/daemon/runtimes/$CONTRACT_RUNTIME/tasks/claim" '{}' | cut -f1)"
  [ "$S" = "200" ] && ok "claim returns 200" || bad "claim returned $S"
  db "UPDATE agent_task_queue SET status='running' WHERE id='$T'" >/dev/null
  S="$(api POST "/api/daemon/tasks/$T/complete" '{"output":"contract success"}' | cut -f1)"
  [ "$S" = "200" ] && ok "complete returns 200" || bad "complete returned $S"
  [ "$(terminal_status "$T")" = "completed" ] && ok "task state is 'completed'" || bad "task state is '$(terminal_status "$T")'"
  S="$(api POST "/api/daemon/tasks/$T/complete" '{"output":"contract success"}' | cut -f1)"
  note "replayed complete -> $S"
  [ "$(terminal_rows "$T")" = "1" ] && ok "a replayed complete leaves exactly one terminal row" \
    || bad "a replayed complete changed the terminal row count to $(terminal_rows "$T")"

  # failure
  T="$(seed_task "$CONTRACT_RUNTIME" "$CONTRACT_AGENT")"
  api POST "/api/daemon/runtimes/$CONTRACT_RUNTIME/tasks/claim" '{}' >/dev/null
  db "UPDATE agent_task_queue SET status='running' WHERE id='$T'" >/dev/null
  S="$(api POST "/api/daemon/tasks/$T/fail" '{"error":"contract failure"}' | cut -f1)"
  case "$S" in 200|204) ok "fail returns $S";; *) bad "fail returned $S";; esac
  [ "$(terminal_status "$T")" = "failed" ] && ok "task state is 'failed'" || bad "task state is '$(terminal_status "$T")'"
  [ "$(terminal_rows "$T")" = "1" ] && ok "a failed task has exactly one terminal row" \
    || bad "a failed task has $(terminal_rows "$T") terminal rows"
fi

# ------------------------------------------------- registration concurrency --
step "Concurrent registration (distinct identities)"
pids=(); : >"$OUT_DIR/codes.txt"
for round in 1 2 3 4 5 6; do
  for i in $(seq 1 25); do
    ( curl -s -o /dev/null -w '%{http_code}\n' -X POST "$BASE_URL/api/daemon/register" \
        -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
        -d "{\"daemon_id\":\"burst-$round-$i-$RUN_ID\",\"workspace_id\":\"$WS_ID\",\"device_name\":\"burst\",
             \"runtimes\":[{\"name\":\"claude\",\"provider\":\"claude\",\"runtime_mode\":\"local\"}]}" ) >>"$OUT_DIR/codes.txt" &
    pids+=($!)
  done
  for p in "${pids[@]}"; do wait "$p"; done
  pids=()
done
total=$(wc -l <"$OUT_DIR/codes.txt"); ok200=$(grep -c '^200$' "$OUT_DIR/codes.txt" || true)
distinct=$(db "SELECT count(*) FROM agent_runtime WHERE daemon_id LIKE 'burst-%-$RUN_ID'")
note "registration: $ok200/$total returned 200; distinct runtimes: $distinct"
if [ "$ok200" = "$total" ] && [ "$distinct" = "150" ]; then
  ok "150 concurrent registrations produced 150 distinct runtimes"
else
  bad "burst: $ok200/$total ok, $distinct distinct runtimes (want 150)"
fi

step "Reconnect with the same identities"
pids=(); : >"$OUT_DIR/reconn.txt"
for i in $(seq 1 25); do
  ( curl -s -o /dev/null -w '%{http_code}\n' -X POST "$BASE_URL/api/daemon/register" \
      -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
      -d "{\"daemon_id\":\"burst-6-$i-$RUN_ID\",\"workspace_id\":\"$WS_ID\",\"device_name\":\"burst\",
           \"runtimes\":[{\"name\":\"claude\",\"provider\":\"claude\",\"runtime_mode\":\"local\"}]}" ) >>"$OUT_DIR/reconn.txt" &
  pids+=($!)
done
for p in "${pids[@]}"; do wait "$p"; done
after=$(db "SELECT count(*) FROM agent_runtime WHERE daemon_id LIKE 'burst-%-$RUN_ID'")
if [ "$(grep -c '^200$' "$OUT_DIR/reconn.txt")" = "25" ] && [ "$after" = "150" ]; then
  ok "25 reconnects succeeded and left 150 runtimes (no duplicates)"
else
  bad "reconnect: $(grep -c '^200$' "$OUT_DIR/reconn.txt")/25 ok, $after runtimes (want 150)"
fi

step "Duplicate daemon id (refresh, not duplicate)"
# A fresh profile needs its own login before the daemon can start; reuse the
# neutral-CWD trick so the CLI does not refuse on the task marker.
( cd "$OUT_DIR/neutral" && env -u MULTICA_TASK_ID -u MULTICA_TASK_SLOT \
    -u MULTICA_TASK_WORKSPACES_ROOT -u MULTICA_TASK_CONFIG_ROOT -u MULTICA_AGENT_ID -u MULTICA_DAEMON_PORT \
    HOME="$OUT_DIR/state-dup" MULTICA_SERVER_URL="$BASE_URL" MULTICA_TOKEN="$TOKEN" \
    "$DAEMON_NEW" --profile "matrix-dup-$RUN_ID" login --token "$TOKEN" ) >>"$LOG" 2>&1 \
  || bad "duplicate-id profile could not log in"
mkdir -p "$OUT_DIR/state-dup"
for round in 1 2; do
  ( cd "$OUT_DIR/neutral" && exec setsid env -u MULTICA_TASK_ID -u MULTICA_TASK_SLOT \
      -u MULTICA_TASK_WORKSPACES_ROOT -u MULTICA_TASK_CONFIG_ROOT -u MULTICA_AGENT_ID -u MULTICA_DAEMON_PORT \
      HOME="$OUT_DIR/state-dup" MULTICA_SERVER_URL="$BASE_URL" MULTICA_TOKEN="$TOKEN" \
      MULTICA_DAEMON_AUTO_UPDATE=false \
      "$DAEMON_NEW" --profile "matrix-dup-$RUN_ID" daemon start --foreground \
        --daemon-id "matrix-dup-$RUN_ID" --device-name "matrix-dup" --no-auto-update \
        >>"$OUT_DIR/daemon-dup-$round.log" 2>&1 ) &
  printf '%s\n' "$!" >>"$PID_FILE"
  sleep 10
done
rows="$(db "SELECT count(*) FROM agent_runtime WHERE daemon_id='matrix-dup-$RUN_ID'")"
providers="$(db "SELECT count(DISTINCT provider) FROM agent_runtime WHERE daemon_id='matrix-dup-$RUN_ID'")"
if [ "$rows" = "$providers" ] && [ "${rows:-0}" -ge 1 ]; then
  ok "a second start of one daemon id refreshed rows ($rows rows, $providers providers)"
else
  bad "duplicate start produced $rows rows for $providers providers"
fi

step "Rate limiting: registration has none, invitations do"
if grep -q '429' "$OUT_DIR/codes.txt"; then
  bad "daemon registration returned 429; the card says this path has no limiter"
else
  ok "daemon registration is not rate limited (no 429 across $total requests)"
fi

invite_status() { api POST "/api/workspaces/$WS_ID/members" \
  "{\"email\":\"invite-$1@multica.test\",\"role\":\"member\"}" | cut -f1; }
declare -a inv=()
for i in $(seq 1 14); do inv+=("$(invite_status "$RUN_ID-$i")"); done
note "invitation statuses: ${inv[*]}"
first429=-1
for i in "${!inv[@]}"; do
  if [ "${inv[$i]}" = "429" ]; then first429=$((i+1)); break; fi
done
if [ "$first429" -gt 0 ]; then
  ok "the invitation limiter refuses at request $first429 of 14"

  # Recovery: restart the server with a higher limit. The limit is read per
  # request from the environment, so raising it is how recovery is observed
  # without waiting out a 10-minute window.
  kill "$SERVER_PID" 2>/dev/null; wait "$SERVER_PID" 2>/dev/null
  INVITE_LIMIT=100 start_server "$OUT_DIR/server-restarted.log" \
    || { bad "server did not come back after the limit change"; }
  recovered="$(invite_status "$RUN_ID-recovered")"
  case "$recovered" in
    201|200) ok "after raising the actor limit the same actor can invite again ($recovered)";;
    *) bad "no recovery after raising the actor limit ($recovered)";;
  esac
else
  bad "the invitation limiter never refused across 14 invitations (${inv[*]})"
fi

step "Invalid credentials"
status="$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE_URL/api/daemon/register" \
  -H 'Authorization: Bearer mul_not_a_real_token' -H 'Content-Type: application/json' \
  -d "{\"daemon_id\":\"x\",\"workspace_id\":\"$WS_ID\",\"runtimes\":[]}")"
[ "$status" = "401" ] && ok "an invalid token is refused with 401" || bad "invalid token got $status, want 401"

# ------------------------------------------------------------------ table ----
step "Scope table"
# Only cells this script actually produced are filled. The daemon-behaviour row
# is deferred, and says so, instead of borrowing the HTTP contract's evidence.
cat >"$OUT_DIR/scope-table.md" <<EOF
| what | who measured it | status |
| --- | --- | --- |
| registration + heartbeat advance by the real $LABEL_OLD binary | this script | measured |
| registration + heartbeat advance by the real $LABEL_NEW binary | this script | measured |
| registration/heartbeat/claim/complete/fail HTTP contract, replay idempotency | this script (curl) | measured |
| concurrent registration 150, reconnect 25, duplicate id, invalid token | this script (curl) | measured |
| invitation limiter trigger + recovery | this script (curl) | measured |
| a daemon BINARY claiming, backing off on retry, single terminal side effect | **MYS-3119** | not measured here |
| $LABEL_NEW binary against a $LABEL_OLD server | nobody | not run; not a supported target |
EOF
cat "$OUT_DIR/scope-table.md" >>"$LOG"
note "scope table written to $OUT_DIR/scope-table.md"

step "Summary"
note "pass: $(pass_count)   fail: $(fail_count)"
if [ "$(fail_count)" -gt 0 ]; then
  printf 'FAILURES:\n'
  sed 's/^/  - /' "$FAIL_LIST"
  exit 1
fi
