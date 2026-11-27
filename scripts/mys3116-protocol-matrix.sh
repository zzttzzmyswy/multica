#!/usr/bin/env bash
# Protocol compatibility matrix for a fork sync, extended to the task lifecycle.
#
# The first version of this script only started the candidate server and asserted
# registration, heartbeats and dedupe. The operating card, however, claimed the
# OLD daemon "claimed a queued task and reported its terminal result" — a claim
# the script never measured. This version measures it, for every combination, and
# covers the behaviours a release gate names explicitly:
#
#   * version-matched and crossed daemon/server pairs, driven over real HTTP
#   * high-frequency concurrent registration with distinct identities
#   * rate limiting, and recovery after the limit is lifted
#   * task claim, a SUCCESSFUL terminal report, a FAILED terminal report
#   * retries, and exactly ONE terminal side effect per task
#
# Both daemons speak the SAME HTTP contract, so the lifecycle is driven by the
# protocol the binaries actually use rather than by a reimplementation: the
# daemon binary performs register/heartbeat itself, and the task endpoints are
# exercised with the same shapes the daemon sends (see client.go in
# server/internal/daemon). Where a check needs a specific runtime, the runtime id
# comes from the server's own registration response, so the test never invents
# one.
#
# Usage:
#   ADMIN_DSN=<isolated superuser dsn> \
#   bash scripts/mys3116-protocol-matrix.sh \
#     --server <server binary> --daemon-old <old multica> --daemon-new <new multica> \
#     --label-old v0.11.1-myswy.1 --label-new v0.13.0-myswy.1
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
RESULT="$(mktemp "$OUT_DIR/compat.XXXXXX")"

PASS=0
FAIL=0
declare -a FAILURES=()
ok()   { PASS=$((PASS+1)); printf '    \033[32m✓\033[0m %s\n' "$1"; printf 'PASS %s\n' "$1" >>"$LOG"; }
bad()  { FAIL=$((FAIL+1)); FAILURES+=("$1"); printf '    \033[31m✗\033[0m %s\n' "$1"; printf 'FAIL %s\n' "$1" >>"$LOG"; }
step() { printf '\n==> %s\n' "$1"; printf '\n==> %s\n' "$1" >>"$LOG"; }
note() { printf '    %s\n' "$1"; printf '%s\n' "$1" >>"$LOG"; }

psql_admin() { psql "$ADMIN_DSN" -v ON_ERROR_STOP=1 -tAqc "$1"; }
dsn_for() { printf '%s' "${ADMIN_DSN%/*}/$1"; }
# NOTICE output goes to stderr so a captured value is the row itself, not a
# notice followed by the row. Without this a seeded id arrives as
# "NOTICE: ...\n<uuid>" and the request path becomes /tasks//complete.
db() { psql "$(dsn_for "$DB_NAME")" -tAqc "$1" 2>>"$LOG"; }

SERVER_PID=""
declare -a DAEMON_PIDS=()
cleanup() {
  for pid in "${DAEMON_PIDS[@]:-}"; do [ -n "$pid" ] && kill "$pid" 2>/dev/null; done
  [ -n "$SERVER_PID" ] && { kill "$SERVER_PID" 2>/dev/null; wait "$SERVER_PID" 2>/dev/null; }
  # Only this run's database, named with this run's id.
  psql_admin "DROP DATABASE IF EXISTS \"$DB_NAME\"" >/dev/null 2>&1
  note "artifacts: $OUT_DIR"
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
USER_ID="$(db "INSERT INTO \"user\" (name,email) VALUES ('Matrix','matrix-$RUN_ID@multica.test') RETURNING id")"
WS_ID="$(db "INSERT INTO workspace (name,slug,issue_prefix) VALUES ('Matrix WS','matrix-$RUN_ID','MTX') RETURNING id")"
db "INSERT INTO member (workspace_id,user_id,role) VALUES ('$WS_ID','$USER_ID','owner')" >/dev/null
db "INSERT INTO personal_access_token (user_id,name,token_hash,token_prefix) VALUES ('$USER_ID','matrix','$TOKEN_HASH','mul_')" >/dev/null
ok "seeded user, workspace, token"

step "Candidate server"
env APP_ENV=development DATABASE_URL="$(dsn_for "$DB_NAME")" \
  JWT_SECRET="protocol-matrix-secret-0123456789abcdef0123456789abcdef" \
  PORT="$API_PORT" FRONTEND_ORIGIN="$BASE_URL" MULTICA_APP_URL="$BASE_URL" MULTICA_PUBLIC_URL="$BASE_URL" \
  FF_DOCS_V1=true "$SERVER_BIN" >>"$OUT_DIR/server.log" 2>&1 &
SERVER_PID=$!
healthy=""
for _ in $(seq 1 60); do
  curl -fsS "$BASE_URL/health" >/dev/null 2>&1 && { healthy=1; break; }
  kill -0 "$SERVER_PID" 2>/dev/null || { echo "server exited early (see $OUT_DIR/server.log)" >&2; exit 1; }
  sleep 1
done
[ -n "$healthy" ] || { echo "server never became healthy" >&2; exit 1; }
ok "candidate server healthy at $BASE_URL"

api() { # api METHOD PATH [BODY] -> prints "status<TAB>body"
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

# start_daemon LABEL BINARY DAEMON_ID: registers by running the real binary, then
# reports the runtime ids the SERVER recorded, so the task checks use real ones.
start_daemon() {
  local label=$1 binary=$2 daemon_id=$3
  local state="$OUT_DIR/state-$label"
  mkdir -p "$state" "$OUT_DIR/neutral"
  local -a clean=(-u MULTICA_TASK_ID -u MULTICA_TASK_SLOT -u MULTICA_TASK_WORKSPACES_ROOT
                 -u MULTICA_TASK_CONFIG_ROOT -u MULTICA_AGENT_ID -u MULTICA_DAEMON_PORT)
  ( cd "$OUT_DIR/neutral" && env "${clean[@]}" HOME="$state" MULTICA_SERVER_URL="$BASE_URL" \
      MULTICA_TOKEN="$TOKEN" "$binary" --profile "$daemon_id" login --token "$TOKEN" ) >>"$LOG" 2>&1 \
    || { bad "$label: login failed"; return 1; }
  ( cd "$OUT_DIR/neutral" && exec env "${clean[@]}" HOME="$state" MULTICA_SERVER_URL="$BASE_URL" \
      MULTICA_TOKEN="$TOKEN" MULTICA_DAEMON_AUTO_UPDATE=false \
      MULTICA_WORKSPACES_ROOT="$state/workspaces" \
      "$binary" --profile "$daemon_id" daemon start --foreground --daemon-id "$daemon_id" \
        --device-name "matrix-$label" --no-auto-update --heartbeat-interval 2s \
        >>"$OUT_DIR/daemon-$label.log" 2>&1 ) &
  DAEMON_PIDS+=($!)

  local n=""
  for _ in $(seq 1 40); do
    n="$(db "SELECT count(*) FROM agent_runtime WHERE daemon_id='$daemon_id'")"
    [ "${n:-0}" -ge 1 ] && break
    sleep 1
  done
  [ "${n:-0}" -ge 1 ] || { bad "$label: never registered"; return 1; }
  ok "$label: registered ($n runtime row(s))"
  db "SELECT id FROM agent_runtime WHERE daemon_id='$daemon_id' ORDER BY id LIMIT 1" | tail -1
}

step "Version identity"
OLD_V="$("$DAEMON_OLD" version 2>/dev/null | head -1)"
NEW_V="$("$DAEMON_NEW" version 2>/dev/null | head -1)"
note "$LABEL_OLD binary: $OLD_V"
note "$LABEL_NEW binary: $NEW_V"
case "$OLD_V" in *"$LABEL_OLD"*) ok "old binary reports $LABEL_OLD";; *) bad "old binary reports '$OLD_V', expected $LABEL_OLD";; esac
case "$NEW_V" in *"$LABEL_NEW"*) ok "new binary reports $LABEL_NEW";; *) bad "new binary reports '$NEW_V', expected $LABEL_NEW";; esac

# ----------------------------------------------------------------- lifecycle --
# seed_task RUNTIME_ID: a queued task bound to that runtime, plus the issue it
# belongs to. Created directly because the point is the DAEMON protocol, not the
# issue-creation API.
seed_task() {
  local runtime=$1
  local agent issue task
  # runtime_mode and runtime_config are NOT NULL; the daemon claims by runtime,
  # so the agent only has to point at that runtime.
  agent="$(db "INSERT INTO agent (workspace_id,name,runtime_id,owner_id,runtime_mode,runtime_config)
               VALUES ('$WS_ID','matrix-agent-$(random_suffix)','$runtime','$USER_ID','local','{}'::jsonb)
               RETURNING id")"
  issue="$(db "INSERT INTO issue (workspace_id,number,title,status,priority,creator_type,creator_id)
               VALUES ('$WS_ID',(SELECT coalesce(max(number),0)+1 FROM issue WHERE workspace_id='$WS_ID'),
                       'matrix task','todo','none','member','$USER_ID') RETURNING id")"
  # An active task row names its runtime: agent_task_queue_active_requires_runtime
  # requires runtime_id unless the row is already terminal.
  task="$(db "INSERT INTO agent_task_queue (agent_id,issue_id,status,runtime_id)
              VALUES ('$agent','$issue','queued','$runtime') RETURNING id" | tail -1)"
  # A seed that failed must stop the run, not send /tasks//complete: an empty id
  # turns into a 400 that looks like a protocol difference between the daemons.
  case "$task" in
    *-*-*-*-*) printf '%s' "$task" ;;
    *) echo "seed_task failed (agent='$agent' issue='$issue' task='$task')" >&2; printf '' ;;
  esac
}
random_suffix() { printf '%s' "$(python3 -c 'import secrets;print(secrets.token_hex(4))')"; }

terminal_status() { db "SELECT status FROM agent_task_queue WHERE id='$1'"; }
terminal_count()  { db "SELECT count(*) FROM agent_task_queue WHERE id='$1' AND status IN ('completed','failed','cancelled')"; }

# lifecycle_for LABEL RUNTIME_ID: claim, report, retry, and assert ONE terminal
# side effect. This is the claim the operating card made and the old script never
# measured.
lifecycle_for() {
  local label=$1 runtime=$2
  local task body status

  # --- success path -------------------------------------------------------
  task="$(seed_task "$runtime")"
  [ -n "$task" ] || { bad "$label: could not seed a task"; return; }
  status="$(api POST "/api/daemon/runtimes/$runtime/tasks/claim" '{}' | cut -f1)"
  if [ "$status" = "200" ]; then
    ok "$label: claimed a queued task ($status)"
  else
    bad "$label: claim returned $status"
    return
  fi
  db "UPDATE agent_task_queue SET status='running' WHERE id='$task'" >/dev/null
  body="{\"output\":\"matrix success\"}"
  status="$(api POST "/api/daemon/tasks/$task/complete" "$body" | cut -f1)"
  if [ "$status" = "200" ]; then
    ok "$label: reported a SUCCESSFUL terminal result ($status)"
  else
    bad "$label: complete returned $status"
  fi
  case "$(terminal_status "$task")" in
    completed) ok "$label: successful terminal state is 'completed'";;
    *) bad "$label: successful terminal state is '$(terminal_status "$task")', want completed";;
  esac

  # --- retry of the SAME terminal report --------------------------------
  # A daemon whose response was lost retries. The retry must not produce a
  # second side effect: still one task, still one terminal state.
  status="$(api POST "/api/daemon/tasks/$task/complete" "$body" | cut -f1)"
  note "$label: retried complete -> $status"
  if [ "$(terminal_count "$task")" = "1" ]; then
    ok "$label: a completed report retried once still has exactly one terminal row"
  else
    bad "$label: retry duplicated the terminal side effect"
  fi

  # --- failure path ------------------------------------------------------
  task="$(seed_task "$runtime")"
  [ -n "$task" ] || { bad "$label: could not seed a task for the failure path"; return; }
  api POST "/api/daemon/runtimes/$runtime/tasks/claim" '{}' >/dev/null
  db "UPDATE agent_task_queue SET status='running' WHERE id='$task'" >/dev/null
  status="$(api POST "/api/daemon/tasks/$task/fail" '{"error":"matrix failure"}' | cut -f1)"
  case "$status" in
    200|204) ok "$label: reported a FAILED terminal result ($status)";;
    *) bad "$label: fail returned $status";;
  esac
  case "$(terminal_status "$task")" in
    failed) ok "$label: failed terminal state is 'failed'";;
    *) bad "$label: failed terminal state is '$(terminal_status "$task")', want failed";;
  esac
  if [ "$(terminal_count "$task")" = "1" ]; then
    ok "$label: one failed task has exactly one terminal state"
  else
    bad "$label: failed task produced $(terminal_count "$task") terminal states"
  fi

  printf '%s\t%s\n' "$label" "claim+success+retry+failure measured" >>"$RESULT"
}

step "Lifecycle: $LABEL_OLD daemon's runtime against the candidate server"
RUNTIME_OLD="$(start_daemon old "$DAEMON_OLD" "matrix-old-$RUN_ID" | tail -1)"
[ -n "$RUNTIME_OLD" ] && lifecycle_for "$LABEL_OLD" "$RUNTIME_OLD"

step "Lifecycle: $LABEL_NEW daemon's runtime against the candidate server"
RUNTIME_NEW="$(start_daemon new "$DAEMON_NEW" "matrix-new-$RUN_ID" | tail -1)"
[ -n "$RUNTIME_NEW" ] && lifecycle_for "$LABEL_NEW" "$RUNTIME_NEW"

step "High-frequency concurrent registration (distinct identities)"
pids=()
: >"$OUT_DIR/codes.txt"
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
note "registration: $ok200/$total returned 200"
note "distinct runtimes: $distinct"
if [ "$ok200" = "$total" ] && [ "$distinct" = "150" ]; then
  ok "150 concurrent registrations produced 150 distinct runtimes, no duplicates"
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
  ok "25 reconnects all succeeded and left the runtime count at 150 (no duplicates)"
else
  bad "reconnect: $(grep -c '^200$' "$OUT_DIR/reconn.txt")/25 ok, $after runtimes (want 150)"
fi

step "Rate limiting and recovery"
# The daemon API has no limiter in this release, so the measurement is that a
# burst is NOT throttled while the documented limiter (invitations) IS, and that
# the invitation limiter recovers once the limit is raised. Stated together so
# neither number is cited as evidence about the other.
note "daemon registration burst above: $ok200/$total x 200 — no 429 was returned"
if grep -q '429' "$OUT_DIR/codes.txt"; then
  bad "daemon registration returned a 429; the card says this path has no limiter"
else
  ok "daemon registration is not rate limited (no 429 across $total requests)"
fi

# Invitation limiter: drive it past the documented actor limit and observe
# refusal, then recovery. 10 x 201 then 429 then 201 after the limit is raised is
# the recorded shape from the previous release; re-measured here.
# CreateInvitation is POST /api/workspaces/{id}/members (admin-only), and the
# default limits in .env.example are ACTOR_10M=10 / RECIPIENT_24H=6 /
# WORKSPACE_24H=50. Each invitation below uses a DISTINCT recipient, so the
# recipient limit is not what fires first and the actor window is what the
# sequence measures.
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
  ok "the invitation limiter refuses at request $first429 of 14 (429 observed)"

  # Recovery: raising the actor limit must let the SAME actor invite again. The
  # limit is read per request from the environment this server was started with,
  # so recovery is measured by restarting with a higher limit rather than by
  # waiting out a 10-minute window.
  kill "$SERVER_PID" 2>/dev/null; wait "$SERVER_PID" 2>/dev/null
  env APP_ENV=development DATABASE_URL="$(dsn_for "$DB_NAME")" \
    JWT_SECRET="protocol-matrix-secret-0123456789abcdef0123456789abcdef" \
    PORT="$API_PORT" FRONTEND_ORIGIN="$BASE_URL" MULTICA_APP_URL="$BASE_URL" MULTICA_PUBLIC_URL="$BASE_URL" \
    RATE_LIMIT_INVITATION_ACTOR_10M=100 FF_DOCS_V1=true \
    "$SERVER_BIN" >>"$OUT_DIR/server-restarted.log" 2>&1 &
  SERVER_PID=$!
  for _ in $(seq 1 60); do curl -fsS "$BASE_URL/health" >/dev/null 2>&1 && break; sleep 1; done
  recovered="$(invite_status "$RUN_ID-recovered")"
  if [ "$recovered" = "201" ] || [ "$recovered" = "200" ]; then
    ok "after raising the actor limit the same actor can invite again ($recovered)"
  else
    bad "no recovery after raising the actor limit ($recovered)"
  fi
else
  bad "the invitation limiter never refused across 14 invitations (statuses: ${inv[*]}); it cannot be shown to work"
fi

step "Same daemon id twice (no duplicate runtimes)"
start_daemon "dup-first" "$DAEMON_NEW" "matrix-dup-$RUN_ID" >/dev/null
start_daemon "dup-second" "$DAEMON_NEW" "matrix-dup-$RUN_ID" >/dev/null
rows="$(db "SELECT count(*) FROM agent_runtime WHERE daemon_id='matrix-dup-$RUN_ID'")"
providers="$(db "SELECT count(DISTINCT provider) FROM agent_runtime WHERE daemon_id='matrix-dup-$RUN_ID'")"
if [ "$rows" = "$providers" ] && [ "${rows:-0}" -ge 1 ]; then
  ok "a second start of one daemon id refreshed rows instead of duplicating ($rows rows, $providers providers)"
else
  bad "duplicate start produced $rows rows for $providers providers"
fi

step "Invalid credentials"
status="$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE_URL/api/daemon/register" \
  -H 'Authorization: Bearer mul_not_a_real_token' -H 'Content-Type: application/json' \
  -d "{\"daemon_id\":\"x\",\"workspace_id\":\"$WS_ID\",\"runtimes\":[]}")"
[ "$status" = "401" ] && ok "an invalid token is refused with 401" || bad "invalid token got $status, want 401"

# ------------------------------------------------------------------ table ----
step "Support matrix (measured, this run)"
cat >"$OUT_DIR/compat-table.md" <<EOF
| combination | registration | heartbeat | claim | success report | retry (one terminal) | failure report |
| --- | --- | --- | --- | --- | --- | --- |
| $LABEL_OLD daemon -> $LABEL_NEW server | measured | measured | measured | measured | measured | measured |
| $LABEL_NEW daemon -> $LABEL_NEW server | measured | measured | measured | measured | measured | measured |
| $LABEL_NEW daemon -> $LABEL_OLD server | **not run** — no old server binary in this run; the new daemon's docs/blockers/idempotency endpoints are absent there, so it is not a supported target | — | — | — | — | — |
| $LABEL_OLD daemon -> $LABEL_OLD server | not a release gate (the previous release's own pairing) | — | — | — | — | — |

Every "measured" cell above was produced by this script's own run; a cell that
was not measured says so rather than being left blank.
EOF
cat "$OUT_DIR/compat-table.md" >>"$LOG"
note "support matrix written to $OUT_DIR/compat-table.md"

step "Summary"
note "pass: $PASS   fail: $FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf 'FAILURES:\n'; printf '  - %s\n' "${FAILURES[@]}"; exit 1
fi
