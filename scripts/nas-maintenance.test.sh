#!/usr/bin/env bash
# Behavioural tests for scripts/nas-maintenance.sh.
#
# The executor decides whether a production Multica switch freezes every writer
# before it takes a backup, whether a migration that stopped half-way may look
# like success, and whether a rollback restores the old images or merely
# restarts the new ones. Each of those mistakes is unrecoverable in place, so
# every case pins observed state — unit and container states, compose bytes,
# file hashes, call order, the journal, and the exit code — instead of matching
# an exit code alone.
#
# Everything external is stubbed. systemctl, docker and curl come from
# scripts/testdata/nas-maintenance/stubs; the release archive and the approved
# upgrade script are generated fixtures; every path lives under one private temp
# directory. No NAS path, real daemon, SSH or network is reachable, and no case
# modifies the executor.
#
# Usage: bash scripts/nas-maintenance.test.sh
set -uo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
EXECUTOR="$SCRIPT_DIR/nas-maintenance.sh"
STUBS="$SCRIPT_DIR/testdata/nas-maintenance/stubs"

PASS=0
FAIL=0
FAILURES=()
CASE="setup"
RC=0
OUT=""
CUR=""

ok()  { PASS=$((PASS + 1)); printf '    \033[32m✓\033[0m %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); FAILURES+=("$CASE: $1"); printf '    \033[31m✗\033[0m %s\n' "$1"; }
step() { CASE=$1; printf '\n==> %s\n' "$1"; }

[ -f "$EXECUTOR" ] || { echo "missing $EXECUTOR" >&2; exit 1; }
[ -x "$STUBS/systemctl" ] && [ -x "$STUBS/docker" ] && [ -x "$STUBS/curl" ] || {
    echo "missing stubs under $STUBS" >&2
    exit 1
}

TMP="$(mktemp -d "${TMPDIR:-/tmp}/nas-maintenance-test.XXXXXX")" || exit 1
trap 'rm -rf "$TMP"' EXIT

# ---------------------------------------------------------------------------
# Release pins, kept here independently of the executor so a drift in either
# side fails the suite instead of both agreeing on a wrong value.
# ---------------------------------------------------------------------------
BACKEND_DIGEST_OLD=sha256:864a97102959895b174f4fb1e2798bc38c896ea9ff33497564ec11eac5728374
WEB_DIGEST_OLD=sha256:ece41d5b9732ce62a4362e5b55dd89ca2fa5ad9af692536738958a8da92d31fa
BACKEND_DIGEST_NEW=sha256:01e09bc9d800260b89834c6a0a00433a456daa5f8ec06211a1515da103817702
WEB_DIGEST_NEW=sha256:011f47fd9a1adf688382f36d7b9446fd580d50b0b7321377492e189da46e4b26
REV_OLD=b1ea927def6490c43bedff537b6f4ed9a47fa828
REV_NEW=8098fd32808c57d8e3b6bd8f7408e6e47b81e7ab
CLI_VERSION_OLD=0.9.0
CLI_VERSION_NEW=0.9.0-myswy.2
BACKEND_IMAGE_OLD="ghcr.io/zzttzzmyswy/multica-backend@$BACKEND_DIGEST_OLD"
WEB_IMAGE_OLD="ghcr.io/zzttzzmyswy/multica-web@$WEB_DIGEST_OLD"
BACKEND_IMAGE_NEW="ghcr.io/zzttzzmyswy/multica-backend@$BACKEND_DIGEST_NEW"
WEB_IMAGE_NEW="ghcr.io/zzttzzmyswy/multica-web@$WEB_DIGEST_NEW"

# ---------------------------------------------------------------------------
# Fixtures, built once and copied into each case sandbox.
# ---------------------------------------------------------------------------
FIXTURES="$TMP/fixtures"
mkdir -p "$FIXTURES/cli-src"

write_cli() {
    cat >"$1" <<STUB
#!/usr/bin/env bash
printf 'multica ${2} (commit: deadbee, built: 2026-01-01T00:00:00Z)\n'
STUB
    chmod 755 "$1"
}

write_cli "$FIXTURES/cli-src/multica" "$CLI_VERSION_NEW"
tar -czf "$FIXTURES/cli-archive.tar.gz" -C "$FIXTURES/cli-src" multica
CLI_ARCHIVE_SHA="$(sha256sum "$FIXTURES/cli-archive.tar.gz" | awk '{ print $1 }')"

# Stand-in for the reviewed self-hosted CLI updater. It is installed verbatim,
# so no case may rewrite its content.
cat >"$FIXTURES/approved-upgrade.sh" <<'STUB'
#!/usr/bin/env bash
# Fixture stand-in for the reviewed zzttzzmyswy/multica CLI updater.
# SELF_TAG="v0.9.0-myswy.2"
echo "approved upgrade script fixture"
STUB
chmod 750 "$FIXTURES/approved-upgrade.sh"
APPROVED_SHA="$(sha256sum "$FIXTURES/approved-upgrade.sh" | awk '{ print $1 }')"

cat >"$FIXTURES/compose-live.yml" <<YAML
# Live compose file, as recorded before the switch.
services:
  postgres:
    image: pgvector/pgvector:pg16
    environment:
      POSTGRES_DB: multica
  backend:
    image: ${BACKEND_IMAGE_OLD}
    environment:
      DATABASE_URL: postgres://multica:secret@postgres:5432/multica?sslmode=disable
  frontend:
    image: ${WEB_IMAGE_OLD}
    environment:
      BACKEND_URL: http://backend:8080
YAML

sed -e "s|$BACKEND_IMAGE_OLD|$BACKEND_IMAGE_NEW|" \
    -e "s|$WEB_IMAGE_OLD|$WEB_IMAGE_NEW|" \
    "$FIXTURES/compose-live.yml" >"$FIXTURES/compose-new.yml"

# ---------------------------------------------------------------------------
# Sandbox
# ---------------------------------------------------------------------------
new_case() {
    local name=$1
    shift
    CUR="$TMP/case-$name"
    CUR_CONFIG="$CUR/maintenance.conf"
    rm -rf "$CUR"
    mkdir -p "$CUR/state/units" "$CUR/state/containers" "$CUR/state/opt" \
        "$CUR/scripts" "$CUR/compose" "$CUR/backup" "$CUR/state-dir" "$CUR/work" "$CUR/cli-bin"
    : >"$CUR/state/calls.log"
    : >"$CUR/state/exec.log"
    : >"$CUR/state/compose.log"

    set_unit multica-daemon active
    set_unit multica-upgrade.timer active
    set_unit multica-upgrade.service inactive
    set_unit multica-attachment-gc.timer active
    set_unit multica-attachment-gc.service inactive
    set_container multica-backend-1 "$BACKEND_IMAGE_OLD"
    set_container multica-frontend-1 "$WEB_IMAGE_OLD"

    cp "$FIXTURES/compose-live.yml" "$CUR/compose/docker-compose.yml"
    cp "$FIXTURES/compose-new.yml" "$CUR/compose/docker-compose.approved.yml"
    cp "$FIXTURES/cli-archive.tar.gz" "$CUR/multica-cli.tar.gz"
    cp "$FIXTURES/approved-upgrade.sh" "$CUR/approved-upgrade-multica.sh"
    cat >"$CUR/scripts/upgrade-multica.sh" <<'STUB'
#!/usr/bin/env bash
# Pre-change (upstream) upgrade script.
echo "upstream upgrade script"
STUB
    chmod 750 "$CUR/scripts/upgrade-multica.sh"
    write_cli "$CUR/cli-bin/multica" "$CLI_VERSION_OLD"

    # The upgrade unit executes the maintained script by default.
    printf '%s\n' "$CUR/scripts/upgrade-multica.sh" >"$CUR/state/opt/execstart"

    local spec
    for spec in "$@"; do
        set_unit "${spec%%=*}" "${spec#*=}"
    done
    write_config
}

set_unit() { printf '%s\n' "$2" >"$CUR/state/units/$1.state"; }

set_container() {
    printf '%s\n' "$2" >"$CUR/state/containers/$1.image"
    printf 'running\n' >"$CUR/state/containers/$1.status"
    printf 'true\n' >"$CUR/state/containers/$1.running"
}

# stub_opt <name> [value] — sets (or with no value, clears) one stub behaviour.
stub_opt() {
    local name=$1
    if [ $# -lt 2 ]; then
        rm -f "$CUR/state/opt/$name"
    else
        printf '%s\n' "$2" >"$CUR/state/opt/$name"
    fi
}

write_config() {
    {
        printf 'COMPOSE_DIR=%s\n' "$CUR/compose"
        printf 'COMPOSE_FILE=%s\n' "$CUR/compose/docker-compose.yml"
        printf 'COMPOSE_FILE_NEW=%s\n' "$CUR/compose/docker-compose.approved.yml"
        printf 'PROJECT=multica\n'
        printf 'DOCKER_NETWORK=multica-net\n'
        printf 'PG_CONTAINER=pgvector-pgvector\n'
        printf 'PG_USER=multica\n'
        printf 'PG_DATABASE=multica\n'
        printf 'BACKEND_CONTAINER=multica-backend-1\n'
        printf 'FRONTEND_CONTAINER=multica-frontend-1\n'
        printf 'DAEMON_UNIT=multica-daemon\n'
        printf 'UPGRADE_TIMER=multica-upgrade.timer\n'
        printf 'GC_TIMER=multica-attachment-gc.timer\n'
        printf 'BACKEND_URL=http://127.0.0.1:8080/health\n'
        printf 'CLI_BIN=%s\n' "$CUR/cli-bin/multica"
        printf 'UPGRADE_SCRIPT=%s\n' "$CUR/scripts/upgrade-multica.sh"
        printf 'CLI_ARCHIVE=%s\n' "$CUR/multica-cli.tar.gz"
        printf 'APPROVED_UPGRADE_SCRIPT=%s\n' "$CUR/approved-upgrade-multica.sh"
        printf 'STATE_DIR=%s\n' "$CUR/state-dir"
        printf 'LOG=%s\n' "$CUR/maintenance.log"
        printf 'BACKUP_DIR=%s\n' "$CUR/backup"
        printf 'CLI_ARCHIVE_SHA256=%s\n' "$CLI_ARCHIVE_SHA"
        printf 'APPROVED_UPGRADE_SHA256=%s\n' "$APPROVED_SHA"
        printf 'STOP_TIMEOUT=10\nBACKUP_TIMEOUT=20\nTOC_TIMEOUT=10\nMIGRATE_TIMEOUT=20\n'
        printf 'UP_TIMEOUT=20\nHEALTH_TIMEOUT=3\nQUERY_TIMEOUT=10\nPROBE_TIMEOUT=10\n'
        local spec
        for spec in "$@"; do printf '%s\n' "$spec"; done
    } >"$CUR_CONFIG"
}

CUR_CONFIG=""

# run_script [args...] — runs the executor with only the stubs on PATH.
run_script() {
    OUT="$(env -i \
        PATH="$STUBS:/usr/bin:/bin" \
        HOME="$CUR" \
        TB="$CUR" \
        TMPDIR="$CUR/work" \
        bash "$EXECUTOR" "$@" 2>&1)"
    RC=$?
}

prepare_ok() {
    run_script prepare --config "$CUR_CONFIG"
    if [ "$RC" = 0 ]; then
        ok "prepare succeeded"
        return 0
    fi
    bad "prepare exited $RC: $(printf '%s' "$OUT" | tr '\n' '|' | cut -c1-500)"
    return 1
}

# ---------------------------------------------------------------------------
# Assertions
# ---------------------------------------------------------------------------
journal_get() {
    [ -f "$CUR/state-dir/journal" ] || return 1
    awk -v k="$1=" 'index($0, k) == 1 { v = substr($0, length(k) + 1); found = 1 }
                    END { if (!found) exit 1; print v }' "$CUR/state-dir/journal"
}

expect_rc() {
    if [ "$RC" = "$1" ]; then
        ok "exit $1"
    else
        bad "exit $RC, expected $1; output: $(printf '%s' "$OUT" | tr '\n' '|' | cut -c1-500)"
    fi
}

expect_log() {
    if printf '%s' "$OUT" | grep -qE -- "$1"; then
        ok "${2:-matches /$1/}"
    else
        bad "expected output matching /$1/; got: $(printf '%s' "$OUT" | tr '\n' '|' | cut -c1-500)"
    fi
}

expect_no_log() {
    if printf '%s' "$OUT" | grep -qE -- "$1"; then
        bad "${2:-no /$1/} (matched /$1/): $(printf '%s' "$OUT" | tr '\n' '|' | cut -c1-400)"
    else
        ok "${2:-no /$1/}"
    fi
}

expect_journal() {
    local got
    got="$(journal_get "$1" 2>/dev/null)"
    if [ "$got" = "$2" ]; then
        ok "journal $1=$2"
    else
        bad "journal $1='$got', expected '$2'"
    fi
}

expect_no_journal() {
    if journal_get "$1" >/dev/null 2>&1; then
        bad "journal unexpectedly holds $1=$(journal_get "$1")"
    else
        ok "journal has no $1"
    fi
}

expect_unit() {
    local got
    got="$(cat "$CUR/state/units/$1.state" 2>/dev/null || printf 'inactive')"
    if [ "$got" = "$2" ]; then
        ok "$1 is $2"
    else
        bad "$1 is '$got', expected '$2'"
    fi
}

expect_container_image() {
    local got
    got="$(cat "$CUR/state/containers/$1.image" 2>/dev/null)"
    if [ "$got" = "$2" ]; then
        ok "$1 runs $(printf '%s' "$2" | sed 's/.*@//')"
    else
        bad "$1 runs '$got', expected '$2'"
    fi
}

expect_sha() {
    local got
    got="$(sha256sum "$1" 2>/dev/null | awk '{ print $1 }')"
    if [ "$got" = "$2" ]; then
        ok "$(basename "$1") has the expected content"
    else
        bad "$1 sha256=$got, expected $2"
    fi
}

# expect_order <first> <second> — the first logged call must precede the second.
# Ordering is the whole point: a backup taken before the writers stop is not a
# consistent backup, whatever the exit code says.
expect_order() {
    local a b
    a=$(grep -nE -- "$1" "$CUR/state/calls.log" | head -1 | cut -d: -f1)
    b=$(grep -nE -- "$2" "$CUR/state/calls.log" | head -1 | cut -d: -f1)
    if [ -z "$a" ]; then
        bad "no call matched /$1/"
    elif [ -z "$b" ]; then
        bad "no call matched /$2/"
    elif [ "$a" -lt "$b" ]; then
        ok "/$1/ precedes /$2/"
    else
        bad "/$1/ (line $a) did not precede /$2/ (line $b)"
    fi
}

expect_no_call() {
    if grep -qE -- "$1" "$CUR/state/calls.log" 2>/dev/null; then
        bad "${2:-no /$1/}: $(grep -E -- "$1" "$CUR/state/calls.log" | head -3 | tr '\n' '|')"
    else
        ok "${2:-no /$1/}"
    fi
}

expect_no_restore() {
    if [ -s "$CUR/state/restore.log" ]; then
        bad "pg_restore ran against the live database: $(head -1 "$CUR/state/restore.log")"
    else
        ok "no pg_restore ran against the live database"
    fi
}

# world_post_switch — the state a completed switch+cli leaves behind, with the
# daemon still stopped, and the journal pointed at the verify stage. Isolating
# verify this way means only what verify observes can decide its outcome.
world_post_switch() {
    set_container multica-backend-1 "$BACKEND_IMAGE_NEW"
    set_container multica-frontend-1 "$WEB_IMAGE_NEW"
    write_cli "$CUR/cli-bin/multica" "$CLI_VERSION_NEW"
    printf '%s\n' 660_attachment_upload_session_workspace >"$CUR/state/ledger"
    printf '684\n' >"$CUR/state/ledger_rows"
    printf '148\n' >"$CUR/state/tables"
    printf '799/0/0\n' >"$CUR/state/indexes"
    sed -i 's/^stage=prepared/stage=cli/' "$CUR/state-dir/journal"
    set_unit multica-daemon inactive
    set_unit multica-upgrade.timer inactive
    set_unit multica-attachment-gc.timer inactive
}

dump_count() { find "$CUR/backup" -name '*.dump' 2>/dev/null | wc -l | tr -d ' '; }

# mark_calls — everything logged after this point is "since the mark".
mark_calls() { printf 'MARK %s\n' "${1:-mark}" >>"$CUR/state/calls.log"; }

calls_since_mark() {
    awk 'f { print } /^MARK / { f = 1 }' "$CUR/state/calls.log"
}

expect_no_call_since_mark() {
    local hits
    hits=$(calls_since_mark | grep -E -- "$1" || true)
    if [ -n "$hits" ]; then
        bad "${2:-no /$1/ since the mark}: $(printf '%s' "$hits" | head -3 | tr '\n' '|')"
    else
        ok "${2:-no /$1/ since the mark}"
    fi
}

# ---------------------------------------------------------------------------
step "A bare invocation is safe and changes nothing"
new_case surface
run_script
expect_rc 2
expect_log 'usage: nas-maintenance.sh' 'prints usage'
if [ -e "$CUR/state-dir/journal" ]; then bad "a bare invocation wrote a journal"; else ok "no journal was written"; fi
if [ -s "$CUR/state/calls.log" ]; then
    bad "a bare invocation touched the host: $(head -3 "$CUR/state/calls.log" | tr '\n' '|')"
else
    ok "no systemctl or docker call"
fi

run_script status
expect_rc 0
expect_log 'no journal yet' 'status reports an empty journal'
expect_log 'units:.*daemon=active' 'status reports the real unit state'
expect_log 'containers: backend=running' 'status reports the real container state'

step "Write commands refuse to guess a production path"
new_case no-config
run_script prepare
expect_rc 2
expect_log 'requires --config' 'prepare demands an explicit config'
run_script run --config "$CUR_CONFIG"
expect_rc 2
expect_log 'requires --intent=switch' 'run demands an explicit intent'
run_script run --intent=other --config "$CUR_CONFIG"
expect_rc 2
expect_log 'nothing was changed' 'an unknown intent refuses without acting'
if [ -s "$CUR/state/calls.log" ]; then
    bad "a refused invocation still touched the host: $(head -3 "$CUR/state/calls.log" | tr '\n' '|')"
else
    ok "the host was never touched"
fi

step "An incomplete or unknown config is refused, never defaulted"
new_case bad-config
sed -e '/^COMPOSE_FILE_NEW=/d' "$CUR_CONFIG" >"$CUR/partial.conf"
run_script prepare --config "$CUR/partial.conf"
expect_rc 2
expect_log 'missing: COMPOSE_FILE_NEW' 'names the missing setting'
write_config 'NONSENSE_KEY=1'
run_script prepare --config "$CUR_CONFIG"
expect_rc 2
expect_log 'unknown key NONSENSE_KEY' 'rejects an unknown key'
write_config 'COMPOSE_FILE=relative/path.yml'
run_script prepare --config "$CUR_CONFIG"
expect_rc 2
expect_log 'COMPOSE_FILE must be an absolute path' 'rejects a relative compose path'
write_config
if [ -s "$CUR/state/calls.log" ]; then bad "a refused config still touched the host"; else ok "no host call before the config is valid"; fi

step "prepare stages assets and snapshots state without stopping anything"
new_case prepare-ok
prepare_ok
expect_journal stage prepared
expect_journal initial_compose_sha256 "$(sha256sum "$CUR/compose/docker-compose.yml" | awk '{ print $1 }')"
expect_journal initial_cli_sha256 "$(sha256sum "$CUR/cli-bin/multica" | awk '{ print $1 }')"
expect_journal initial_cli_version "$CLI_VERSION_OLD"
expect_journal initial_upgrade_script_sha256 "$(sha256sum "$CUR/scripts/upgrade-multica.sh" | awk '{ print $1 }')"
expect_journal initial_upgrade_script_mode 750
expect_journal initial_backend_digest "$BACKEND_DIGEST_OLD"
expect_journal initial_web_digest "$WEB_DIGEST_OLD"
expect_journal initial_daemon_state active
expect_journal initial_upgrade_timer_state active
expect_journal initial_upgrade_service_state inactive
expect_journal cli_binary_sha256 "$(sha256sum "$CUR/state-dir/assets/cli/unpack/multica" | awk '{ print $1 }')"
expect_journal approved_upgrade_sha256 "$APPROVED_SHA"
expect_no_call 'systemctl stop' 'no unit was stopped'
expect_no_call 'systemctl start' 'no unit was started'
expect_no_call 'compose .* up' 'no container was created'
expect_no_call 'exec .* pg_dump' 'no backup was taken'
expect_sha "$CUR/compose/docker-compose.yml" "$(sha256sum "$FIXTURES/compose-live.yml" | awk '{ print $1 }')"
expect_sha "$CUR/state-dir/assets/compose/docker-compose.initial.yml" "$(sha256sum "$FIXTURES/compose-live.yml" | awk '{ print $1 }')"

step "prepare refuses a CLI archive whose hash is wrong"
new_case cli-hash
write_config 'CLI_ARCHIVE_SHA256=0000000000000000000000000000000000000000000000000000000000000000'
run_script prepare --config "$CUR_CONFIG"
expect_rc 20
expect_log 'CLI archive sha256 mismatch' 'names the archive hash'
expect_no_journal stage
if [ "$(dump_count)" = 0 ]; then ok "no backup written"; else bad "a backup was written"; fi

step "prepare refuses a CLI archive with the wrong version"
new_case cli-version
write_cli "$FIXTURES/cli-src/multica" "0.9.0-myswy.1"
tar -czf "$CUR/multica-cli.tar.gz" -C "$FIXTURES/cli-src" multica
write_cli "$FIXTURES/cli-src/multica" "$CLI_VERSION_NEW"
write_config "CLI_ARCHIVE_SHA256=$(sha256sum "$CUR/multica-cli.tar.gz" | awk '{ print $1 }')"
run_script prepare --config "$CUR_CONFIG"
expect_rc 20
expect_log 'staged CLI reports version .0.9.0-myswy.1.' 'refuses the wrong build'

step "prepare refuses an upgrade script that is not the approved one"
new_case script-hash
printf '\n# tampered\n' >>"$CUR/approved-upgrade-multica.sh"
run_script prepare --config "$CUR_CONFIG"
expect_rc 20
expect_log 'approved upgrade script sha256 mismatch' 'names the script hash'

step "prepare refuses when a .2 image is not on the box"
new_case missing-image
stub_opt missing-images "$BACKEND_DIGEST_NEW"
run_script prepare --config "$CUR_CONFIG"
expect_rc 20
expect_log 'is not present locally' 'refuses to switch to an unpulled image'
expect_no_call 'compose .* up' 'pulls nothing and creates nothing'

step "prepare refuses a compose input that changes anything but the images"
new_case compose-drift
sed -i 's/POSTGRES_DB: multica/POSTGRES_DB: other/' "$CUR/compose/docker-compose.approved.yml"
run_script prepare --config "$CUR_CONFIG"
expect_rc 20
expect_log 'differs from the live file outside image lines' 'refuses a broader config change'

step "prepare refuses a compose input without the exact .2 digests"
new_case compose-no-pin
sed -i "s|$BACKEND_IMAGE_NEW|ghcr.io/zzttzzmyswy/multica-backend@sha256:1111111111111111111111111111111111111111111111111111111111111111|" \
    "$CUR/compose/docker-compose.approved.yml"
run_script prepare --config "$CUR_CONFIG"
expect_rc 20
expect_log 'does not pin the backend .2 digest' 'refuses an unpinned backend'

step "prepare refuses a live compose file that already runs .2"
new_case already-switched
cp "$FIXTURES/compose-new.yml" "$CUR/compose/docker-compose.yml"
set_container multica-backend-1 "$BACKEND_IMAGE_NEW"
set_container multica-frontend-1 "$WEB_IMAGE_NEW"
run_script prepare --config "$CUR_CONFIG"
expect_rc 20
expect_log 'already references the .2 backend digest' 'refuses to snapshot a switched host'

step "prepare refuses a host that is not on the validated rollback baseline"
new_case wrong-digest
set_container multica-backend-1 "ghcr.io/zzttzzmyswy/multica-backend@sha256:9999999999999999999999999999999999999999999999999999999999999999"
run_script prepare --config "$CUR_CONFIG"
expect_rc 20
expect_log 'expected the pre-change pin' 'refuses an unexpected running image'

step "prepare refuses a schema, table or index baseline that drifted"
new_case wrong-ledger
printf '620_something_else\n' >"$CUR/state/ledger"
run_script prepare --config "$CUR_CONFIG"
expect_rc 20
expect_log 'expected the pre-change 616_member_pinned' 'refuses an unexpected schema'

new_case baseline-drift
printf '130\n' >"$CUR/state/tables"
run_script prepare --config "$CUR_CONFIG"
expect_rc 20
expect_log 'baseline is rows=640 tables=130 indexes=740/0/0' 'refuses a drifted baseline'

new_case baseline-invalid-index
printf '740/2/0\n' >"$CUR/state/indexes"
run_script prepare --config "$CUR_CONFIG"
expect_rc 20
expect_log 'baseline is rows=640 tables=131 indexes=740/2/0' 'refuses an invalid index on the base'

step "prepare refuses a unit in a transitional state"
new_case transitional
set_unit multica-upgrade.timer activating
run_script prepare --config "$CUR_CONFIG"
expect_rc 20
expect_log 'no stable state to restore' 'refuses to guess a restore target'

step "prepare refuses while a timer job is still running"
new_case inflight-timer-job
set_unit multica-upgrade.service active
run_script prepare --config "$CUR_CONFIG"
expect_rc 20
expect_log 'is running; a timer job is in flight' 'refuses to freeze a half-finished upgrade'
expect_no_call 'systemctl stop' 'stops nothing'

step "prepare refuses a unit whose entry point is not the maintained script"
new_case wrong-execstart
stub_opt execstart-units multica-upgrade.service
run_script prepare --config "$CUR_CONFIG"
expect_rc 20
expect_log 'does not execute' 'refuses to install a script no unit runs'

step "prepare needs no network and no python"
new_case no-network
if grep -nE 'releases/download|python[0-9]?|wget' "$EXECUTOR" | grep -vE ':[[:space:]]*#' >/dev/null; then
    bad "the executor downloads a release or shells out to python: $(grep -nE 'releases/download|python[0-9]?|wget' "$EXECUTOR" | head -2)"
else
    ok "the executor downloads nothing and needs no python"
fi
prepare_ok
expect_no_call 'curl' 'prepare probes no endpoint'
expect_no_call 'docker run' 'prepare runs no container'

step "Re-running prepare keeps the original snapshot"
new_case prepare-twice
prepare_ok
snapshot_compose="$(journal_get initial_compose_sha256)"
snapshot_cli="$(journal_get initial_cli_sha256)"
write_cli "$CUR/cli-bin/multica" "$CLI_VERSION_NEW"
run_script prepare --config "$CUR_CONFIG"
expect_rc 0
expect_log 'keeping the original snapshot' 'says the snapshot is kept'
expect_journal initial_compose_sha256 "$snapshot_compose"
expect_journal initial_cli_sha256 "$snapshot_cli"

step "prepare refuses once maintenance has started"
new_case prepare-after-run
prepare_ok
sed -i 's/^stage=prepared/stage=frozen/' "$CUR/state-dir/journal"
run_script prepare --config "$CUR_CONFIG"
expect_rc 80
expect_log 'initial snapshot must not be replaced' 'refuses to overwrite a live snapshot'

step "freeze stops every writer before the backup is taken"
new_case freeze-order
prepare_ok
run_script run --intent=switch --config "$CUR_CONFIG"
expect_rc 0
expect_order 'systemctl stop multica-upgrade.timer' 'systemctl stop multica-upgrade.service'
expect_order 'systemctl stop multica-upgrade.service' 'systemctl stop multica-daemon'
expect_order 'systemctl stop multica-attachment-gc.timer' 'systemctl stop multica-daemon'
expect_order 'systemctl stop multica-daemon' 'compose .* stop backend frontend'
expect_order 'compose .* stop backend frontend' 'exec .* pg_dump'

step "freeze refuses to call a live database frozen"
new_case freeze-backend-live
prepare_ok
stub_opt stop-ignore-container multica-backend-1
run_script run --intent=switch --config "$CUR_CONFIG"
expect_rc 30
expect_log 'multica-backend-1 is still running' 'names the container that did not stop'
expect_log 'writes are not frozen' 'does not claim a freeze'
expect_no_log 'writes frozen' 'never prints the frozen boundary'
expect_no_call 'exec .* pg_dump' 'no backup was taken'
expect_no_journal backup_path

step "freeze treats a failing unit stop as a failure"
new_case freeze-stop-fails
prepare_ok
stub_opt stop-fail-unit multica-upgrade.timer
run_script run --intent=switch --config "$CUR_CONFIG"
expect_rc 30
expect_log "systemctl stop multica-upgrade.timer' failed" 'names the failing stop'
expect_no_call 'exec .* pg_dump' 'no backup was taken'

step "freeze refuses a stop that returns zero but leaves the unit active"
new_case freeze-stop-ignored
prepare_ok
stub_opt stop-ignore-unit multica-attachment-gc.timer
run_script run --intent=switch --config "$CUR_CONFIG"
expect_rc 30
expect_log 'multica-attachment-gc.timer is still .active. after stop' 'reads the state back instead of trusting exit 0'
expect_no_journal backup_path

step "freeze refuses a unit left mid-transition"
new_case freeze-stop-deactivating
prepare_ok
stub_opt stop-transition-unit multica-daemon
run_script run --intent=switch --config "$CUR_CONFIG"
expect_rc 30
expect_log 'multica-daemon is still .deactivating. after stop' 'refuses a transitional state'
expect_no_call 'exec .* pg_dump' 'no backup was taken'

step "freeze refuses when the container stop command fails"
new_case freeze-compose-stop-fails
prepare_ok
stub_opt compose-stop-rc 1
run_script run --intent=switch --config "$CUR_CONFIG"
expect_rc 30
expect_log "docker compose stop backend frontend' failed" 'reports the compose stop failure'
expect_no_call 'exec .* pg_dump' 'no backup was taken'

step "a failed dump leaves no backup and keeps writers stopped"
new_case backup-fail
prepare_ok
stub_opt dump-rc 1
run_script run --intent=switch --config "$CUR_CONFIG"
expect_rc 30
expect_log 'pg_dump exit=1' 'reports the dump exit'
expect_no_journal backup_path
if [ "$(dump_count)" = 0 ]; then ok "no partial dump left behind"; else bad "a partial dump was left behind"; fi
expect_unit multica-daemon inactive

step "a dump whose TOC cannot be parsed is not a backup"
new_case backup-toc-fail
prepare_ok
stub_opt toc-rc 1
stub_opt toc-lines 500
run_script run --intent=switch --config "$CUR_CONFIG"
expect_rc 30
expect_log 'pg_restore -l exit=1' 'reports the TOC exit, not only the line count'
expect_no_log 'backup ok' 'never calls it a backup'
expect_no_journal backup_path

step "a dump with too few TOC entries is not a backup"
new_case backup-tiny
prepare_ok
stub_opt toc-lines 12
run_script run --intent=switch --config "$CUR_CONFIG"
expect_rc 30
expect_log 'TOC entries; the dump is not usable' 'rejects an implausibly small TOC'
expect_journal stage frozen

step "a recorded backup matches the bytes on disk"
new_case backup-recorded
prepare_ok
stub_opt health-never 1
run_script run --intent=switch --config "$CUR_CONFIG"
expect_rc 50
expect_journal backup_sha256 "$(sha256sum "$(journal_get backup_path)" | awk '{ print $1 }')"
expect_journal backup_bytes "$(stat -c '%s' "$(journal_get backup_path)")"
expect_no_log 'writes are not frozen' 'the freeze itself succeeded'
if [ "$(dump_count)" = 1 ]; then ok "exactly one dump exists"; else bad "$(dump_count) dumps exist"; fi

step "migrate runs only the exact image's migrate"
new_case migrate-image
prepare_ok
run_script run --intent=switch --config "$CUR_CONFIG"
expect_rc 0
if grep -q '/app/migrate' "$CUR/state/migrate.log" 2>/dev/null; then
    ok "runs /app/migrate"
else
    bad "migrate was not run through /app/migrate: $(cat "$CUR/state/migrate.log" 2>/dev/null)"
fi
if grep -q "$BACKEND_DIGEST_NEW" "$CUR/state/migrate.log" 2>/dev/null; then
    ok "migrate uses the exact .2 backend image"
else
    bad "migrate did not use the pinned image: $(cat "$CUR/state/migrate.log" 2>/dev/null)"
fi
if grep -qE 'server|worker' "$CUR/state/migrate.log" 2>/dev/null; then
    bad "migrate started the application: $(cat "$CUR/state/migrate.log")"
else
    ok "migrate starts no server or worker"
fi

step "a failing migration preserves the site and stops"
new_case migrate-fail
prepare_ok
stub_opt migrate-rc 1
run_script run --intent=switch --config "$CUR_CONFIG"
expect_rc 40
expect_log 'MIGRATION FAILED' 'reports the failure'
expect_log 'no claim that an intermediate schema is recoverable' 'refuses to promise a recoverable middle state'
expect_journal stage backup
expect_no_call 'compose .* up' 'no application was started'
expect_no_restore

step "a migration leaving a partial ledger does not continue"
new_case migrate-partial-ledger
prepare_ok
stub_opt partial-ledger 640_somewhere_in_the_middle
stub_opt migrate-rc 40
run_script run --intent=switch --config "$CUR_CONFIG"
expect_rc 40
expect_log 'Real state: ledger=640_somewhere_in_the_middle' 'reports the real ledger'
expect_no_call 'compose .* up' 'does not continue onto a partial schema'

step "a migration with the right ledger but the wrong shape does not continue"
new_case migrate-wrong-shape
prepare_ok
stub_opt tables-after 131
stub_opt indexes-after 740/0/0
run_script run --intent=switch --config "$CUR_CONFIG"
expect_rc 40
expect_log 'table count is .131., expected 148' 'checks the shape, not only the ledger'
expect_no_call 'compose .* up' 'does not switch onto the wrong shape'

new_case migrate-wrong-rows
prepare_ok
stub_opt rows-after 660
run_script run --intent=switch --config "$CUR_CONFIG"
expect_rc 40
expect_log 'ledger row count is .660., expected 684' 'checks the ledger row count'

new_case migrate-invalid-index
prepare_ok
stub_opt indexes-after 799/3/0
run_script run --intent=switch --config "$CUR_CONFIG"
expect_rc 40
expect_log 'index state is .799/3/0.' 'rejects an invalid index'

step "a candidate with an empty or wrong commit is not healthy"
new_case health-empty-commit
prepare_ok
stub_opt health-commit ""
run_script run --intent=switch --config "$CUR_CONFIG"
expect_rc 50
expect_no_log 'commit=, ' 'never reports an empty commit as accepted'
expect_journal stage migrated

new_case health-wrong-commit
prepare_ok
stub_opt health-commit 0000000000000000000000000000000000000000
run_script run --intent=switch --config "$CUR_CONFIG"
expect_rc 50
expect_log "candidate reports commit '0000000" 'names the wrong revision'

step "a candidate that never answers times out instead of hanging"
new_case health-timeout
prepare_ok
stub_opt health-never 1
start=$(date +%s)
run_script run --intent=switch --config "$CUR_CONFIG"
elapsed=$(( $(date +%s) - start ))
expect_rc 50
expect_log 'within 3s' 'reports the bounded wait'
if [ "$elapsed" -le 90 ]; then ok "the wait was bounded (${elapsed}s)"; else bad "the wait was unbounded (${elapsed}s)"; fi

step "a candidate that comes up on an unexpected digest is rejected"
new_case unknown-build
prepare_ok
# The approved compose input pins .2, but the daemon brings the container up on
# another image, so /health cannot report the .2 revision.
stub_opt up-image-backend "ghcr.io/zzttzzmyswy/multica-backend@sha256:3333333333333333333333333333333333333333333333333333333333333333"
run_script run --intent=switch --config "$CUR_CONFIG"
expect_rc 50
expect_log 'no candidate answered' 'waits for a candidate that reports a commit'
expect_no_log 'candidate ok' 'never accepts the unpinned candidate'

step "a candidate that comes up on the old digest is rejected"
new_case old-digest-candidate
prepare_ok
stub_opt up-image-backend "$BACKEND_IMAGE_OLD"
run_script run --intent=switch --config "$CUR_CONFIG"
expect_rc 50
expect_log "candidate reports commit '$REV_OLD'" 'names the revision it actually saw'
expect_no_log 'candidate ok' 'never accepts the pre-change build'

step "the switch is accepted only on the exact revision, digest and frontend"
new_case switch-accepted
prepare_ok
run_script run --intent=switch --config "$CUR_CONFIG"
expect_rc 0
expect_log "candidate ok: commit=$REV_NEW" 'reports the exact revision'
expect_container_image multica-backend-1 "$BACKEND_IMAGE_NEW"
expect_container_image multica-frontend-1 "$WEB_IMAGE_NEW"
expect_sha "$CUR/compose/docker-compose.yml" "$(sha256sum "$FIXTURES/compose-new.yml" | awk '{ print $1 }')"

new_case compose-up-fails
prepare_ok
stub_opt compose-rc 1
run_script run --intent=switch --config "$CUR_CONFIG"
expect_rc 50
expect_log 'compose up exit=1' 'reports the compose failure'

step "the CLI is installed and verified by hash and version, then the approved script"
new_case cli-install
prepare_ok
expected_bin_sha="$(journal_get cli_binary_sha256)"
run_script run --intent=switch --config "$CUR_CONFIG"
expect_rc 0
expect_sha "$CUR/cli-bin/multica" "$expected_bin_sha"
expect_sha "$CUR/scripts/upgrade-multica.sh" "$APPROVED_SHA"
if [ "$(stat -c '%a' "$CUR/scripts/upgrade-multica.sh")" = 750 ]; then
    ok "the upgrade script keeps its 750 mode"
else
    bad "the upgrade script mode is $(stat -c '%a' "$CUR/scripts/upgrade-multica.sh"), expected 750"
fi
expect_log "CLI installed: version=$CLI_VERSION_NEW" 'reports the verified version'
expect_log 'unit entry point verified' 'checks the unit actually runs the script'
if grep -q 'multica-cli' "$CUR/state/calls.log" 2>/dev/null; then
    bad "the CLI was downloaded instead of using the staged archive"
else
    ok "the CLI came from the staged archive, not the network"
fi

step "a staged CLI that changed after prepare is not installed"
new_case cli-tampered
prepare_ok
printf '#!/usr/bin/env bash\nprintf "multica %s (commit: deadbee, built: 2026-01-01T00:00:00Z)\\n"\n' "$CLI_VERSION_NEW" \
    >"$CUR/state-dir/assets/cli/unpack/multica"
chmod 755 "$CUR/state-dir/assets/cli/unpack/multica"
run_script run --intent=switch --config "$CUR_CONFIG"
expect_rc 60
expect_log 'staged CLI hash changed since prepare' 'refuses a mutated staged binary'
expect_sha "$CUR/cli-bin/multica" "$(sha256sum "$CUR/state-dir/assets/previous/multica" | awk '{ print $1 }')"

step "an upgrade unit repointed between prepare and run fails the CLI step"
new_case cli-wrong-unit
prepare_ok
stub_opt execstart-units multica-upgrade.service
run_script run --intent=switch --config "$CUR_CONFIG"
expect_rc 60
expect_log 'does not execute' 'refuses an unverified unit entry point'
expect_sha "$CUR/scripts/upgrade-multica.sh" "$(journal_get initial_upgrade_script_sha256)"

step "verify re-reads the schema and the CLI instead of trusting the earlier steps"
new_case verify-ok
prepare_ok
world_post_switch
run_script run --intent=switch --config "$CUR_CONFIG"
expect_rc 0
expect_log 'maintenance complete' 'accepts a genuinely complete switch'

new_case verify-wrong-shape
prepare_ok
world_post_switch
printf '131\n' >"$CUR/state/tables"
run_script run --intent=switch --config "$CUR_CONFIG"
expect_rc 40
expect_log 'MISMATCH: tables' 'rejects the old table count'
expect_no_log 'maintenance complete' 'never claims completion'

new_case verify-wrong-index
prepare_ok
world_post_switch
printf '799/2/0\n' >"$CUR/state/indexes"
run_script run --intent=switch --config "$CUR_CONFIG"
expect_rc 40
expect_log 'MISMATCH: indexes' 'rejects an invalid index'

new_case verify-wrong-ledger
prepare_ok
world_post_switch
printf '616_member_pinned\n' >"$CUR/state/ledger"
run_script run --intent=switch --config "$CUR_CONFIG"
expect_rc 40
expect_log 'MISMATCH: ledger' 'rejects an unmigrated ledger'

new_case verify-wrong-cli
prepare_ok
world_post_switch
write_cli "$CUR/cli-bin/multica" "$CLI_VERSION_OLD"
run_script run --intent=switch --config "$CUR_CONFIG"
expect_rc 60
expect_log 'MISMATCH: cli version' 'rejects a CLI that is not the pinned build'
expect_no_log 'maintenance complete' 'never claims completion'

new_case verify-daemon-running
prepare_ok
world_post_switch
set_unit multica-daemon active
run_script run --intent=switch --config "$CUR_CONFIG"
expect_rc 30
expect_log 'MISMATCH: daemon is active before thaw' 'refuses to verify with the daemon live'

step "restoring an initially inactive unit keeps it inactive"
new_case thaw-inactive
set_unit multica-daemon inactive
set_unit multica-upgrade.timer inactive
set_unit multica-attachment-gc.timer inactive
prepare_ok
run_script run --intent=switch --config "$CUR_CONFIG"
expect_rc 0
expect_unit multica-daemon inactive
expect_unit multica-upgrade.timer inactive
expect_unit multica-attachment-gc.timer inactive
expect_log 'correctly left' 'reports the units left as recorded'
expect_journal stage "done"
expect_no_call 'systemctl start multica-daemon' 'never starts a unit that was off'

step "a unit that does not come back fails the run"
new_case thaw-start-fails
prepare_ok
stub_opt start-fail-unit multica-daemon
run_script run --intent=switch --config "$CUR_CONFIG"
expect_rc 70
expect_log "systemctl start multica-daemon' failed" 'reports the failing start'
expect_log 'actual state' 'prints the real state'
expect_journal stage verified

step "a full switch runs from old state to final state and keeps the snapshot"
new_case full-switch
prepare_ok
snapshot_compose="$(journal_get initial_compose_sha256)"
snapshot_cli="$(journal_get initial_cli_sha256)"
snapshot_script="$(journal_get initial_upgrade_script_sha256)"
run_script run --intent=switch --config "$CUR_CONFIG"
expect_rc 0
expect_journal stage "done"
expect_journal initial_compose_sha256 "$snapshot_compose"
expect_journal initial_cli_sha256 "$snapshot_cli"
expect_journal initial_upgrade_script_sha256 "$snapshot_script"
expect_journal switched_commit "$REV_NEW"
expect_container_image multica-backend-1 "$BACKEND_IMAGE_NEW"
expect_container_image multica-frontend-1 "$WEB_IMAGE_NEW"
expect_unit multica-daemon active
expect_unit multica-upgrade.timer active
expect_unit multica-attachment-gc.timer active
expect_unit multica-upgrade.service inactive
expect_no_restore
if [ -f "$CUR/state-dir/assets/compose/docker-compose.initial.yml" ]; then
    ok "the pre-change compose file is still archived"
else
    bad "the pre-change compose snapshot is gone"
fi

step "rollback-r1 restores the exact old images, compose, CLI and script"
new_case r1-restores
prepare_ok
run_script run --intent=switch --config "$CUR_CONFIG"
if [ "$RC" != 0 ]; then bad "the switch did not complete; the rollback case cannot be trusted"; fi
snapshot_cli="$(journal_get initial_cli_sha256)"
snapshot_script="$(journal_get initial_upgrade_script_sha256)"
run_script rollback-r1 --config "$CUR_CONFIG"
expect_rc 0
expect_sha "$CUR/compose/docker-compose.yml" "$(sha256sum "$FIXTURES/compose-live.yml" | awk '{ print $1 }')"
expect_container_image multica-backend-1 "$BACKEND_IMAGE_OLD"
expect_container_image multica-frontend-1 "$WEB_IMAGE_OLD"
expect_sha "$CUR/cli-bin/multica" "$snapshot_cli"
expect_sha "$CUR/scripts/upgrade-multica.sh" "$snapshot_script"
if [ "$(stat -c '%a' "$CUR/scripts/upgrade-multica.sh")" = 750 ]; then
    ok "the restored upgrade script keeps its mode"
else
    bad "the restored upgrade script mode is $(stat -c '%a' "$CUR/scripts/upgrade-multica.sh")"
fi
expect_unit multica-daemon active
expect_unit multica-upgrade.timer active
expect_no_restore
expect_journal stage rolled-back
expect_log "images restored: commit=$REV_OLD" 'reports the old revision it observed'
expect_no_log 'commit=8098fd3' 'never reports the new revision'

step "rollback-r1 rejects a backend that came back on the new revision"
new_case r1-new-commit
prepare_ok
run_script run --intent=switch --config "$CUR_CONFIG"
stub_opt health-commit "$REV_NEW"
run_script rollback-r1 --config "$CUR_CONFIG"
expect_rc 70
expect_log "expected the old revision $REV_OLD" 'names the expected old revision'

step "rollback-r1 fails rather than reporting success on a damaged snapshot"
new_case r1-cli-damaged
prepare_ok
run_script run --intent=switch --config "$CUR_CONFIG"
printf 'not-the-original-binary\n' >"$CUR/state-dir/assets/previous/multica"
run_script rollback-r1 --config "$CUR_CONFIG"
expect_rc 70
expect_log 'CLI snapshot no longer matches' 'detects the damaged CLI snapshot'

new_case r1-script-damaged
prepare_ok
run_script run --intent=switch --config "$CUR_CONFIG"
printf '# damaged\n' >"$CUR/state-dir/assets/previous/upgrade-multica.sh"
run_script rollback-r1 --config "$CUR_CONFIG"
expect_rc 70
expect_log 'upgrade script snapshot no longer matches' 'detects the damaged script snapshot'

new_case r1-compose-damaged
prepare_ok
run_script run --intent=switch --config "$CUR_CONFIG"
printf '\n# damaged\n' >>"$CUR/state-dir/assets/compose/docker-compose.initial.yml"
run_script rollback-r1 --config "$CUR_CONFIG"
expect_rc 70
expect_log 'snapshot compose file no longer matches' 'detects the damaged compose snapshot'

step "rollback-r1 fails when a unit cannot be restored"
new_case r1-services
prepare_ok
run_script run --intent=switch --config "$CUR_CONFIG"
stub_opt start-ignore-unit multica-upgrade.timer
run_script rollback-r1 --config "$CUR_CONFIG"
expect_rc 70
expect_log 'did not become active' 'reads the state back instead of trusting exit 0'

step "rollback-r1 refuses without a snapshot to restore from"
new_case r1-no-snapshot
run_script rollback-r1 --config "$CUR_CONFIG"
expect_rc 80
expect_log 'cannot restore a state that was never recorded' 'refuses to improvise'
expect_no_call 'compose .* up' 'changes nothing'

step "rollback-r2 is refused and only prints a read-only plan"
new_case r2-refused
prepare_ok
run_script run --intent=switch --config "$CUR_CONFIG"
mark_calls rollback-r2
run_script rollback-r2 --config "$CUR_CONFIG"
expect_rc 80
expect_log 'no destructive database rollback' 'refuses'
expect_log 'Create a NEW database' 'prints the recovery plan'
expect_log 'Keep the current database and volume untouched' 'states the preservation boundary'
expect_log 'separate, reviewed operation card' 'hands connection switching to its own approval'
expect_no_restore
expect_no_call_since_mark 'compose .* up' 'does not touch containers'
expect_no_call_since_mark 'systemctl (stop|start)' 'does not touch units'
if grep -qE 'down|--clean' "$CUR/state/migrate.log" 2>/dev/null; then
    bad "a destructive migrate or restore was attempted"
else
    ok "no migrate down and no --clean restore"
fi

step "rollback-r2 is refused even without any journal"
new_case r2-no-journal
run_script rollback-r2
expect_rc 80
expect_no_restore

step "one maintenance action cannot start while another holds the lock"
new_case lock-held
prepare_ok
flock "$CUR/state-dir/maintenance.lock" sleep 10 &
lock_pid=$!
sleep 0.3
run_script run --intent=switch --config "$CUR_CONFIG"
expect_rc 10
expect_log 'another maintenance action holds' 'refuses instead of queueing'
if [ "$(journal_get stage)" = prepared ]; then ok "the journal was left alone"; else bad "the blocked run changed the journal"; fi
kill "$lock_pid" 2>/dev/null
wait "$lock_pid" 2>/dev/null

step "status reads stage and log while maintenance holds the lock"
new_case status-during-run
prepare_ok
sed -i 's/^stage=prepared/stage=frozen/' "$CUR/state-dir/journal"
printf '[2026-01-01 00:00:00] running migrate\n' >>"$CUR/maintenance.log"
flock "$CUR/state-dir/maintenance.lock" sleep 10 &
lock_pid=$!
sleep 0.3
run_script status --config "$CUR_CONFIG"
expect_rc 0
expect_log 'stage:   frozen' 'reads the stage while the lock is held'
expect_log 'running migrate' 'tails the log while the lock is held'
kill "$lock_pid" 2>/dev/null
wait "$lock_pid" 2>/dev/null

step "a corrupt journal refuses every write command"
new_case corrupt-journal
prepare_ok
printf 'this-is-not-a-journal\n' >>"$CUR/state-dir/journal"
run_script run --intent=switch --config "$CUR_CONFIG"
expect_rc 80
expect_log 'journal corrupt' 'names the malformed line'
expect_log 'restore it from a copy' 'says what to do'
expect_no_call 'systemctl stop' 'stops nothing'

step "status still reports a corrupt journal without writing to it"
new_case corrupt-journal-status
prepare_ok
printf 'garbage\n' >>"$CUR/state-dir/journal"
run_script status --config "$CUR_CONFIG"
expect_rc 0
expect_log 'CORRUPT' 'flags the corruption'
expect_no_call 'systemctl stop' 'changes nothing'

step "a journal that cannot be written fails the command"
new_case journal-unwritable
prepare_ok
rm -f "$CUR/state-dir/journal"
mkdir -p "$CUR/state-dir/journal"
run_script prepare --config "$CUR_CONFIG"
expect_rc 20
expect_log 'is not a regular file' 'refuses to write through a non-file journal'

step "a journal from a different config refuses to continue"
new_case config-drift
prepare_ok
write_config 'PROJECT=other-project'
run_script run --intent=switch --config "$CUR_CONFIG"
expect_rc 80
expect_log 'prepared with a different config' 'refuses a changed config'
expect_no_call 'systemctl stop' 'changes nothing'

step "an unknown stage refuses to continue"
new_case unknown-stage
prepare_ok
sed -i 's/^stage=prepared/stage=sorcery/' "$CUR/state-dir/journal"
run_script run --intent=switch --config "$CUR_CONFIG"
expect_rc 80
expect_log "stage 'sorcery' is not a switch stage" 'refuses an unknown stage'

step "a run without prepare refuses"
new_case run-without-prepare
run_script run --intent=switch --config "$CUR_CONFIG"
expect_rc 80
expect_log 'run .prepare. first' 'says what is missing'
expect_no_call 'systemctl stop' 'changes nothing'

step "a completed maintenance is not repeated"
new_case already-done
prepare_ok
run_script run --intent=switch --config "$CUR_CONFIG"
run_script run --intent=switch --config "$CUR_CONFIG"
expect_rc 80
expect_log 'already completed' 'refuses to run twice'

step "an interrupted run resumes at the step it stopped on"
new_case resume
prepare_ok
stub_opt migrate-rc 1
run_script run --intent=switch --config "$CUR_CONFIG"
expect_rc 40
stub_opt migrate-rc
run_script run --intent=switch --config "$CUR_CONFIG"
expect_rc 0
expect_log "resuming at 'migrate'" 'resumes at the failed step'
expect_no_log '== freeze:' 'the resume does not repeat the freeze'
expect_journal stage "done"
if [ "$(dump_count)" = 1 ]; then ok "the backup was taken exactly once"; else bad "$(dump_count) dumps exist; a resume re-took the backup"; fi
expect_order 'systemctl stop multica-upgrade.timer' 'exec .* pg_dump'

step "the release pins match the reviewed release"
pin_of() { grep -E "^readonly $1=" "$EXECUTOR" | head -1 | sed 's/.*=//'; }

expect_pin() {
    local got
    got="$(pin_of "$1")"
    if [ "$got" = "$2" ]; then ok "$1=$2"; else bad "$1='$got', expected '$2'"; fi
}

expect_pin PIN_BACKEND_DIGEST_NEW "$BACKEND_DIGEST_NEW"
expect_pin PIN_WEB_DIGEST_NEW "$WEB_DIGEST_NEW"
expect_pin PIN_BACKEND_DIGEST_OLD "$BACKEND_DIGEST_OLD"
expect_pin PIN_WEB_DIGEST_OLD "$WEB_DIGEST_OLD"
expect_pin PIN_BACKEND_REV_NEW "$REV_NEW"
expect_pin PIN_BACKEND_REV_OLD "$REV_OLD"
expect_pin PIN_APPROVED_UPGRADE_SHA256 a777090243e1bcf237856486d9759ff596dbf95c1751c928a41ef19388ed58d7
expect_pin PIN_CLI_ARCHIVE_SHA256 6b1414ba07b9b5e4b6e01f2411917e35957812b52449801522c3d3d0a6195e54
expect_pin PIN_CLI_VERSION_NEW "$CLI_VERSION_NEW"
expect_pin PIN_LEDGER_BEFORE 616_member_pinned
expect_pin PIN_LEDGER_AFTER 660_attachment_upload_session_workspace
expect_pin PIN_TABLES_AFTER 148
expect_pin PIN_INDEXES_AFTER 799

step "the executor never invokes a destructive database command"
# Every mention of a restore or a down-migration must sit in a comment or in a
# log string: anything else would be an executable line.
offenders=$(grep -nE 'pg_restore|migrate[[:space:]]+down|DROP[[:space:]]+DATABASE|--clean' "$EXECUTOR" |
    grep -vE ':[[:space:]]*#' |
    grep -vE ':[[:space:]]*log ' |
    grep -vE 'pg_restore -l' || true)
if [ -n "$offenders" ]; then
    bad "the executor can execute a destructive database command: $(printf '%s' "$offenders" | head -3 | tr '\n' '|')"
else
    ok "pg_restore, migrate down and --clean appear only in comments and log text"
fi
if grep -q 'cmd_rollback_r2' "$EXECUTOR"; then
    ok "rollback-r2 is wired to its handler"
else
    bad "rollback-r2 is not wired"
fi

step "the executor needs no bash feature newer than 3"
if grep -nE 'declare -A|mapfile|readarray|\$\{[a-zA-Z_]+,,|\$\{[a-zA-Z_]+\^\^' "$EXECUTOR" >/dev/null; then
    bad "the executor uses a bash 4+ construct: $(grep -nE 'declare -A|mapfile|readarray' "$EXECUTOR" | head -2)"
else
    ok "no bash-4-only construct"
fi

# ---------------------------------------------------------------------------
printf '\n'
if [ "$FAIL" -eq 0 ]; then
    printf '\033[32m%s checks passed\033[0m\n' "$PASS"
    exit 0
fi
printf '\033[31m%s passed, %s failed\033[0m\n' "$PASS" "$FAIL"
for f in "${FAILURES[@]}"; do printf '  - %s\n' "$f"; done
exit 1
