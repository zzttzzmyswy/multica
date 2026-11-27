#!/usr/bin/env bash
# Protocol compatibility matrix between this distribution's releases.
#
# Starts one server build and drives daemon binaries against it over real HTTP,
# recording what each combination can do. Nothing here touches production: the
# server binds loopback on a free port, uses its own database, and every daemon
# gets a private state directory.
#
# Usage:
#   ADMIN_DSN=<isolated superuser dsn> \
#   bash scripts/mys3116-protocol-matrix.sh \
#     --server <server binary> \
#     --daemon-old <previous release multica binary> \
#     --daemon-new <candidate multica binary> \
#     [--label-old vX.Y.Z] [--label-new vX.Y.Z]
#
# The daemons authenticate with a personal access token this script seeds
# directly (a user row plus the SHA-256 of a token it generates), so the matrix
# tests the daemon protocol rather than the browser sign-in flow.
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

PASS=0
FAIL=0
declare -a FAILURES=()
ok()   { PASS=$((PASS+1)); printf '    \033[32m✓\033[0m %s\n' "$1"; printf 'PASS %s\n' "$1" >>"$LOG"; }
bad()  { FAIL=$((FAIL+1)); FAILURES+=("$1"); printf '    \033[31m✗\033[0m %s\n' "$1"; printf 'FAIL %s\n' "$1" >>"$LOG"; }
step() { printf '\n==> %s\n' "$1"; printf '\n==> %s\n' "$1" >>"$LOG"; }
note() { printf '    %s\n' "$1"; printf '%s\n' "$1" >>"$LOG"; }

psql_admin() { psql "$ADMIN_DSN" -v ON_ERROR_STOP=1 -tAqc "$1"; }
dsn_for() { printf '%s' "${ADMIN_DSN%/*}/$1"; }
db() { psql "$(dsn_for "$DB_NAME")" -tAqc "$1"; }

SERVER_PID=""
declare -a DAEMON_PIDS=()
cleanup() {
  for pid in "${DAEMON_PIDS[@]:-}"; do
    [ -n "$pid" ] && kill "$pid" 2>/dev/null
  done
  if [ -n "$SERVER_PID" ]; then
    kill "$SERVER_PID" 2>/dev/null
    wait "$SERVER_PID" 2>/dev/null
  fi
  psql_admin "DROP DATABASE IF EXISTS \"$DB_NAME\"" >/dev/null 2>&1
  note "artifacts: $OUT_DIR"
}
trap cleanup EXIT

API_PORT="$(python3 -c '
import socket
s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()
')"
BASE_URL="http://127.0.0.1:$API_PORT"

# --------------------------------------------------------------- database ----
step "Isolated database"
psql_admin "CREATE DATABASE \"$DB_NAME\"" >/dev/null || { echo "could not create $DB_NAME" >&2; exit 1; }
psql "$(dsn_for "$DB_NAME")" -q -v ON_ERROR_STOP=1 \
  -c "CREATE EXTENSION IF NOT EXISTS vector; CREATE EXTENSION IF NOT EXISTS pg_trgm; CREATE EXTENSION IF NOT EXISTS pgcrypto;" \
  >>"$LOG" 2>&1 || { echo "could not create extensions" >&2; exit 1; }
( cd "$ROOT_DIR/server" && DATABASE_URL="$(dsn_for "$DB_NAME")" go run ./cmd/migrate up ) >>"$LOG" 2>&1 \
  || { echo "migrations failed (see $LOG)" >&2; exit 1; }
ok "created $DB_NAME and applied the candidate migration tree"

# ---------------------------------------------------------------- account ----
# A user, a workspace they own, and a PAT are all a daemon needs. Seeding them
# directly keeps the matrix about the protocol: a browser sign-in would test the
# auth flow instead, and would need a code round-trip per daemon.
step "Seed account and token"
TOKEN="mul_$(python3 -c 'import secrets;print(secrets.token_hex(24))')"
TOKEN_HASH="$(python3 -c "import hashlib,sys;print(hashlib.sha256(sys.argv[1].encode()).hexdigest())" "$TOKEN")"
USER_ID="$(db "INSERT INTO \"user\" (name, email) VALUES ('Matrix User', 'matrix-$RUN_ID@multica.test') RETURNING id")"
WS_ID="$(db "INSERT INTO workspace (name, slug, issue_prefix) VALUES ('Matrix WS', 'matrix-$RUN_ID', 'MTX') RETURNING id")"
db "INSERT INTO member (workspace_id, user_id, role) VALUES ('$WS_ID', '$USER_ID', 'owner')" >/dev/null
db "INSERT INTO personal_access_token (user_id, name, token_hash, token_prefix)
    VALUES ('$USER_ID', 'matrix', '$TOKEN_HASH', 'mul_')" >/dev/null
ok "seeded user, workspace and token"

# ----------------------------------------------------------------- server ----
step "Candidate server"
JWT_SECRET="protocol-matrix-secret-0123456789abcdef0123456789abcdef"
env \
  APP_ENV=development \
  DATABASE_URL="$(dsn_for "$DB_NAME")" \
  JWT_SECRET="$JWT_SECRET" \
  PORT="$API_PORT" \
  FRONTEND_ORIGIN="$BASE_URL" \
  MULTICA_APP_URL="$BASE_URL" \
  MULTICA_PUBLIC_URL="$BASE_URL" \
  FF_DOCS_V1=true \
  "$SERVER_BIN" >>"$OUT_DIR/server.log" 2>&1 &
SERVER_PID=$!
healthy=""
for _ in $(seq 1 60); do
  if curl -fsS "$BASE_URL/health" >/dev/null 2>&1; then healthy=1; break; fi
  kill -0 "$SERVER_PID" 2>/dev/null || { echo "server exited early (see $OUT_DIR/server.log)" >&2; exit 1; }
  sleep 1
done
[ -n "$healthy" ] || { echo "server never became healthy (see $OUT_DIR/server.log)" >&2; exit 1; }
ok "candidate server healthy at $BASE_URL"

# ----------------------------------------------------------------- daemon ----
# observe_daemon LABEL BINARY DAEMON_ID: start a daemon, wait for its runtime
# row, prove the heartbeat advances, then stop it. Everything asserted here is
# the server's view, so it is the same measurement for either binary.
observe_daemon() {
  local label=$1 binary=$2 daemon_id=$3
  local state_dir="$OUT_DIR/state-$label"
  mkdir -p "$state_dir"

  # `multica login` and `multica daemon start` both refuse to run inside a
  # daemon-managed task: the CLI looks for a task marker in the working
  # directory (and the MULTICA_TASK_* identity variables) and stops, which is
  # exactly where this script runs when an agent invokes it. Run the child from
  # a neutral directory with the task identity cleared, so it behaves like an
  # ordinary shell on the machine — the situation a real daemon lives in.
  local -a clean_env=(
    -u MULTICA_TASK_ID -u MULTICA_TASK_SLOT -u MULTICA_TASK_WORKSPACES_ROOT
    -u MULTICA_TASK_CONFIG_ROOT -u MULTICA_AGENT_ID -u MULTICA_DAEMON_PORT
  )
  local neutral="$OUT_DIR/neutral"
  mkdir -p "$neutral"
  ( cd "$neutral" && env "${clean_env[@]}" HOME="$state_dir" MULTICA_SERVER_URL="$BASE_URL" MULTICA_TOKEN="$TOKEN" \
      "$binary" --profile "$daemon_id" login --token "$TOKEN" ) >>"$LOG" 2>&1
  local login_status=$?
  if [ $login_status -ne 0 ]; then
    bad "$label: login --token failed (exit $login_status) (see $LOG)"
    return
  fi
  ok "$label: authenticated with the seeded token"

  ( cd "$neutral" && exec env "${clean_env[@]}" HOME="$state_dir" \
      MULTICA_SERVER_URL="$BASE_URL" MULTICA_TOKEN="$TOKEN" \
      MULTICA_DAEMON_AUTO_UPDATE=false MULTICA_WORKSPACES_ROOT="$state_dir/workspaces" \
      "$binary" --profile "$daemon_id" daemon start --foreground --daemon-id "$daemon_id" \
        --device-name "matrix-$label" --no-auto-update --heartbeat-interval 2s \
        >>"$OUT_DIR/daemon-$label.log" 2>&1 ) &
  local pid=$!
  DAEMON_PIDS+=("$pid")

  local seen=""
  for _ in $(seq 1 40); do
    seen="$(db "SELECT count(*) FROM agent_runtime WHERE daemon_id = '$daemon_id'")"
    [ "${seen:-0}" -ge 1 ] && break
    sleep 1
  done
  if [ "${seen:-0}" -ge 1 ]; then
    ok "$label: registered (runtime row for $daemon_id)"
  else
    bad "$label: never registered (see $OUT_DIR/daemon-$label.log)"
    kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
    return
  fi

  # A daemon registers one runtime per agent provider it finds (claude, codex,
  # ...), so the count is a property of the machine, not a fixed 1. What the
  # protocol promises is one row per (daemon, provider).
  local runtimes distinct
  runtimes="$(db "SELECT count(*) FROM agent_runtime WHERE daemon_id = '$daemon_id'")"
  distinct="$(db "SELECT count(DISTINCT provider) FROM agent_runtime WHERE daemon_id = '$daemon_id'")"
  if [ "$runtimes" = "$distinct" ] && [ "${runtimes:-0}" -ge 1 ]; then
    ok "$label: $runtimes runtime(s), one per provider, no duplicates"
  else
    bad "$label: $runtimes runtime rows but only $distinct distinct providers"
  fi

  # The steady-state online bump is coalesced by a 30s batch scheduler
  # (DefaultHeartbeatBatchInterval), so a shorter wait measures nothing. Wait
  # past one full tick and require the timestamp to move.
  local before after
  before="$(db "SELECT coalesce(max(last_seen_at)::text,'') FROM agent_runtime WHERE daemon_id = '$daemon_id'")"
  sleep 40
  after="$(db "SELECT coalesce(max(last_seen_at)::text,'') FROM agent_runtime WHERE daemon_id = '$daemon_id'")"
  if [ -n "$after" ] && [ "$after" != "$before" ]; then
    ok "$label: heartbeat advanced last_seen_at"
  else
    bad "$label: heartbeat did not advance last_seen_at within 40s ($before -> $after)"
  fi

  kill "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
}

step "Protocol: $LABEL_OLD daemon against the candidate server"
observe_daemon old "$DAEMON_OLD" "matrix-old-$RUN_ID"

step "Protocol: $LABEL_NEW daemon against the candidate server"
observe_daemon new "$DAEMON_NEW" "matrix-new-$RUN_ID"

step "Same daemon id twice"
observe_daemon dup-first "$DAEMON_NEW" "matrix-dup-$RUN_ID"
observe_daemon dup-second "$DAEMON_NEW" "matrix-dup-$RUN_ID"
# Registration is keyed by (workspace, daemon_id, provider). Starting the same
# daemon id twice must refresh those rows, not add a second set — otherwise
# every restart leaks runtimes and the server would dispatch one task twice.
dup_rows="$(db "SELECT count(*) FROM agent_runtime WHERE daemon_id = 'matrix-dup-$RUN_ID'")"
dup_providers="$(db "SELECT count(DISTINCT provider) FROM agent_runtime WHERE daemon_id = 'matrix-dup-$RUN_ID'")"
if [ "${dup_rows:-0}" = "${dup_providers:-1}" ] && [ "${dup_rows:-0}" -ge 1 ]; then
  ok "a second start of one daemon id refreshed its rows instead of duplicating them ($dup_rows rows, $dup_providers providers)"
else
  bad "a second start of one daemon id produced $dup_rows rows for $dup_providers providers"
fi

step "Invalid credentials"
status="$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE_URL/api/daemon/register" \
  -H 'Authorization: Bearer mul_not_a_real_token' -H 'Content-Type: application/json' \
  -d "{\"daemon_id\":\"x\",\"workspace_id\":\"$WS_ID\",\"runtimes\":[]}")"
if [ "$status" = "401" ]; then
  ok "an invalid token is refused with 401"
else
  bad "an invalid token got $status, want 401"
fi

step "Token is honoured"
status="$(curl -s -o /dev/null -w '%{http_code}' "$BASE_URL/api/daemon/workspaces" -H "Authorization: Bearer $TOKEN")"
if [ "$status" = "200" ]; then
  ok "the seeded token authenticates a daemon route (200)"
else
  bad "the seeded token got $status on a daemon route, want 200"
fi

# ---------------------------------------------------------------- summary ----
step "Summary"
note "pass: $PASS   fail: $FAIL"
note "server log: $OUT_DIR/server.log"
note "daemon logs: $OUT_DIR/daemon-*.log"
if [ "$FAIL" -gt 0 ]; then
  printf 'FAILURES:\n'
  printf '  - %s\n' "${FAILURES[@]}"
  exit 1
fi
