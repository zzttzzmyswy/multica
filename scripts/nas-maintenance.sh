#!/usr/bin/env bash
# NAS maintenance executor for the Multica v0.9.0-myswy.2 switch (MYS-2871/2872).
#
# This is the only entry point that changes production state on the NAS. It runs
# one bounded, mutually exclusive sequence with a persistent log and an atomic
# journal, so a supervising process (never an agent session, never the Multica
# API) can drive it and an operator can watch it from a separate shell.
#
# Commands
#   prepare --config F
#       Verify and stage every asset, snapshot the pre-change state. No service
#       is stopped, no container is created, nothing outside STATE_DIR and
#       BACKUP_DIR is written.
#   run --intent=switch --config F
#       The bounded maintenance: freeze all writers, final backup, migrate,
#       switch backend/web, install the frozen CLI and the approved upgrade
#       script, verify, restore the recorded unit states.
#   rollback-r1 --config F
#       Restore the exact pre-change compose file, images, CLI and upgrade
#       script from the prepare snapshot, then restore daemon/timer states.
#       Keeps the current database.
#   rollback-r2
#       Always refused (exit 80) with a read-only recovery plan.
#   status [--config F]
#       Read-only. Never takes the modification lock, so it works while `run`
#       holds it, and needs no config (production defaults).
#
# Exit codes
#    0 ok | 2 usage | 10 locked | 20 prepare/asset/config | 30 freeze or backup
#   40 migrate | 50 candidate backend/web | 60 cli or upgrade script
#   70 rollback or thaw incomplete | 80 refused
#
# Boundaries (deliberate, do not extend casually)
#   * There is no destructive database restore: no pg_restore --clean, no DROP,
#     no `migrate down`, no ledger edits. The pre-change dump is evidence, not
#     an automatic recovery mechanism. Restoring into a new database or volume
#     and switching the connection is a separate, separately reviewed NAS
#     operation.
#   * Every assertion reads real state (systemctl is-active, docker inspect,
#     psql, curl). A command's exit status alone never proves a state.
#   * Write commands refuse to run without an explicit config file, so a
#     forgotten parameter can never fall back to a built-in production path.
#
# Production writes stay behind explicit intent: `run` requires --intent=switch
# and refuses every other value; bare invocation prints usage and exits 2.

set -uo pipefail

readonly EXIT_OK=0
readonly EXIT_USAGE=2
readonly EXIT_LOCKED=10
readonly EXIT_PREPARE=20
readonly EXIT_FREEZE=30
readonly EXIT_MIGRATE=40
readonly EXIT_CANDIDATE=50
readonly EXIT_CLI=60
readonly EXIT_ROLLBACK=70
readonly EXIT_REFUSED=80

# ---------------------------------------------------------------------------
# Frozen release pins. File hashes can be overridden by config for fixture
# suites; the two digest/revision/count pins that define the acceptance cannot.
# ---------------------------------------------------------------------------
readonly PIN_BACKEND_REV_NEW=8098fd32808c57d8e3b6bd8f7408e6e47b81e7ab
readonly PIN_BACKEND_REV_OLD=b1ea927def6490c43bedff537b6f4ed9a47fa828
readonly PIN_BACKEND_DIGEST_NEW=sha256:01e09bc9d800260b89834c6a0a00433a456daa5f8ec06211a1515da103817702
readonly PIN_WEB_DIGEST_NEW=sha256:011f47fd9a1adf688382f36d7b9446fd580d50b0b7321377492e189da46e4b26
readonly PIN_BACKEND_DIGEST_OLD=sha256:864a97102959895b174f4fb1e2798bc38c896ea9ff33497564ec11eac5728374
readonly PIN_WEB_DIGEST_OLD=sha256:ece41d5b9732ce62a4362e5b55dd89ca2fa5ad9af692536738958a8da92d31fa
readonly PIN_CLI_VERSION_NEW=0.9.0-myswy.2
readonly PIN_CLI_ARCHIVE_SHA256=6b1414ba07b9b5e4b6e01f2411917e35957812b52449801522c3d3d0a6195e54
readonly PIN_APPROVED_UPGRADE_SHA256=a777090243e1bcf237856486d9759ff596dbf95c1751c928a41ef19388ed58d7
readonly PIN_LEDGER_BEFORE=616_member_pinned
readonly PIN_LEDGER_ROWS_BEFORE=640
readonly PIN_TABLES_BEFORE=131
readonly PIN_INDEXES_BEFORE=740
readonly PIN_LEDGER_AFTER=660_attachment_upload_session_workspace
readonly PIN_LEDGER_ROWS_AFTER=684
readonly PIN_TABLES_AFTER=148
readonly PIN_INDEXES_AFTER=799

# Read-only production defaults, used by `status` when no config is given.
DEFAULT_COMPOSE_DIR=/home/myswy/dockers/multica
DEFAULT_COMPOSE_FILE=/home/myswy/dockers/multica/docker-compose.yml
DEFAULT_PROJECT=multica
DEFAULT_PG_CONTAINER=pgvector-pgvector
DEFAULT_PG_USER=multica
DEFAULT_PG_DATABASE=multica
DEFAULT_BACKEND_CONTAINER=multica-backend-1
DEFAULT_FRONTEND_CONTAINER=multica-frontend-1
DEFAULT_DAEMON_UNIT=multica-daemon
DEFAULT_UPGRADE_TIMER=multica-upgrade.timer
DEFAULT_GC_TIMER=multica-attachment-gc.timer
DEFAULT_BACKEND_URL=http://127.0.0.1:8080/health
DEFAULT_CLI_BIN=/usr/local/bin/multica
DEFAULT_UPGRADE_SCRIPT=/home/myswy/scripts/upgrade-multica.sh
DEFAULT_STATE_DIR=/home/myswy/.local/state/multica-maintenance
DEFAULT_LOG=/home/myswy/scripts/multica-maintenance.log
DEFAULT_BACKUP_DIR=/Volume1/@backup

# Runtime settings; populated by load_config (write commands) or by
# apply_readonly_defaults (status only).
COMPOSE_DIR=""
COMPOSE_FILE=""
COMPOSE_FILE_NEW=""
PROJECT=""
DOCKER_NETWORK=""
PG_CONTAINER=""
PG_USER=""
PG_DATABASE=""
BACKEND_CONTAINER=""
FRONTEND_CONTAINER=""
DAEMON_UNIT=""
UPGRADE_TIMER=""
GC_TIMER=""
UPGRADE_SERVICE=""
GC_SERVICE=""
BACKEND_URL=""
CLI_BIN=""
UPGRADE_SCRIPT=""
CLI_ARCHIVE=""
APPROVED_UPGRADE_SCRIPT=""
STATE_DIR=""
LOG=""
BACKUP_DIR=""
CLI_ARCHIVE_SHA256=$PIN_CLI_ARCHIVE_SHA256
APPROVED_UPGRADE_SHA256=$PIN_APPROVED_UPGRADE_SHA256

# Timeouts in seconds. Overridable per deployment config; every external call is
# bounded by one of these, and a timeout is a failure, never a silent wait.
STOP_TIMEOUT=120
BACKUP_TIMEOUT=900
TOC_TIMEOUT=300
MIGRATE_TIMEOUT=1800
UP_TIMEOUT=600
HEALTH_TIMEOUT=180
QUERY_TIMEOUT=60
PROBE_TIMEOUT=15
HEALTH_POLL_INTERVAL=1

CONFIG_FILE=""
CONFIG_LOADED=0
INTENT=""
JOURNAL=""
ASSETS=""
LOCK=""
WORK=""

PROG=${0##*/}

# ---------------------------------------------------------------------------
# Logging and small helpers
# ---------------------------------------------------------------------------
log() {
    local line
    line="[$(date '+%F %T')] $*"
    if [ -n "$LOG" ]; then
        mkdir -p "$(dirname -- "$LOG")" 2>/dev/null
        printf '%s\n' "$line" >>"$LOG" 2>/dev/null
    fi
    printf '%s\n' "$line"
}

have() { command -v "$1" >/dev/null 2>&1; }

# bounded <seconds> <command...>: every external call gets a hard ceiling.
bounded() {
    local secs=$1
    shift
    if have timeout; then
        timeout "$secs" "$@"
    else
        "$@"
    fi
}

sha256_of() {
    if have sha256sum; then
        sha256sum "$1" 2>/dev/null | awk '{print $1}'
    elif have shasum; then
        shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'
    else
        return 1
    fi
}

# atomic_install <src> <dst> [mode]: copy beside the target, then rename.
atomic_install() {
    local src=$1 dst=$2 mode=${3:-}
    local tmp="$dst.nas-maint.$$"
    if [ -n "$mode" ]; then
        install -m "$mode" "$src" "$tmp" || { rm -f "$tmp"; return 1; }
    else
        cp -p "$src" "$tmp" || { rm -f "$tmp"; return 1; }
    fi
    mv -f "$tmp" "$dst" || { rm -f "$tmp"; return 1; }
    return 0
}

# ---------------------------------------------------------------------------
# Journal: flat key=value lines, rewritten atomically (temp file + rename) so a
# reader never sees a half-written file. Keys are written once when they carry
# the pre-change snapshot: a re-run must not replace the original values.
# ---------------------------------------------------------------------------
journal_errors() {
    [ -f "$JOURNAL" ] || return 0
    awk 'NF && $0 !~ /^[A-Za-z0-9_.-]+=/ { print "malformed line " NR ": " $0; bad = 1 }
         END { exit bad ? 1 : 0 }' "$JOURNAL" 2>/dev/null
}

jget() {
    [ -f "$JOURNAL" ] || return 1
    awk -v k="$1=" 'index($0, k) == 1 { v = substr($0, length(k) + 1) } END { if (v == "") exit 1; print v }' "$JOURNAL"
}

# jset <key> <value> [--once]
jset() {
    local k=$1 v=$2 mode=${3:-}
    case $k in
        ''|*[!A-Za-z0-9_.-]*) log "ERROR: invalid journal key '$k'"; return 1 ;;
    esac
    if [ -e "$JOURNAL" ] && [ ! -f "$JOURNAL" ]; then
        log "ERROR: $JOURNAL exists but is not a regular file"
        return 1
    fi
    case $v in
        *$'\n'*) log "ERROR: journal value for '$k' contains a newline"; return 1 ;;
    esac
    if [ "$mode" = "--once" ] && jget "$k" >/dev/null 2>&1; then
        return 0
    fi
    local tmp="$JOURNAL.tmp.$$"
    {
        if [ -f "$JOURNAL" ]; then
            awk -v k="$k=" 'index($0, k) != 1' "$JOURNAL"
        fi
        printf '%s=%s\n' "$k" "$v"
    } >"$tmp" 2>/dev/null || { rm -f "$tmp"; log "ERROR: journal $JOURNAL is not writable"; return 1; }
    mv -f "$tmp" "$JOURNAL" 2>/dev/null || { rm -f "$tmp"; log "ERROR: cannot replace journal $JOURNAL"; return 1; }
    return 0
}

# journal_guard: the journal must exist, parse, belong to this config, and be in
# a stage this command understands. Anything else refuses to continue.
journal_guard() {
    if [ -e "$JOURNAL" ] && [ ! -f "$JOURNAL" ]; then
        log "ERROR: $JOURNAL exists but is not a regular file; refusing to write through it"
        return $EXIT_PREPARE
    fi
    if [ -e "$JOURNAL" ]; then
        if ! journal_errors >/dev/null 2>&1; then
            journal_errors | while IFS= read -r line; do log "ERROR: journal corrupt: $line"; done
            log "REFUSE: $JOURNAL is corrupt; restore it from a copy or archive it and re-run 'prepare'"
            return $EXIT_REFUSED
        fi
    fi
    local want actual
    want=$(config_sha256)
    actual=$(jget config_sha256 2>/dev/null || true)
    if [ -n "$actual" ] && [ "$actual" != "$want" ]; then
        log "REFUSE: the journal was prepared with a different config (journal=$actual config=$want)"
        log "        re-running with a changed config would apply a different snapshot; use the original config"
        return $EXIT_REFUSED
    fi
    if ! : >>"$JOURNAL.probe" 2>/dev/null; then
        log "ERROR: journal directory is not writable: $STATE_DIR"
        return $EXIT_PREPARE
    fi
    rm -f "$JOURNAL.probe"
    return 0
}

config_sha256() {
    [ -n "$CONFIG_FILE" ] && [ -f "$CONFIG_FILE" ] || { printf 'none'; return 0; }
    sha256_of "$CONFIG_FILE"
}

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
usage() {
    cat <<USAGE
usage: $PROG <command> [options]

  prepare --config FILE          verify+stage assets, snapshot pre-change state
  run --intent=switch --config FILE
                                 bounded maintenance (freeze, backup, migrate,
                                 switch, cli, verify, restore units)
  rollback-r1 --config FILE      restore images/compose/cli/upgrade script, keep DB
  rollback-r2                    always refused; prints a read-only plan
  status [--config FILE]         read-only stage, journal, log tail and live state

Every write command requires --config with an explicit deployment description.
Exit codes: 0 ok | 2 usage | 10 locked | 20 prepare | 30 freeze/backup
            40 migrate | 50 candidate | 60 cli/script | 70 rollback | 80 refused
USAGE
}

load_config() {
    local f=$1 line k v
    if [ ! -f "$f" ]; then
        printf 'config file not found: %s\n' "$f" >&2
        return 1
    fi
    while IFS= read -r line || [ -n "$line" ]; do
        # A config edited over SMB or from Windows may carry CRLF endings; a
        # trailing CR would otherwise become part of the last path or hash.
        line=${line%$'\r'}
        case $line in
            ''|'#'*) continue ;;
            *=*) ;;
            *) printf 'config: line is not KEY=VALUE: %s\n' "$line" >&2; return 1 ;;
        esac
        k=${line%%=*}
        v=${line#*=}
        case $v in
            \"*\") v=${v#\"}; v=${v%\"} ;;
            \'*\') v=${v#\'}; v=${v%\'} ;;
        esac
        case $k in
            COMPOSE_DIR) COMPOSE_DIR=$v ;;
            COMPOSE_FILE) COMPOSE_FILE=$v ;;
            COMPOSE_FILE_NEW) COMPOSE_FILE_NEW=$v ;;
            PROJECT) PROJECT=$v ;;
            DOCKER_NETWORK) DOCKER_NETWORK=$v ;;
            PG_CONTAINER) PG_CONTAINER=$v ;;
            PG_USER) PG_USER=$v ;;
            PG_DATABASE) PG_DATABASE=$v ;;
            BACKEND_CONTAINER) BACKEND_CONTAINER=$v ;;
            FRONTEND_CONTAINER) FRONTEND_CONTAINER=$v ;;
            DAEMON_UNIT) DAEMON_UNIT=$v ;;
            UPGRADE_TIMER) UPGRADE_TIMER=$v ;;
            GC_TIMER) GC_TIMER=$v ;;
            UPGRADE_SERVICE) UPGRADE_SERVICE=$v ;;
            GC_SERVICE) GC_SERVICE=$v ;;
            BACKEND_URL) BACKEND_URL=$v ;;
            CLI_BIN) CLI_BIN=$v ;;
            UPGRADE_SCRIPT) UPGRADE_SCRIPT=$v ;;
            CLI_ARCHIVE) CLI_ARCHIVE=$v ;;
            APPROVED_UPGRADE_SCRIPT) APPROVED_UPGRADE_SCRIPT=$v ;;
            STATE_DIR) STATE_DIR=$v ;;
            LOG) LOG=$v ;;
            BACKUP_DIR) BACKUP_DIR=$v ;;
            CLI_ARCHIVE_SHA256) CLI_ARCHIVE_SHA256=$v ;;
            APPROVED_UPGRADE_SHA256) APPROVED_UPGRADE_SHA256=$v ;;
            STOP_TIMEOUT) STOP_TIMEOUT=$v ;;
            BACKUP_TIMEOUT) BACKUP_TIMEOUT=$v ;;
            TOC_TIMEOUT) TOC_TIMEOUT=$v ;;
            MIGRATE_TIMEOUT) MIGRATE_TIMEOUT=$v ;;
            UP_TIMEOUT) UP_TIMEOUT=$v ;;
            HEALTH_TIMEOUT) HEALTH_TIMEOUT=$v ;;
            QUERY_TIMEOUT) QUERY_TIMEOUT=$v ;;
            PROBE_TIMEOUT) PROBE_TIMEOUT=$v ;;
            *)
                printf 'config: unknown key %s\n' "$k" >&2
                return 1
                ;;
        esac
    done <"$f"

    CONFIG_FILE=$f
    CONFIG_LOADED=1
    derive_paths
    return 0
}

derive_paths() {
    [ -n "${UPGRADE_SERVICE:-}" ] || UPGRADE_SERVICE=${UPGRADE_TIMER%.timer}.service
    [ -n "${GC_SERVICE:-}" ] || GC_SERVICE=${GC_TIMER%.timer}.service
    if [ -n "$STATE_DIR" ]; then
        JOURNAL=$STATE_DIR/journal
        ASSETS=$STATE_DIR/assets
        LOCK=$STATE_DIR/maintenance.lock
    fi
}

apply_readonly_defaults() {
    COMPOSE_DIR=$DEFAULT_COMPOSE_DIR
    COMPOSE_FILE=$DEFAULT_COMPOSE_FILE
    PROJECT=$DEFAULT_PROJECT
    PG_CONTAINER=$DEFAULT_PG_CONTAINER
    PG_USER=$DEFAULT_PG_USER
    PG_DATABASE=$DEFAULT_PG_DATABASE
    BACKEND_CONTAINER=$DEFAULT_BACKEND_CONTAINER
    FRONTEND_CONTAINER=$DEFAULT_FRONTEND_CONTAINER
    DAEMON_UNIT=$DEFAULT_DAEMON_UNIT
    UPGRADE_TIMER=$DEFAULT_UPGRADE_TIMER
    GC_TIMER=$DEFAULT_GC_TIMER
    BACKEND_URL=$DEFAULT_BACKEND_URL
    CLI_BIN=$DEFAULT_CLI_BIN
    UPGRADE_SCRIPT=$DEFAULT_UPGRADE_SCRIPT
    STATE_DIR=$DEFAULT_STATE_DIR
    LOG=$DEFAULT_LOG
    BACKUP_DIR=$DEFAULT_BACKUP_DIR
    derive_paths
}

# require_config: write commands must have every write-relevant setting spelled
# out. Missing settings are a refusal, never a production default.
require_config() {
    local missing="" k v
    if [ "$CONFIG_LOADED" != 1 ]; then
        log "REFUSE: a write command requires --config FILE (no production defaults are applied)"
        return $EXIT_USAGE
    fi
    for k in COMPOSE_DIR COMPOSE_FILE COMPOSE_FILE_NEW PROJECT DOCKER_NETWORK \
             PG_CONTAINER PG_USER PG_DATABASE BACKEND_CONTAINER FRONTEND_CONTAINER \
             DAEMON_UNIT UPGRADE_TIMER GC_TIMER BACKEND_URL CLI_BIN UPGRADE_SCRIPT \
             CLI_ARCHIVE APPROVED_UPGRADE_SCRIPT STATE_DIR LOG BACKUP_DIR; do
        eval "v=\${$k:-}"
        [ -n "$v" ] || missing="$missing $k"
    done
    if [ -n "$missing" ]; then
        log "REFUSE: config is incomplete; missing:$missing"
        return $EXIT_USAGE
    fi
    for k in STOP_TIMEOUT BACKUP_TIMEOUT TOC_TIMEOUT MIGRATE_TIMEOUT UP_TIMEOUT \
             HEALTH_TIMEOUT QUERY_TIMEOUT PROBE_TIMEOUT; do
        eval "v=\${$k:-}"
        case $v in
            ''|*[!0-9]*) log "REFUSE: timeout $k must be a positive integer, got '$v'"; return $EXIT_USAGE ;;
        esac
    done
    case $COMPOSE_FILE in
        /*) ;;
        *) log "REFUSE: COMPOSE_FILE must be an absolute path"; return $EXIT_USAGE ;;
    esac
    if [ "$COMPOSE_DIR" != "$(dirname -- "$COMPOSE_FILE")" ]; then
        log "REFUSE: COMPOSE_DIR $COMPOSE_DIR does not contain COMPOSE_FILE $COMPOSE_FILE"
        return $EXIT_USAGE
    fi
    return 0
}

# ---------------------------------------------------------------------------
# State probes. Each returns observed state, never an assumption.
# ---------------------------------------------------------------------------
unit_state() {
    local s
    s=$(bounded "$PROBE_TIMEOUT" systemctl is-active "$1" 2>/dev/null)
    printf '%s' "${s:-unknown}"
}

unit_state_stopped() {
    case $1 in
        inactive|failed) return 0 ;;
        *) return 1 ;;
    esac
}

container_status() {
    local s
    s=$(bounded "$PROBE_TIMEOUT" docker inspect -f '{{.State.Status}}' "$1" 2>/dev/null)
    printf '%s' "${s:-missing}"
}

container_running() {
    local s
    s=$(bounded "$PROBE_TIMEOUT" docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)
    printf '%s' "${s:-false}"
}

container_image_ref() {
    bounded "$PROBE_TIMEOUT" docker inspect -f '{{.Config.Image}}' "$1" 2>/dev/null
}

image_id() {
    bounded "$PROBE_TIMEOUT" docker image inspect -f '{{.Id}}' "$1" 2>/dev/null
}

psql_value() {
    bounded "$QUERY_TIMEOUT" docker exec "$PG_CONTAINER" \
        psql -U "$PG_USER" -d "$PG_DATABASE" -tAc "$1" 2>/dev/null | tr -d '[:space:]'
}

ledger_max() { psql_value "select max(version) from schema_migrations;"; }
ledger_rows() { psql_value "select count(*) from schema_migrations;"; }
table_count() { psql_value "select count(*) from information_schema.tables where table_schema='public';"; }
index_state() { psql_value "select count(*)||'/'||count(*) filter (where not indisvalid)||'/'||count(*) filter (where not indisready) from pg_index;"; }

health_body() { bounded "$PROBE_TIMEOUT" curl -fsS --max-time "$PROBE_TIMEOUT" "$BACKEND_URL" 2>/dev/null; }

health_field() {
    printf '%s' "$1" | sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p"
}

# digest_of_ref: "ghcr.io/x@sha256:abc" -> "sha256:abc" (empty when unpinned).
digest_of_ref() {
    case $1 in
        *@sha256:*) printf '%s' "${1##*@}" ;;
        *) printf '' ;;
    esac
}

# ---------------------------------------------------------------------------
# Locking. flock is mandatory: without it the "one maintenance at a time"
# guarantee does not exist, so refuse rather than run unprotected.
# ---------------------------------------------------------------------------
acquire_lock() {
    have flock || { log "ERROR: flock is required for mutual exclusion"; return $EXIT_PREPARE; }
    mkdir -p "$STATE_DIR" 2>/dev/null || { log "ERROR: cannot create $STATE_DIR"; return $EXIT_PREPARE; }
    exec 9>>"$LOCK" || { log "ERROR: cannot open lock file $LOCK"; return $EXIT_PREPARE; }
    if ! flock -n 9; then
        log "REFUSE: another maintenance action holds $LOCK (exit $EXIT_LOCKED)"
        return $EXIT_LOCKED
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Composer of shared steps
# ---------------------------------------------------------------------------
report_state() {
    log "  actual state:"
    log "    units: daemon=$(unit_state "$DAEMON_UNIT") upgrade_timer=$(unit_state "$UPGRADE_TIMER") upgrade_service=$(unit_state "$UPGRADE_SERVICE") gc_timer=$(unit_state "$GC_TIMER") gc_service=$(unit_state "$GC_SERVICE")"
    log "    containers: backend=$(container_status "$BACKEND_CONTAINER") frontend=$(container_status "$FRONTEND_CONTAINER")"
    log "    images: backend=$(container_image_ref "$BACKEND_CONTAINER") frontend=$(container_image_ref "$FRONTEND_CONTAINER")"
    local cli cli_sha
    cli=$([ -x "$CLI_BIN" ] && "$CLI_BIN" --version 2>/dev/null | head -1 | awk '{print $2}')
    cli_sha=$([ -f "$CLI_BIN" ] && sha256_of "$CLI_BIN")
    log "    cli: version=${cli:-missing} sha256=${cli_sha:-missing}"
    log "    upgrade_script: sha256=$([ -f "$UPGRADE_SCRIPT" ] && sha256_of "$UPGRADE_SCRIPT" || printf 'missing')"
    log "    database: ledger=$(ledger_max) rows=$(ledger_rows) tables=$(table_count) indexes=$(index_state)"
    log "    health: $(health_body)"
}

record_failure() {
    local step=$1 code=$2
    log "FAILED at '$step' (exit $code); journal stage stays at '$(jget stage 2>/dev/null || printf 'unknown')' so a re-run resumes here"
    jset last_error "$step failed" >/dev/null 2>&1
    jset last_error_code "$code" >/dev/null 2>&1
    jset last_error_at "$(date '+%F %T')" >/dev/null 2>&1
}

stage_set() {
    jset stage "$1" || return 1
    jset stage_at "$(date '+%F %T')" || return 1
    log "stage -> $1"
    return 0
}

# ---------------------------------------------------------------------------
# Asset staging and pre-change snapshot (prepare)
# ---------------------------------------------------------------------------
compose_input_check() {
    local old_images new_images n_new_backend n_new_web
    old_images=$(grep -cE '^[[:space:]]*image:' "$COMPOSE_FILE" 2>/dev/null)
    new_images=$(grep -cE '^[[:space:]]*image:' "$COMPOSE_FILE_NEW" 2>/dev/null)
    [ "${old_images:-0}" -gt 0 ] || { log "ERROR: $COMPOSE_FILE has no image lines"; return 1; }
    if [ "$old_images" != "$new_images" ]; then
        log "ERROR: the approved compose input has $new_images image lines, the live file has $old_images"
        return 1
    fi
    grep -vE '^[[:space:]]*image:' "$COMPOSE_FILE" >"$WORK/live.norm" || return 1
    grep -vE '^[[:space:]]*image:' "$COMPOSE_FILE_NEW" >"$WORK/new.norm" || return 1
    if ! cmp -s "$WORK/live.norm" "$WORK/new.norm"; then
        log "ERROR: the approved compose input differs from the live file outside image lines"
        return 1
    fi
    n_new_backend=$(grep -E '^[[:space:]]*image:' "$COMPOSE_FILE_NEW" | grep -c -- "$PIN_BACKEND_DIGEST_NEW")
    n_new_web=$(grep -E '^[[:space:]]*image:' "$COMPOSE_FILE_NEW" | grep -c -- "$PIN_WEB_DIGEST_NEW")
    [ "${n_new_backend:-0}" -eq 1 ] || { log "ERROR: approved compose input does not pin the backend .2 digest exactly once"; return 1; }
    [ "${n_new_web:-0}" -eq 1 ] || { log "ERROR: approved compose input does not pin the web .2 digest exactly once"; return 1; }
    if grep -E '^[[:space:]]*image:' "$COMPOSE_FILE" | grep -q -- "$PIN_BACKEND_DIGEST_NEW"; then
        log "ERROR: the live compose file already references the .2 backend digest; nothing to snapshot"
        return 1
    fi
    return 0
}

stage_assets() {
    local cli_sha bin_sha ver approved_sha
    log "== staging assets (no service is touched) =="

    [ -f "$CLI_ARCHIVE" ] || { log "ERROR: CLI archive not found: $CLI_ARCHIVE"; return $EXIT_PREPARE; }
    cli_sha=$(sha256_of "$CLI_ARCHIVE")
    if [ "$cli_sha" != "$CLI_ARCHIVE_SHA256" ]; then
        log "ERROR: CLI archive sha256 mismatch: expected $CLI_ARCHIVE_SHA256 got ${cli_sha:-none}"
        return $EXIT_PREPARE
    fi
    log "CLI archive sha256 ok ($cli_sha)"

    mkdir -p "$ASSETS/cli" "$ASSETS/compose" "$ASSETS/previous" || { log "ERROR: cannot create $ASSETS"; return $EXIT_PREPARE; }
    rm -rf "$ASSETS/cli/unpack"
    mkdir -p "$ASSETS/cli/unpack" || return $EXIT_PREPARE
    bounded 300 tar xzf "$CLI_ARCHIVE" -C "$ASSETS/cli/unpack" || { log "ERROR: cannot extract $CLI_ARCHIVE"; return $EXIT_PREPARE; }
    [ -f "$ASSETS/cli/unpack/multica" ] || { log "ERROR: CLI archive does not contain a 'multica' binary"; return $EXIT_PREPARE; }
    chmod 755 "$ASSETS/cli/unpack/multica" 2>/dev/null
    ver=$("$ASSETS/cli/unpack/multica" --version 2>/dev/null | head -1 | awk '{print $2}')
    if [ "$ver" != "$PIN_CLI_VERSION_NEW" ]; then
        log "ERROR: staged CLI reports version '${ver:-none}', expected $PIN_CLI_VERSION_NEW"
        return $EXIT_PREPARE
    fi
    bin_sha=$(sha256_of "$ASSETS/cli/unpack/multica")
    cp -p "$CLI_ARCHIVE" "$ASSETS/cli/archive.tar.gz" || return $EXIT_PREPARE
    log "CLI staged: version=$ver binary_sha256=$bin_sha"

    [ -f "$APPROVED_UPGRADE_SCRIPT" ] || { log "ERROR: approved upgrade script not found: $APPROVED_UPGRADE_SCRIPT"; return $EXIT_PREPARE; }
    approved_sha=$(sha256_of "$APPROVED_UPGRADE_SCRIPT")
    if [ "$approved_sha" != "$APPROVED_UPGRADE_SHA256" ]; then
        log "ERROR: approved upgrade script sha256 mismatch: expected $APPROVED_UPGRADE_SHA256 got ${approved_sha:-none}"
        return $EXIT_PREPARE
    fi
    cp -p "$APPROVED_UPGRADE_SCRIPT" "$ASSETS/approved-upgrade-multica.sh" || return $EXIT_PREPARE
    log "approved upgrade script staged ($approved_sha); it is installed verbatim, never regenerated"

    cp -p "$COMPOSE_FILE_NEW" "$ASSETS/compose/docker-compose.new.yml" || return $EXIT_PREPARE
    jset cli_archive_sha256 "$cli_sha" --once || return $EXIT_PREPARE
    jset cli_binary_sha256 "$bin_sha" --once || return $EXIT_PREPARE
    jset cli_version_new "$ver" --once || return $EXIT_PREPARE
    jset approved_upgrade_sha256 "$approved_sha" --once || return $EXIT_PREPARE
    jset approved_upgrade_sha256_pin "$APPROVED_UPGRADE_SHA256" --once || return $EXIT_PREPARE
    jset cli_archive_sha256_pin "$CLI_ARCHIVE_SHA256" --once || return $EXIT_PREPARE
    return 0
}

snapshot_state() {
    local backend_ref web_ref backend_digest web_digest compose_sha cli_sha cli_ver script_sha script_mode script_uid script_gid
    log "== snapshot of the pre-change state =="

    backend_ref=$(container_image_ref "$BACKEND_CONTAINER")
    web_ref=$(container_image_ref "$FRONTEND_CONTAINER")
    [ -n "$backend_ref" ] || { log "ERROR: cannot read the backend image of container $BACKEND_CONTAINER"; return $EXIT_PREPARE; }
    [ -n "$web_ref" ] || { log "ERROR: cannot read the web image of container $FRONTEND_CONTAINER"; return $EXIT_PREPARE; }
    backend_digest=$(digest_of_ref "$backend_ref")
    web_digest=$(digest_of_ref "$web_ref")
    if [ "$backend_digest" != "$PIN_BACKEND_DIGEST_OLD" ]; then
        log "ERROR: running backend digest is '${backend_digest:-unpinned}', expected the pre-change pin $PIN_BACKEND_DIGEST_OLD"
        log "       ($backend_ref) — re-verify the rollback baseline on the NAS before switching"
        return $EXIT_PREPARE
    fi
    if [ "$web_digest" != "$PIN_WEB_DIGEST_OLD" ]; then
        log "ERROR: running web digest is '${web_digest:-unpinned}', expected the pre-change pin $PIN_WEB_DIGEST_OLD"
        return $EXIT_PREPARE
    fi

    compose_sha=$(sha256_of "$COMPOSE_FILE")
    cp -p "$COMPOSE_FILE" "$ASSETS/compose/docker-compose.initial.yml" || return $EXIT_PREPARE
    [ "$(sha256_of "$ASSETS/compose/docker-compose.initial.yml")" = "$compose_sha" ] || {
        log "ERROR: compose snapshot does not match the live file"; return $EXIT_PREPARE; }

    if [ -f "$CLI_BIN" ]; then
        cp -p "$CLI_BIN" "$ASSETS/previous/multica" || return $EXIT_PREPARE
        cli_sha=$(sha256_of "$CLI_BIN")
        [ "$(sha256_of "$ASSETS/previous/multica")" = "$cli_sha" ] || { log "ERROR: CLI snapshot hash mismatch"; return $EXIT_PREPARE; }
        cli_ver=$("$CLI_BIN" --version 2>/dev/null | head -1 | awk '{print $2}')
        [ -n "$cli_ver" ] || { log "ERROR: cannot read the version of the installed CLI $CLI_BIN"; return $EXIT_PREPARE; }
    else
        cli_sha=""; cli_ver=""
    fi

    if [ -f "$UPGRADE_SCRIPT" ]; then
        script_sha=$(sha256_of "$UPGRADE_SCRIPT")
        cp -p "$UPGRADE_SCRIPT" "$ASSETS/previous/upgrade-multica.sh" || return $EXIT_PREPARE
        [ "$(sha256_of "$ASSETS/previous/upgrade-multica.sh")" = "$script_sha" ] || {
            log "ERROR: upgrade script snapshot hash mismatch"; return $EXIT_PREPARE; }
        script_mode=$(stat -c '%a' "$UPGRADE_SCRIPT" 2>/dev/null || stat -f '%Lp' "$UPGRADE_SCRIPT" 2>/dev/null)
        script_uid=$(stat -c '%u' "$UPGRADE_SCRIPT" 2>/dev/null || stat -f '%u' "$UPGRADE_SCRIPT" 2>/dev/null)
        script_gid=$(stat -c '%g' "$UPGRADE_SCRIPT" 2>/dev/null || stat -f '%g' "$UPGRADE_SCRIPT" 2>/dev/null)
    else
        script_sha=""; script_mode=""; script_uid=""; script_gid=""
    fi

    # Unit entry point: the approved script is only useful if the unit runs it.
    local exec_start
    exec_start=$(bounded "$PROBE_TIMEOUT" systemctl show -p ExecStart --value "$UPGRADE_SERVICE" 2>/dev/null)
    case $exec_start in
        *"$UPGRADE_SCRIPT"*) ;;
        *) log "ERROR: unit $UPGRADE_SERVICE does not execute $UPGRADE_SCRIPT (ExecStart: ${exec_start:-unreadable})"
           return $EXIT_PREPARE ;;
    esac

    local d_state ut_state gs_state us_state
    d_state=$(unit_state "$DAEMON_UNIT")
    ut_state=$(unit_state "$UPGRADE_TIMER")
    gs_state=$(unit_state "$GC_TIMER")
    us_state=$(unit_state "$UPGRADE_SERVICE")
    local gc_state
    gc_state=$(unit_state "$GC_SERVICE")
    for pair in "$DAEMON_UNIT=$d_state" "$UPGRADE_TIMER=$ut_state" "$UPGRADE_SERVICE=$us_state" \
                "$GC_TIMER=$gs_state" "$GC_SERVICE=$gc_state"; do
        case ${pair#*=} in
            active|inactive|failed) ;;
            *)
                log "ERROR: ${pair%%=*} is in state '${pair#*=}' (transitional or unreadable); there is no stable state to restore"
                return $EXIT_PREPARE
                ;;
        esac
    done
    # A oneshot timer job that is running right now is mid-flight: freezing it
    # would leave a half-applied update behind, and the snapshot could not
    # describe the state it returns to. Wait for it to finish and re-run.
    local unit_name
    for pair in "$UPGRADE_SERVICE=$us_state" "$GC_SERVICE=$gc_state"; do
        if [ "${pair#*=}" = "active" ]; then
            unit_name=${pair%%=*}
            log "ERROR: $unit_name is running; a timer job is in flight. Wait for it to finish and re-run prepare"
            return $EXIT_PREPARE
        fi
    done

    local lm lr tc ix
    lm=$(ledger_max); lr=$(ledger_rows); tc=$(table_count); ix=$(index_state)
    if [ "$lm" != "$PIN_LEDGER_BEFORE" ]; then
        log "ERROR: ledger is '${lm:-unreadable}', expected the pre-change $PIN_LEDGER_BEFORE"
        return $EXIT_PREPARE
    fi
    # These three are the baseline the rollback evidence was gathered on. A
    # drift here means that evidence no longer describes this box, so record the
    # observed values and stop rather than switching onto an unverified base.
    if [ "$lr" != "$PIN_LEDGER_ROWS_BEFORE" ] || [ "$tc" != "$PIN_TABLES_BEFORE" ] || [ "$ix" != "$PIN_INDEXES_BEFORE/0/0" ]; then
        log "ERROR: baseline is rows=$lr tables=$tc indexes=$ix, expected"
        log "       rows=$PIN_LEDGER_ROWS_BEFORE tables=$PIN_TABLES_BEFORE indexes=$PIN_INDEXES_BEFORE/0/0"
        return $EXIT_PREPARE
    fi

    local k v
    for k in "backend_image=$backend_ref" "web_image=$web_ref" \
             "backend_digest=$backend_digest" "web_digest=$web_digest" \
             "compose_path=$COMPOSE_FILE" "compose_sha256=$compose_sha" \
             "compose_new_sha256=$(sha256_of "$ASSETS/compose/docker-compose.new.yml")" \
             "cli_sha256=$cli_sha" "cli_version=$cli_ver" \
             "upgrade_script_sha256=$script_sha" "upgrade_script_mode=$script_mode" \
             "upgrade_script_uid=$script_uid" "upgrade_script_gid=$script_gid" \
             "daemon_state=$d_state" "upgrade_timer_state=$ut_state" "upgrade_service_state=$us_state" \
             "gc_timer_state=$gs_state" "gc_service_state=$gc_state" \
             "ledger_max=$lm" "ledger_rows=$lr" "tables=$tc" "indexes=$ix" \
             "backend_container_state=$(container_status "$BACKEND_CONTAINER")" \
             "frontend_container_state=$(container_status "$FRONTEND_CONTAINER")" \
             "prepared_at=$(date '+%F %T')"; do
        v=${k#*=}
        k=${k%%=*}
        jset "initial_$k" "$v" --once || return $EXIT_PREPARE
    done
    log "snapshot: compose=$compose_sha cli=${cli_sha:-absent} script=${script_sha:-absent} ledger=$lm/$lr tables=$tc indexes=$ix"
    log "snapshot: daemon=$d_state upgrade_timer=$ut_state gc_timer=$gs_state"
    return 0
}

cmd_prepare() {
    require_config || return $?
    derive_paths
    mkdir -p "$STATE_DIR" || { log "ERROR: cannot create $STATE_DIR"; return $EXIT_PREPARE; }
    if ! : >>"$LOG" 2>/dev/null; then
        printf 'ERROR: log %s is not writable\n' "$LOG" >&2
        return $EXIT_PREPARE
    fi
    acquire_lock || return $?
    journal_guard || return $?

    local stage
    stage=$(jget stage 2>/dev/null || true)
    case $stage in
        '') ;;
        prepared)
            log "note: a prepared snapshot already exists; re-verifying assets, keeping the original snapshot"
            ;;
        *)
            log "REFUSE: maintenance already reached stage '$stage'; the initial snapshot must not be replaced"
            return $EXIT_REFUSED
            ;;
    esac

    log "== prepare (intent: verify assets and snapshot; no service is stopped) =="
    WORK=$(mktemp -d "$STATE_DIR/tmp.XXXXXX") || { log "ERROR: cannot create a work directory under $STATE_DIR"; return $EXIT_PREPARE; }

    local rc=0 ref
    for ref in "$COMPOSE_FILE" "$COMPOSE_FILE_NEW" "$CLI_ARCHIVE" "$APPROVED_UPGRADE_SCRIPT"; do
        [ -f "$ref" ] || { log "ERROR: required input missing: $ref"; rc=$EXIT_PREPARE; break; }
    done
    if [ "$rc" -eq 0 ]; then compose_input_check || rc=$EXIT_PREPARE; fi
    if [ "$rc" -eq 0 ]; then
        log "== verifying the .2 images are already on the box (no network in prepare) =="
        local id
        for id in "$PIN_BACKEND_DIGEST_NEW" "$PIN_WEB_DIGEST_NEW"; do
            case $id in
                "$PIN_BACKEND_DIGEST_NEW") ref="ghcr.io/zzttzzmyswy/multica-backend@$id" ;;
                *) ref="ghcr.io/zzttzzmyswy/multica-web@$id" ;;
            esac
            if [ -z "$(image_id "$ref")" ]; then
                log "ERROR: $ref is not present locally; pull it before prepare (prepare never uses the network)"
                rc=$EXIT_PREPARE
                break
            fi
            log "image present: $ref"
        done
    fi
    if [ "$rc" -eq 0 ]; then
        jset config_sha256 "$(config_sha256)" --once || rc=$EXIT_PREPARE
    fi
    if [ "$rc" -eq 0 ]; then
        jset intent switch --once || rc=$EXIT_PREPARE
    fi
    if [ "$rc" -eq 0 ]; then stage_assets || rc=$?; fi
    if [ "$rc" -eq 0 ]; then snapshot_state || rc=$?; fi
    if [ "$rc" -eq 0 ]; then stage_set prepared || rc=$EXIT_PREPARE; fi
    rm -rf "$WORK"
    WORK=""
    [ "$rc" -eq 0 ] || return "$rc"
    log "prepare ok: assets staged under $ASSETS, snapshot frozen in $JOURNAL"
    return $EXIT_OK
}

# ---------------------------------------------------------------------------
# Steps
# ---------------------------------------------------------------------------
stop_writers() {
    local t svc s
    log "== freeze: stop every writer and confirm the exact state =="
    for t in "$UPGRADE_TIMER" "$GC_TIMER"; do
        svc=${t%.timer}.service
        log "stopping $t"
        if ! bounded "$STOP_TIMEOUT" systemctl stop "$t"; then
            s=$(unit_state "$t")
            log "ERROR: 'systemctl stop $t' failed; state=$s"
            return $EXIT_FREEZE
        fi
        s=$(unit_state "$t")
        unit_state_stopped "$s" || { log "ERROR: $t is still '$s' after stop"; return $EXIT_FREEZE; }
        log "stopping $svc (a timer run may already have started it)"
        if ! bounded "$STOP_TIMEOUT" systemctl stop "$svc"; then
            s=$(unit_state "$svc")
            log "ERROR: 'systemctl stop $svc' failed; state=$s"
            return $EXIT_FREEZE
        fi
        s=$(unit_state "$svc")
        unit_state_stopped "$s" || { log "ERROR: $svc is still '$s' after stop"; return $EXIT_FREEZE; }
        log "$t=$s $svc=$s"
    done

    log "stopping $DAEMON_UNIT"
    if ! bounded "$STOP_TIMEOUT" systemctl stop "$DAEMON_UNIT"; then
        s=$(unit_state "$DAEMON_UNIT")
        log "ERROR: 'systemctl stop $DAEMON_UNIT' failed; state=$s"
        return $EXIT_FREEZE
    fi
    s=$(unit_state "$DAEMON_UNIT")
    unit_state_stopped "$s" || { log "ERROR: $DAEMON_UNIT is still '$s' after stop"; return $EXIT_FREEZE; }

    log "stopping backend and frontend containers (project $PROJECT)"
    if ! bounded "$STOP_TIMEOUT" docker compose -f "$COMPOSE_FILE" -p "$PROJECT" stop backend frontend; then
        log "ERROR: 'docker compose stop backend frontend' failed; backend=$(container_status "$BACKEND_CONTAINER") frontend=$(container_status "$FRONTEND_CONTAINER")"
        return $EXIT_FREEZE
    fi
    local name st running
    for name in "$BACKEND_CONTAINER" "$FRONTEND_CONTAINER"; do
        st=$(container_status "$name")
        running=$(container_running "$name")
        if [ "$running" != "false" ]; then
            log "ERROR: $name is still running (status=$st running=$running); writes are not frozen"
            return $EXIT_FREEZE
        fi
        case $st in
            exited|created) ;;
            *) log "ERROR: $name is in state '$st' after stop; writes are not frozen"; return $EXIT_FREEZE ;;
        esac
    done
    log "writes frozen: timers+services stopped, daemon stopped, backend/frontend exited"
    return 0
}

step_freeze() {
    local rc
    stop_writers || return $?
    jset freeze_at "$(date '+%F %T')" || return $EXIT_FREEZE
    stage_set frozen || return $EXIT_FREEZE
    return 0
}

step_backup() {
    local dump stamp rc toc_out toc_rc toc_lines sha size
    log "== final backup (writes are frozen) =="
    # Re-confirm the writers are still stopped right before the dump.
    local name running
    for name in "$BACKEND_CONTAINER" "$FRONTEND_CONTAINER"; do
        running=$(container_running "$name")
        [ "$running" = "false" ] || { log "ERROR: $name started again (running=$running); refusing to dump a live database"; return $EXIT_FREEZE; }
    done
    [ "$(unit_state "$DAEMON_UNIT")" = "inactive" ] || [ "$(unit_state "$DAEMON_UNIT")" = "failed" ] || {
        log "ERROR: $DAEMON_UNIT is '$(unit_state "$DAEMON_UNIT")' before the dump"; return $EXIT_FREEZE; }

    stamp=$(date '+%Y%m%d-%H%M%S')
    mkdir -p "$BACKUP_DIR" || { log "ERROR: cannot create $BACKUP_DIR"; return $EXIT_FREEZE; }
    dump="$BACKUP_DIR/multica-pre-myswy2-$stamp.dump"
    bounded "$BACKUP_TIMEOUT" docker exec "$PG_CONTAINER" pg_dump -U "$PG_USER" -d "$PG_DATABASE" -Fc >"$dump"
    rc=$?
    if [ "$rc" -ne 0 ]; then
        rm -f "$dump"
        log "ERROR: pg_dump exit=$rc; no usable backup, writers stay stopped (thaw restores service)"
        return $EXIT_FREEZE
    fi
    sha=$(sha256_of "$dump")
    size=$(stat -c '%s' "$dump" 2>/dev/null)
    if [ -z "$sha" ] || [ "${size:-0}" -lt 1024 ]; then
        rm -f "$dump"
        log "ERROR: dump is empty or too small (bytes=${size:-0}); refusing to treat it as a backup"
        return $EXIT_FREEZE
    fi

    # A TOC line count alone hides a pg_restore -l failure: check its exit code.
    toc_out=$(bounded "$TOC_TIMEOUT" docker exec -i "$PG_CONTAINER" pg_restore -l <"$dump" 2>/dev/null)
    toc_rc=$?
    toc_lines=$(printf '%s\n' "$toc_out" | awk 'NF { n++ } END { print n + 0 }')
    if [ "$toc_rc" -ne 0 ]; then
        log "ERROR: pg_restore -l exit=$toc_rc (lines=$toc_lines); the dump cannot be parsed"
        return $EXIT_FREEZE
    fi
    if [ "${toc_lines:-0}" -lt 100 ]; then
        log "ERROR: pg_restore -l returned only ${toc_lines:-0} TOC entries; the dump is not usable"
        return $EXIT_FREEZE
    fi
    jset backup_path "$dump" --once || return $EXIT_FREEZE
    jset backup_sha256 "$sha" --once || return $EXIT_FREEZE
    jset backup_bytes "$size" --once || return $EXIT_FREEZE
    jset backup_toc_lines "$toc_lines" --once || return $EXIT_FREEZE
    jset backup_at "$(date '+%F %T')" --once || return $EXIT_FREEZE
    log "backup ok: $dump sha256=$sha bytes=$size toc=$toc_lines"
    log "the data-loss window for any future recovery starts now (writes frozen)"
    stage_set backup || return $EXIT_FREEZE
    return 0
}

database_url() {
    bounded "$PROBE_TIMEOUT" docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$BACKEND_CONTAINER" 2>/dev/null |
        sed -n 's/^DATABASE_URL=//p' | head -1
}

step_migrate() {
    local dburl rc lm lr tc ix
    log "== migrate: /app/migrate up from the exact .2 backend image (no server, no worker) =="
    dburl=$(database_url)
    if [ -z "$dburl" ]; then
        log "ERROR: cannot read DATABASE_URL from $BACKEND_CONTAINER; migrate was not attempted"
        return $EXIT_MIGRATE
    fi
    log "using DATABASE_URL from $BACKEND_CONTAINER (host=$(printf '%s' "$dburl" | sed 's#.*@##; s#/.*##'))"

    bounded "$MIGRATE_TIMEOUT" docker run --rm --network "$DOCKER_NETWORK" \
        --entrypoint /app/migrate -e DATABASE_URL="$dburl" \
        "ghcr.io/zzttzzmyswy/multica-backend@$PIN_BACKEND_DIGEST_NEW" up
    rc=$?
    log "migrate exit=$rc"
    if [ "$rc" -ne 0 ]; then
        jset migrate_rc "$rc" >/dev/null 2>&1
        log "MIGRATION FAILED. Real state: ledger=$(ledger_max) rows=$(ledger_rows) tables=$(table_count) indexes=$(index_state)"
        log "No automatic continuation and no claim that an intermediate schema is recoverable:"
        log "the site is preserved. Decide with the operator; rollback-r1 restores the old images only."
        return $EXIT_MIGRATE
    fi

    lm=$(ledger_max); lr=$(ledger_rows); tc=$(table_count); ix=$(index_state)
    log "post-migrate: ledger=$lm rows=$lr tables=$tc indexes(ok/invalid/notready)=$ix"
    jset migrate_rc 0 >/dev/null 2>&1
    jset ledger_after "$lm" --once >/dev/null 2>&1
    if [ "$lm" != "$PIN_LEDGER_AFTER" ]; then
        log "ERROR: ledger is '$lm', expected $PIN_LEDGER_AFTER; not continuing on a partial schema"
        return $EXIT_MIGRATE
    fi
    if [ "$lr" != "$PIN_LEDGER_ROWS_AFTER" ]; then
        log "ERROR: ledger row count is '$lr', expected $PIN_LEDGER_ROWS_AFTER"
        return $EXIT_MIGRATE
    fi
    if [ "$tc" != "$PIN_TABLES_AFTER" ]; then
        log "ERROR: table count is '$tc', expected $PIN_TABLES_AFTER"
        return $EXIT_MIGRATE
    fi
    case $ix in
        "$PIN_INDEXES_AFTER/0/0") ;;
        *)
            log "ERROR: index state is '$ix', expected $PIN_INDEXES_AFTER/0/0 (all valid and ready)"
            return $EXIT_MIGRATE
            ;;
    esac
    stage_set migrated || return $EXIT_MIGRATE
    return 0
}

wait_candidate() {
    local deadline body commit
    deadline=$(( $(date +%s) + HEALTH_TIMEOUT ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        body=$(health_body)
        commit=$(health_field "$body" commit)
        if [ -n "$body" ] && [ -n "$commit" ]; then
            printf '%s' "$body"
            return 0
        fi
        sleep "$HEALTH_POLL_INTERVAL"
    done
    return 1
}

assert_container_digest() {
    local name=$1 want=$2 ref got
    ref=$(container_image_ref "$name")
    got=$(digest_of_ref "$ref")
    if [ "$got" != "$want" ]; then
        log "ERROR: $name runs '${ref:-unknown}' (digest ${got:-none}), expected $want"
        return 1
    fi
    return 0
}

step_switch() {
    local rc body commit
    log "== switch: apply the approved compose input with the exact .2 digests =="
    [ -f "$ASSETS/compose/docker-compose.new.yml" ] || { log "ERROR: staged compose input missing"; return $EXIT_CANDIDATE; }
    [ "$(sha256_of "$ASSETS/compose/docker-compose.new.yml")" = "$(jget initial_compose_new_sha256)" ] || {
        log "ERROR: staged compose input no longer matches the hash recorded at prepare"; return $EXIT_CANDIDATE; }

    cp -p "$COMPOSE_FILE" "$ASSETS/compose/docker-compose.pre-switch.yml" 2>/dev/null
    atomic_install "$ASSETS/compose/docker-compose.new.yml" "$COMPOSE_FILE" || {
        log "ERROR: cannot write $COMPOSE_FILE"; return $EXIT_CANDIDATE; }
    [ "$(sha256_of "$COMPOSE_FILE")" = "$(jget initial_compose_new_sha256)" ] || {
        log "ERROR: $COMPOSE_FILE does not match the approved input after the write"; return $EXIT_CANDIDATE; }

    bounded "$UP_TIMEOUT" docker compose -f "$COMPOSE_FILE" -p "$PROJECT" up -d backend frontend
    rc=$?
    log "compose up exit=$rc"
    if [ "$rc" -ne 0 ]; then
        log "ERROR: compose up failed; backend=$(container_status "$BACKEND_CONTAINER")"
        return $EXIT_CANDIDATE
    fi
    if ! body=$(wait_candidate); then
        log "ERROR: no candidate answered $BACKEND_URL with a commit within ${HEALTH_TIMEOUT}s"
        log "  backend=$(container_status "$BACKEND_CONTAINER") frontend=$(container_status "$FRONTEND_CONTAINER")"
        bounded "$PROBE_TIMEOUT" docker logs --tail 20 "$BACKEND_CONTAINER" 2>&1 | while IFS= read -r l; do log "    $l"; done
        return $EXIT_CANDIDATE
    fi
    commit=$(health_field "$body" commit)
    if [ "$commit" != "$PIN_BACKEND_REV_NEW" ]; then
        log "ERROR: candidate reports commit '$commit', expected $PIN_BACKEND_REV_NEW"
        return $EXIT_CANDIDATE
    fi
    assert_container_digest "$BACKEND_CONTAINER" "$PIN_BACKEND_DIGEST_NEW" || return $EXIT_CANDIDATE
    assert_container_digest "$FRONTEND_CONTAINER" "$PIN_WEB_DIGEST_NEW" || return $EXIT_CANDIDATE
    if [ "$(container_running "$FRONTEND_CONTAINER")" != "true" ]; then
        log "ERROR: frontend container is not running (status=$(container_status "$FRONTEND_CONTAINER"))"
        return $EXIT_CANDIDATE
    fi
    jset switched_commit "$commit" --once >/dev/null 2>&1
    log "candidate ok: commit=$commit backend=$PIN_BACKEND_DIGEST_NEW web=$PIN_WEB_DIGEST_NEW"
    stage_set switched || return $EXIT_CANDIDATE
    return 0
}

step_cli() {
    local staged installed_sha installed_ver old_mode old_uid old_gid exec_start
    log "== cli: install the frozen CLI, then the approved upgrade script (backend is already .2) =="
    staged="$ASSETS/cli/unpack/multica"
    [ -x "$staged" ] || { log "ERROR: staged CLI missing at $staged"; return $EXIT_CLI; }
    [ "$(sha256_of "$staged")" = "$(jget cli_binary_sha256)" ] || {
        log "ERROR: staged CLI hash changed since prepare"; return $EXIT_CLI; }

    # The environment assertion comes first: a unit that no longer executes the
    # maintained script must fail this step before any file is replaced.
    exec_start=$(bounded "$PROBE_TIMEOUT" systemctl show -p ExecStart --value "$UPGRADE_SERVICE" 2>/dev/null)
    case $exec_start in
        *"$UPGRADE_SCRIPT"*) ;;
        *) log "ERROR: unit $UPGRADE_SERVICE does not execute $UPGRADE_SCRIPT (ExecStart: ${exec_start:-unreadable})"
           return $EXIT_CLI ;;
    esac

    atomic_install "$staged" "$CLI_BIN" 755 || { log "ERROR: cannot install $CLI_BIN"; return $EXIT_CLI; }
    installed_sha=$(sha256_of "$CLI_BIN")
    if [ "$installed_sha" != "$(jget cli_binary_sha256)" ]; then
        log "ERROR: installed CLI hash $installed_sha does not match the staged binary $(jget cli_binary_sha256)"
        return $EXIT_CLI
    fi
    installed_ver=$("$CLI_BIN" --version 2>/dev/null | head -1 | awk '{print $2}')
    if [ "$installed_ver" != "$PIN_CLI_VERSION_NEW" ]; then
        log "ERROR: installed CLI reports '${installed_ver:-none}', expected $PIN_CLI_VERSION_NEW"
        return $EXIT_CLI
    fi
    jset cli_installed_sha256 "$installed_sha" --once >/dev/null 2>&1
    log "CLI installed: version=$installed_ver sha256=$installed_sha"

    # The approved script replaces the upstream one verbatim, keeping the mode
    # and ownership the old file had so the unit keeps working unchanged.
    old_mode=$(jget initial_upgrade_script_mode 2>/dev/null || true)
    old_uid=$(jget initial_upgrade_script_uid 2>/dev/null || true)
    old_gid=$(jget initial_upgrade_script_gid 2>/dev/null || true)
    [ -n "$old_mode" ] || old_mode=755
    atomic_install "$ASSETS/approved-upgrade-multica.sh" "$UPGRADE_SCRIPT" "$old_mode" || {
        log "ERROR: cannot install $UPGRADE_SCRIPT"; return $EXIT_CLI; }
    if [ -n "$old_uid" ] && [ -n "$old_gid" ] && [ "$(id -u)" = "0" ]; then
        chown "$old_uid:$old_gid" "$UPGRADE_SCRIPT" 2>/dev/null || {
            log "ERROR: cannot restore ownership $old_uid:$old_gid on $UPGRADE_SCRIPT"; return $EXIT_CLI; }
    fi
    if [ "$(sha256_of "$UPGRADE_SCRIPT")" != "$(jget approved_upgrade_sha256)" ]; then
        log "ERROR: $UPGRADE_SCRIPT does not match the approved input hash after install"
        return $EXIT_CLI
    fi

    jset upgrade_script_installed_sha256 "$(sha256_of "$UPGRADE_SCRIPT")" --once >/dev/null 2>&1
    log "approved upgrade script installed: $(sha256_of "$UPGRADE_SCRIPT") (unit entry point verified)"
    stage_set cli || return $EXIT_CLI
    return 0
}

step_verify() {
    local commit lm lr tc ix cli_ver cli_sha body
    log "== verify: version, schema, cli, and that writes are still frozen =="
    body=$(health_body)
    commit=$(health_field "$body" commit)
    lm=$(ledger_max); lr=$(ledger_rows); tc=$(table_count); ix=$(index_state)
    cli_ver=$([ -x "$CLI_BIN" ] && "$CLI_BIN" --version 2>/dev/null | head -1 | awk '{print $2}')
    cli_sha=$([ -f "$CLI_BIN" ] && sha256_of "$CLI_BIN")
    log "  commit=$commit ledger=$lm rows=$lr tables=$tc indexes=$ix cli=${cli_ver:-none}"

    local rc=0
    [ "$commit" = "$PIN_BACKEND_REV_NEW" ] || { log "  MISMATCH: commit"; rc=$EXIT_CANDIDATE; }
    [ "$lm" = "$PIN_LEDGER_AFTER" ] || { log "  MISMATCH: ledger"; rc=$EXIT_MIGRATE; }
    [ "$lr" = "$PIN_LEDGER_ROWS_AFTER" ] || { log "  MISMATCH: ledger rows"; rc=$EXIT_MIGRATE; }
    [ "$tc" = "$PIN_TABLES_AFTER" ] || { log "  MISMATCH: tables"; rc=$EXIT_MIGRATE; }
    case $ix in
        "$PIN_INDEXES_AFTER/0/0") ;;
        *) log "  MISMATCH: indexes $ix"; rc=$EXIT_MIGRATE ;;
    esac
    [ "$cli_ver" = "$PIN_CLI_VERSION_NEW" ] || { log "  MISMATCH: cli version '${cli_ver:-none}'"; rc=$EXIT_CLI; }
    [ "$cli_sha" = "$(jget cli_binary_sha256)" ] || { log "  MISMATCH: cli sha256"; rc=$EXIT_CLI; }
    assert_container_digest "$BACKEND_CONTAINER" "$PIN_BACKEND_DIGEST_NEW" || rc=$EXIT_CANDIDATE
    assert_container_digest "$FRONTEND_CONTAINER" "$PIN_WEB_DIGEST_NEW" || rc=$EXIT_CANDIDATE
    [ "$(unit_state "$DAEMON_UNIT")" != "active" ] || { log "  MISMATCH: daemon is active before thaw"; rc=$EXIT_FREEZE; }
    [ "$rc" -eq 0 ] || return "$rc"
    stage_set verified || return $EXIT_CANDIDATE
    return 0
}

restore_units() {
    local u want now failed=0
    log "== restore daemon/timer states recorded at prepare =="
    for u in "$UPGRADE_TIMER" "$GC_TIMER" "$DAEMON_UNIT"; do
        case $u in
            "$UPGRADE_TIMER") want=$(jget initial_upgrade_timer_state) ;;
            "$GC_TIMER") want=$(jget initial_gc_timer_state) ;;
            *) want=$(jget initial_daemon_state) ;;
        esac
        now=$(unit_state "$u")
        if [ "$want" = "active" ]; then
            if [ "$now" = "active" ]; then
                log "$u already active"
                continue
            fi
            if ! bounded "$STOP_TIMEOUT" systemctl start "$u"; then
                log "ERROR: 'systemctl start $u' failed; state=$(unit_state "$u")"
                failed=1
                continue
            fi
            now=$(unit_state "$u")
            if [ "$now" != "active" ]; then
                log "ERROR: $u did not become active (state=$now)"
                failed=1
            else
                log "$u restored to active"
            fi
        else
            if unit_state_stopped "$now"; then
                log "$u correctly left '$now' (was '$want' at prepare)"
            else
                log "ERROR: $u was '$want' at prepare but is '$now'"
                failed=1
            fi
        fi
    done
    [ "$failed" -eq 0 ] || return $EXIT_ROLLBACK
    return 0
}

step_thaw() {
    restore_units || return $?
    stage_set "done" || return $EXIT_ROLLBACK
    log "maintenance complete: backend/web/CLI on .2, schema 660, services restored"
    return 0
}

# ---------------------------------------------------------------------------
# run
# ---------------------------------------------------------------------------
cmd_run() {
    require_config || return $?
    derive_paths
    if [ "$INTENT" != "switch" ]; then
        log "REFUSE: run requires --intent=switch (got '${INTENT:-none}'); nothing was changed"
        return $EXIT_USAGE
    fi
    if ! : >>"$LOG" 2>/dev/null; then
        printf 'ERROR: log %s is not writable\n' "$LOG" >&2
        return $EXIT_PREPARE
    fi
    acquire_lock || return $?
    journal_guard || return $?

    local stage start
    stage=$(jget stage 2>/dev/null || true)
    case $stage in
        prepared) start=freeze ;;
        frozen) start=backup ;;
        backup) start=migrate ;;
        migrated) start=switch ;;
        switched) start=cli ;;
        cli) start=verify ;;
        verified) start=thaw ;;
        '')
            log "REFUSE: no journal at $JOURNAL; run 'prepare' first"
            return $EXIT_REFUSED
            ;;
        done)
            log "REFUSE: maintenance already completed at $(jget stage_at 2>/dev/null || printf 'unknown')"
            return $EXIT_REFUSED
            ;;
        *)
            log "REFUSE: stage '$stage' is not a switch stage"
            return $EXIT_REFUSED
            ;;
    esac
    log "== run --intent=switch (resuming at '$start', stage '$stage') =="
    log "initial snapshot: compose=$(jget initial_compose_sha256) cli=$(jget initial_cli_sha256) ledger=$(jget initial_ledger_max)"

    local step running=0 rc
    for step in freeze backup migrate switch cli verify thaw; do
        [ "$step" = "$start" ] && running=1
        [ "$running" = 1 ] || continue
        "step_$step"
        rc=$?
        if [ "$rc" -ne 0 ]; then
            record_failure "$step" "$rc"
            report_state
            log "next: fix the reported condition and re-run 'run --intent=switch' (it resumes at '$step'),"
            log "      or restore the pre-change state with 'rollback-r1'"
            return "$rc"
        fi
    done
    return $EXIT_OK
}

# ---------------------------------------------------------------------------
# rollback-r1
# ---------------------------------------------------------------------------
cmd_rollback_r1() {
    require_config || return $?
    derive_paths
    if ! : >>"$LOG" 2>/dev/null; then
        printf 'ERROR: log %s is not writable\n' "$LOG" >&2
        return $EXIT_PREPARE
    fi
    acquire_lock || return $?
    journal_guard || return $?

    local snapshot_compose snapshot_cli snapshot_script
    snapshot_compose=$(jget initial_compose_sha256 2>/dev/null || true)
    snapshot_cli=$(jget initial_cli_sha256 2>/dev/null || true)
    snapshot_script=$(jget initial_upgrade_script_sha256 2>/dev/null || true)
    if [ -z "$snapshot_compose" ]; then
        log "REFUSE: no prepare snapshot in $JOURNAL; cannot restore a state that was never recorded"
        return $EXIT_REFUSED
    fi
    [ -f "$ASSETS/compose/docker-compose.initial.yml" ] || { log "ERROR: snapshot compose file missing under $ASSETS"; return $EXIT_ROLLBACK; }
    [ "$(sha256_of "$ASSETS/compose/docker-compose.initial.yml")" = "$snapshot_compose" ] || {
        log "ERROR: snapshot compose file no longer matches the recorded hash $snapshot_compose"; return $EXIT_ROLLBACK; }

    log "== rollback-r1: restore the pre-change images, compose, cli and upgrade script (database stays) =="
    stage_set rb-stopping || return $EXIT_ROLLBACK
    # Stop writers first: the upgrade timer must not swap the CLI back while we
    # are restoring it, and the old backend must not meet a new schema mid-write.
    stop_writers || { record_failure rollback-r1-stop $?; report_state; return $EXIT_ROLLBACK; }

    stage_set rb-images || return $EXIT_ROLLBACK
    atomic_install "$ASSETS/compose/docker-compose.initial.yml" "$COMPOSE_FILE" || {
        log "ERROR: cannot restore $COMPOSE_FILE"; return $EXIT_ROLLBACK; }
    if [ "$(sha256_of "$COMPOSE_FILE")" != "$snapshot_compose" ]; then
        log "ERROR: $COMPOSE_FILE does not match the recorded snapshot hash after restore"
        report_state; return $EXIT_ROLLBACK
    fi
    local rc body commit
    bounded "$UP_TIMEOUT" docker compose -f "$COMPOSE_FILE" -p "$PROJECT" up -d backend frontend
    rc=$?
    if [ "$rc" -ne 0 ]; then
        log "ERROR: compose up with the restored file exited $rc; backend=$(container_status "$BACKEND_CONTAINER")"
        report_state; return $EXIT_ROLLBACK
    fi
    body=$(wait_candidate) || {
        log "ERROR: restored backend did not answer $BACKEND_URL with a commit within ${HEALTH_TIMEOUT}s"
        report_state; return $EXIT_ROLLBACK; }
    commit=$(health_field "$body" commit)
    if [ "$commit" != "$PIN_BACKEND_REV_OLD" ]; then
        log "ERROR: backend reports commit '$commit', expected the old revision $PIN_BACKEND_REV_OLD"
        report_state; return $EXIT_ROLLBACK
    fi
    assert_container_digest "$BACKEND_CONTAINER" "$(jget initial_backend_digest)" || { report_state; return $EXIT_ROLLBACK; }
    assert_container_digest "$FRONTEND_CONTAINER" "$(jget initial_web_digest)" || { report_state; return $EXIT_ROLLBACK; }
    if [ "$(container_running "$FRONTEND_CONTAINER")" != "true" ]; then
        log "ERROR: frontend is not running after the restore (status=$(container_status "$FRONTEND_CONTAINER"))"
        report_state; return $EXIT_ROLLBACK
    fi
    log "images restored: commit=$commit"

    stage_set rb-cli || return $EXIT_ROLLBACK
    if [ -n "$snapshot_cli" ]; then
        [ -f "$ASSETS/previous/multica" ] || { log "ERROR: CLI snapshot missing under $ASSETS"; return $EXIT_ROLLBACK; }
        [ "$(sha256_of "$ASSETS/previous/multica")" = "$snapshot_cli" ] || {
            log "ERROR: CLI snapshot no longer matches $snapshot_cli"; return $EXIT_ROLLBACK; }
        atomic_install "$ASSETS/previous/multica" "$CLI_BIN" 755 || { log "ERROR: cannot restore $CLI_BIN"; return $EXIT_ROLLBACK; }
        if [ "$(sha256_of "$CLI_BIN")" != "$snapshot_cli" ]; then
            log "ERROR: $CLI_BIN hash is $(sha256_of "$CLI_BIN"), expected $snapshot_cli"; report_state; return $EXIT_ROLLBACK
        fi
        local ver
        ver=$("$CLI_BIN" --version 2>/dev/null | head -1 | awk '{print $2}')
        if [ "$ver" != "$(jget initial_cli_version)" ]; then
            log "ERROR: restored CLI reports '${ver:-none}', expected $(jget initial_cli_version)"; report_state; return $EXIT_ROLLBACK
        fi
        log "cli restored: version=$ver sha256=$snapshot_cli"
    else
        log "note: no CLI existed before prepare; nothing to restore"
    fi

    stage_set rb-script || return $EXIT_ROLLBACK
    if [ -n "$snapshot_script" ]; then
        [ -f "$ASSETS/previous/upgrade-multica.sh" ] || { log "ERROR: upgrade script snapshot missing"; return $EXIT_ROLLBACK; }
        [ "$(sha256_of "$ASSETS/previous/upgrade-multica.sh")" = "$snapshot_script" ] || {
            log "ERROR: upgrade script snapshot no longer matches $snapshot_script"; return $EXIT_ROLLBACK; }
        local mode
        mode=$(jget initial_upgrade_script_mode 2>/dev/null || true)
        [ -n "$mode" ] || mode=755
        atomic_install "$ASSETS/previous/upgrade-multica.sh" "$UPGRADE_SCRIPT" "$mode" || {
            log "ERROR: cannot restore $UPGRADE_SCRIPT"; return $EXIT_ROLLBACK; }
        if [ "$(sha256_of "$UPGRADE_SCRIPT")" != "$snapshot_script" ]; then
            log "ERROR: $UPGRADE_SCRIPT hash is $(sha256_of "$UPGRADE_SCRIPT"), expected $snapshot_script"
            report_state; return $EXIT_ROLLBACK
        fi
        log "upgrade script restored: sha256=$snapshot_script (the timer cannot pull .2 back)"
    else
        log "note: no upgrade script existed before prepare; nothing to restore"
    fi

    stage_set rb-services || return $EXIT_ROLLBACK
    restore_units || { record_failure rollback-r1-services $?; report_state; return $EXIT_ROLLBACK; }
    log "rollback-r1 done: old images/compose/cli/script restored, services back to their prepare states"
    log "database kept: ledger=$(ledger_max) rows=$(ledger_rows) tables=$(table_count)"
    stage_set rolled-back || return $EXIT_OK
    return $EXIT_OK
}

# ---------------------------------------------------------------------------
# rollback-r2: refused by design
# ---------------------------------------------------------------------------
cmd_rollback_r2() {
    log "REFUSE: this executor has no destructive database rollback (exit $EXIT_REFUSED)."
    log "Restoring the pre-change dump over the live database would discard every write since the"
    log "freeze boundary, and row counts in two tables cannot prove the absence of such writes."
    log "Read-only recovery plan for the NAS operator:"
    log "  1. Keep the current database and volume untouched; do not run pg_restore --clean/drop on it."
    log "  2. Create a NEW database (or a new volume) on the same PG 16.15 / vector 0.8.5 instance."
    log "  3. Restore the recorded dump into that new database only:"
    log "     docker exec -i $PG_CONTAINER pg_restore -U ${PG_USER:-multica} -d <new-db> --no-owner --no-privileges < $BACKUP_DIR/<recorded dump>"
    log "     (backup recorded at: $(jget backup_path 2>/dev/null || printf 'none'))"
    log "  4. Verify schema 616, 131 tables, 740 valid indexes, /health on a throwaway old-image instance."
    log "  5. Switch the connection (DATABASE_URL) only through a separate, reviewed operation card."
    log "This executor never runs step 2-5; they need their own approval and their own stop conditions."
    return $EXIT_REFUSED
}

# ---------------------------------------------------------------------------
# status: read-only, no modification lock
# ---------------------------------------------------------------------------
cmd_status() {
    if [ "$CONFIG_LOADED" != 1 ]; then
        apply_readonly_defaults
    fi
    printf 'journal: %s\n' "$JOURNAL"
    printf 'log:     %s\n' "$LOG"
    if [ -f "$JOURNAL" ]; then
        local stage
        stage=$(jget stage 2>/dev/null || printf 'unknown')
        printf 'stage:   %s (%s)\n' "$stage" "$(jget stage_at 2>/dev/null || printf 'unknown')"
        if ! journal_errors >/dev/null 2>&1; then
            printf 'journal: CORRUPT — %s\n' "$(journal_errors | head -1)"
        fi
        if e=$(jget last_error 2>/dev/null); then
            printf 'last error: %s (exit %s at %s)\n' "$e" "$(jget last_error_code 2>/dev/null || printf '?')" \
                "$(jget last_error_at 2>/dev/null || printf '?')"
        fi
        printf -- '--- journal ---\n'
        cat "$JOURNAL"
        printf -- '----------------\n'
    else
        printf 'stage:   (no journal yet; nothing was prepared)\n'
    fi
    if [ -f "$LOG" ]; then
        printf -- '--- log tail ---\n'
        tail -n 15 "$LOG" 2>/dev/null
        printf -- '----------------\n'
    fi
    [ -n "${COMPOSE_FILE:-}" ] && printf 'compose: %s\n' "$COMPOSE_FILE"
    printf 'units:   daemon=%s upgrade_timer=%s upgrade_service=%s gc_timer=%s gc_service=%s\n' \
        "$(unit_state "$DAEMON_UNIT")" "$(unit_state "$UPGRADE_TIMER")" "$(unit_state "$UPGRADE_SERVICE")" \
        "$(unit_state "$GC_TIMER")" "$(unit_state "$GC_SERVICE")"
    printf 'containers: backend=%s frontend=%s\n' "$(container_status "$BACKEND_CONTAINER")" "$(container_status "$FRONTEND_CONTAINER")"
    printf 'images:  backend=%s frontend=%s\n' "$(container_image_ref "$BACKEND_CONTAINER")" "$(container_image_ref "$FRONTEND_CONTAINER")"
    printf 'cli:     %s sha256=%s\n' \
        "$([ -x "$CLI_BIN" ] && "$CLI_BIN" --version 2>/dev/null | head -1 || printf 'missing')" \
        "$([ -f "$CLI_BIN" ] && sha256_of "$CLI_BIN" || printf 'missing')"
    printf 'upgrade script: sha256=%s\n' "$([ -f "$UPGRADE_SCRIPT" ] && sha256_of "$UPGRADE_SCRIPT" || printf 'missing')"
    printf 'database: ledger=%s rows=%s tables=%s indexes=%s\n' \
        "$(ledger_max)" "$(ledger_rows)" "$(table_count)" "$(index_state)"
    printf 'health:  %s\n' "$(health_body)"
    return $EXIT_OK
}

# ---------------------------------------------------------------------------
# Argument parsing and dispatch
# ---------------------------------------------------------------------------
parse_args() {
    while [ $# -gt 0 ]; do
        case $1 in
            --config) CONFIG_FILE=${2:-}; shift 2 || { usage >&2; return $EXIT_USAGE; } ;;
            --config=*) CONFIG_FILE=${1#*=}; shift ;;
            --intent) INTENT=${2:-}; shift 2 || { usage >&2; return $EXIT_USAGE; } ;;
            --intent=*) INTENT=${1#*=}; shift ;;
            -h|--help) usage; exit $EXIT_OK ;;
            *) printf 'unknown argument: %s\n' "$1" >&2; usage >&2; return $EXIT_USAGE ;;
        esac
    done
    return 0
}

main() {
    local cmd=${1:-}
    [ $# -gt 0 ] && shift
    case $cmd in
        prepare|run|rollback-r1)
            parse_args "$@" || return $?
            [ -n "$CONFIG_FILE" ] || { log "REFUSE: '$cmd' requires --config FILE"; usage >&2; return $EXIT_USAGE; }
            load_config "$CONFIG_FILE" || return $EXIT_USAGE
            ;;
        status)
            parse_args "$@" || return $?
            if [ -n "$CONFIG_FILE" ]; then
                load_config "$CONFIG_FILE" || return $EXIT_USAGE
            fi
            ;;
        rollback-r2)
            # Config is optional here: the command changes nothing, it only
            # prints the recorded dump path and the plan.
            parse_args "$@" || return $?
            if [ -n "$CONFIG_FILE" ]; then load_config "$CONFIG_FILE" >/dev/null 2>&1 || true; fi
            if [ "$CONFIG_LOADED" != 1 ]; then apply_readonly_defaults; fi
            cmd_rollback_r2
            return $?
            ;;
        ''|-h|--help|help)
            usage
            [ -n "$cmd" ] && return $EXIT_OK
            return $EXIT_USAGE
            ;;
        *)
            printf 'unknown command: %s\n' "$cmd" >&2
            usage >&2
            return $EXIT_USAGE
            ;;
    esac

    case $cmd in
        prepare) cmd_prepare ;;
        run) cmd_run ;;
        rollback-r1) cmd_rollback_r1 ;;
        status) cmd_status ;;
    esac
}

main "$@"
exit $?
