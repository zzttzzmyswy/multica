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
#   * An image is identified by the image the container runs and the digests that
#     image carries, not by how the compose file spells the reference: the real
#     deployment names `:latest` while running the validated build.
#   * A stage in the journal is a position, not evidence. Every resume re-proves
#     the writers are stopped, the backup is intact and the assets still hash as
#     recorded, and a migration attempt is a latch that needs an operator.
#   * Write commands refuse to run without an explicit config file, so a
#     forgotten parameter can never fall back to a built-in production path.
#
# Stage table. "allowed" is what a re-run may do from that stage; "evidence" is
# what the journal must already hold before anything runs. A stage requires only
# what it has actually finished — never a later stage's facts.
#
#   stage                     allowed        evidence required
#   ------------------------- -------------- --------------------------------
#   (none)                    prepare        -
#   prepared                  freeze         snapshot + staged release inputs
#   frozen                    backup (retry) + freeze_at; writers down, no dump
#   backup                    migrate        + verified dump
#   migrated                  switch         + migration_attempt with
#                                            outcome=verified, plus the
#                                            post-migration schema counters
#   switched                  cli            + the candidate's reported revision
#   cli                       verify         + hashes of both installed files
#   verified                  thaw           same as cli (`verify` adds no new
#                                            fact, it re-proves existing ones)
#   done                      -              terminal
#
# `thaw` is the only step that starts units again, so it repeats the whole final
# acceptance rather than trusting `verified`, and it records that it began so a
# half-restored unit set is recognisable as its own work.
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
DEFAULT_FRONTEND_URL=http://127.0.0.1:3000/
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
FRONTEND_URL=""
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
#
# Without `timeout` there is no ceiling, and a hung systemctl, docker or CLI
# would silently hold the maintenance window open. Refuse instead: a missing or
# non-positive timeout is an execution failure, not an invitation to run
# unbounded.
bounded() {
    local secs=$1
    shift
    case $secs in
        ''|*[!0-9]*)
            log "ERROR: invalid timeout '$secs' for: $*"
            return 124
            ;;
    esac
    if [ "$secs" -le 0 ]; then
        log "ERROR: timeout must be positive, got $secs for: $*"
        return 124
    fi
    if ! have timeout; then
        log "ERROR: 'timeout' is required to bound '$*'; refusing to run it unbounded"
        return 127
    fi
    timeout "$secs" "$@"
}

file_mode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null; }
file_uid()  { stat -c '%u' "$1" 2>/dev/null || stat -f '%u' "$1" 2>/dev/null; }
file_gid()  { stat -c '%g' "$1" 2>/dev/null || stat -f '%g' "$1" 2>/dev/null; }

# cli_version_of <path>: the second field of `<cli> --version`. Bounded, because
# an installed CLI that hangs or waits on stdin must not hold the window open.
cli_version_of() {
    bounded "$PROBE_TIMEOUT" "$1" --version </dev/null 2>/dev/null | head -1 | awk '{print $2}'
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
    # A duplicate key makes the journal ambiguous: two runs could read different
    # values for the same fact, so it is corruption rather than a late write.
    awk 'NF == 0 { next }
         $0 !~ /^[A-Za-z0-9_.-]+=/ { print "malformed line " NR ": " $0; bad = 1; next }
         {
             k = $0
             sub(/=.*/, "", k)
             if (seen[k]++) { print "duplicate key " NR ": " k; bad = 1 }
         }
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

# jcommit <stage> [KEY=VALUE ...]
#
# One journal transition: every fact and the stage itself are written into one
# temp file and renamed once, so a reader sees either the whole transition or
# none of it.
#
# The alternative — a sequence of `jset` calls followed by `stage_set` — leaves
# persisted states the tool has no rule for. A run that wrote
# `migration_outcome=verified` and then failed to commit `stage=migrated` leaves
# `stage=backup / attempt=done / outcome=verified`, which is indistinguishable
# from "never migrated" to a reader that keys off the stage, so the next run
# executed `up` a second time. The same shape applies to a backup whose path and
# hash landed while its byte and TOC counts did not: the stage said the recovery
# point existed.
#
# A transition that carries evidence uses this; nothing may advance a stage and
# then describe it in a later write.
jcommit() {
    local stage=$1
    shift
    case $stage in
        ''|*[!A-Za-z0-9_.-]*) log "ERROR: invalid journal stage '$stage'"; return 1 ;;
    esac
    if [ -e "$JOURNAL" ] && [ ! -f "$JOURNAL" ]; then
        log "ERROR: $JOURNAL exists but is not a regular file"
        return 1
    fi
    local pair k v drop
    # Reject a malformed fact before anything is written: a half-validated
    # transition must not reach the journal at all.
    for pair in "$@"; do
        case $pair in
            *=*) ;;
            *) log "ERROR: jcommit fact '$pair' is not KEY=VALUE"; return 1 ;;
        esac
        k=${pair%%=*}
        v=${pair#*=}
        case $k in
            stage|stage_at)
                log "ERROR: jcommit sets '$k' itself; do not pass it"
                return 1
                ;;
            ''|*[!A-Za-z0-9_.-]*) log "ERROR: invalid journal key '$k'"; return 1 ;;
        esac
        case $v in
            *$'\n'*) log "ERROR: journal value for '$k' contains a newline"; return 1 ;;
        esac
    done

    # Every key this transition owns is dropped from the old content, so the new
    # value is the only one present.
    drop=" stage stage_at "
    for pair in "$@"; do
        drop="$drop${pair%%=*} "
    done

    local tmp="$JOURNAL.tmp.$$"
    {
        if [ -f "$JOURNAL" ]; then
            awk -v drop="$drop" '
                { key = $0; sub(/=.*/, "", key) }
                index(drop, " " key " ") == 0 { print }
            ' "$JOURNAL"
        fi
        for pair in "$@"; do
            printf '%s\n' "$pair"
        done
        printf 'stage=%s\n' "$stage"
        printf 'stage_at=%s\n' "$(date '+%F %T')"
    } >"$tmp" 2>/dev/null || { rm -f "$tmp"; log "ERROR: journal $JOURNAL is not writable"; return 1; }
    if ! mv -f "$tmp" "$JOURNAL" 2>/dev/null; then
        rm -f "$tmp"
        log "ERROR: cannot commit stage '$stage' to $JOURNAL; nothing was recorded"
        return 1
    fi
    log "stage -> $stage"
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
    if [ -z "$actual" ] && [ -f "$JOURNAL" ]; then
        # A journal that exists but cannot name its config is not a fresh start:
        # it is a partial or edited file, and every later stage would be acting
        # on facts nobody recorded.
        log "REFUSE: $JOURNAL has no config_sha256, so it cannot be bound to this deployment"
        log "        an unbound journal cannot prove which host or config its stages belong to"
        return $EXIT_REFUSED
    fi
    if [ -f "$JOURNAL" ] && [ "$actual" != "$want" ]; then
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

# Required journal keys per stage. A stage is only meaningful when every fact the
# later steps rely on is present: without them a truncated or hand-edited journal
# would let `run` resume with an empty snapshot and declare success.
#
# The list is cumulative, and it grows only with what the stage has actually
# finished — never with what a later stage will produce:
#
#   prepared         the snapshot and the staged inputs; nothing has been stopped
#   frozen           + freeze_at; the writers are down, but the dump may not
#                    exist yet (a failed or interrupted pg_dump leaves exactly
#                    this stage, and an operator must be able to retry the dump
#                    from here)
#   backup           + the recorded, verified dump: the recovery point
#   migrated         + migration_attempt with outcome=verified, and the
#                    post-migration schema counters the gate accepted
#   switched         + the revision the candidate reported
#   cli/verified/done + the hashes of the two installed artifacts (`verify` adds
#                    no fact of its own, it re-proves the existing ones)
journal_required_keys() {
    local stage=$1
    # Every stage keeps the prepare snapshot and the staged release inputs.
    printf '%s\n' stage config_sha256 intent stage_at initial_prepared_at
    printf '%s\n' initial_compose_sha256 initial_cli_sha256 initial_upgrade_script_sha256
    printf '%s\n' initial_backend_digest initial_web_digest
    printf '%s\n' initial_daemon_state initial_upgrade_timer_state initial_gc_timer_state
    printf '%s\n' initial_upgrade_service_state initial_gc_service_state
    printf '%s\n' initial_ledger_max initial_ledger_rows initial_tables initial_indexes
    printf '%s\n' initial_backend_image_id initial_web_image_id
    printf '%s\n' cli_binary_sha256 cli_archive_sha256 cli_version_new approved_upgrade_sha256
    case $stage in
        prepared) return 0 ;;
    esac
    # Every stage past `prepared` stopped the writers and says when.
    printf '%s\n' freeze_at
    case $stage in
        frozen) return 0 ;;
    esac
    # From `backup` on there is a recovery point, and it must be described.
    printf '%s\n' backup_path backup_sha256 backup_bytes backup_toc_lines
    case $stage in
        backup) return 0 ;;
    esac
    # From `migrated` on the migration ran and its outcome is a verified schema,
    # not a command's exit status. The attempt key is required too: without it
    # there is no proof the command was ever started under this journal.
    printf '%s\n' migration_attempt migration_outcome migrate_rc ledger_after
    printf '%s\n' migration_ledger_rows migration_tables migration_indexes
    case $stage in
        migrated) return 0 ;;
    esac
    printf '%s\n' switched_commit
    case $stage in
        switched) return 0 ;;
    esac
    # From `cli` on, what was installed is part of the record.
    printf '%s\n' cli_installed_sha256 upgrade_script_installed_sha256
    case $stage in
        done) printf '%s\n' completed_at ;;
    esac
    return 0
}

# journal_complete <stage>: every required key is present, the enumerated values
# are legal, and the recorded stage matches. Returns non-zero on the first gap.
journal_complete() {
    local stage=$1 k v missing=0
    while IFS= read -r k; do
        [ -n "$k" ] || continue
        if ! jget "$k" >/dev/null 2>&1; then
            log "ERROR: journal stage '$stage' is missing required key '$k'"
            missing=1
        fi
    done < <(journal_required_keys "$stage")
    [ "$missing" -eq 0 ] || return 1

    case $(jget intent 2>/dev/null) in
        switch) ;;
        *) log "ERROR: journal intent is '$(jget intent 2>/dev/null)' not 'switch'"; return 1 ;;
    esac
    for k in initial_daemon_state initial_upgrade_timer_state initial_gc_timer_state \
             initial_upgrade_service_state initial_gc_service_state; do
        v=$(jget "$k" 2>/dev/null)
        case $v in
            active|inactive|failed) ;;
            *) log "ERROR: journal $k='$v' is not a legal unit state"; return 1 ;;
        esac
    done
    return 0
}

# journal_stage_ok <expected-stage>: the journal must be complete for that stage
# and actually record it. Any mismatch is a refusal, never a resume.
journal_stage_ok() {
    local want=$1 have
    have=$(jget stage 2>/dev/null || true)
    if [ "$have" != "$want" ]; then
        log "REFUSE: journal stage is '${have:-missing}', expected '$want'"
        return $EXIT_REFUSED
    fi
    journal_complete "$want" || {
        log "REFUSE: journal is incomplete for stage '$want'; refusing to act on it"
        return $EXIT_REFUSED
    }
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
            FRONTEND_URL) FRONTEND_URL=$v ;;
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
    FRONTEND_URL=$DEFAULT_FRONTEND_URL
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
             DAEMON_UNIT UPGRADE_TIMER GC_TIMER BACKEND_URL FRONTEND_URL CLI_BIN \
             UPGRADE_SCRIPT CLI_ARCHIVE APPROVED_UPGRADE_SCRIPT STATE_DIR LOG \
             BACKUP_DIR; do
        eval "v=\${$k:-}"
        [ -n "$v" ] || missing="$missing $k"
    done
    if [ -n "$missing" ]; then
        log "REFUSE: config is incomplete; missing:$missing"
        return $EXIT_USAGE
    fi
    # A zero or missing timeout would make `bounded` run the command with no
    # ceiling at all, which is the one thing this tool must never do during a
    # maintenance window. Require every one of them to be a positive integer.
    for k in STOP_TIMEOUT BACKUP_TIMEOUT TOC_TIMEOUT MIGRATE_TIMEOUT UP_TIMEOUT \
             HEALTH_TIMEOUT QUERY_TIMEOUT PROBE_TIMEOUT HEALTH_POLL_INTERVAL; do
        eval "v=\${$k:-}"
        case $v in
            ''|*[!0-9]*) log "REFUSE: timeout $k must be a positive integer, got '$v'"; return $EXIT_USAGE ;;
        esac
        if [ "$v" -le 0 ]; then
            log "REFUSE: timeout $k must be greater than zero, got $v"
            return $EXIT_USAGE
        fi
    done
    if ! have timeout; then
        log "REFUSE: 'timeout' is required; without it no external call can be bounded"
        return $EXIT_USAGE
    fi
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

# container_image_id: the image ID the container actually runs (.Image). This is
# what identifies the build on a host whose compose file names a moving tag.
container_image_id() {
    bounded "$PROBE_TIMEOUT" docker inspect -f '{{.Image}}' "$1" 2>/dev/null
}

# image_repo_digests <image-id>: every repo digest recorded for that image.
image_repo_digests() {
    bounded "$PROBE_TIMEOUT" docker image inspect -f '{{range .RepoDigests}}{{println .}}{{end}}' "$1" 2>/dev/null
}

# image_is_digest <image-id> <digest>: the local image carries that exact
# content digest. Checked against RepoDigests, because a deployment that pulls
# by tag still records the digest the tag resolved to.
image_is_digest() {
    local id=$1 want=${2#sha256:}
    case $want in
        ''|"$2") return 1 ;;
    esac
    image_repo_digests "$id" | grep -q "@sha256:$want\$"
}

# image_ref_for_digest <image-id> <digest>: the full `repo@sha256:...` string the
# local image itself reports for that digest.
#
# This is the only safe rollback reference. The digest alone says nothing about
# which repository can resolve it: the running build may have been pulled from
# upstream, and rewriting the prefix to this fork's repository would invent a
# reference that nobody has verified exists. What the image reports in
# RepoDigests is exactly the reference the daemon can start it from.
image_ref_for_digest() {
    local id=$1 want=${2#sha256:}
    image_repo_digests "$id" | grep "@sha256:$want\$" | head -1
}

# compose_run <timeout> <file> <compose args...> — the single way this tool
# invokes Docker Compose.
#
# `--project-directory` is not decoration. A real deployment's compose file uses
# `env_file: .env`, `${POSTGRES_PASSWORD}` interpolation and relative bind mounts,
# all of which Compose resolves against the *project* directory, not against the
# directory holding the -f file. Running a snapshot copy from
# `$STATE_DIR/assets/compose` therefore fails with "env file .env not found" and
# silently interpolates secrets to blank. Every call pins the project directory to
# the deployment directory, so a snapshot loads exactly like the original, from
# any snapshot location and any caller cwd.
#
# Passing the arguments directly (no string building) keeps paths with spaces and
# hashes containing shell metacharacters intact.
compose_run() {
    local secs=$1 file=$2
    shift 2
    bounded "$secs" docker compose -f "$file" --project-directory "$COMPOSE_DIR" -p "$PROJECT" "$@"
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

# frontend_ready: the web container answers HTTP at its own URL. A container
# that is "running" but not listening, or answering 5xx, is not a working
# frontend — the service is the response, not the process state.
frontend_status() {
    bounded "$PROBE_TIMEOUT" curl -sS -o /dev/null -w '%{http_code}' \
        --max-time "$PROBE_TIMEOUT" "$FRONTEND_URL" 2>/dev/null
}

frontend_ready() {
    local code
    code=$(frontend_status)
    case $code in
        2*|3*) return 0 ;;
    esac
    log "ERROR: frontend at $FRONTEND_URL answered '${code:-no response}', expected 2xx/3xx"
    return 1
}

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
    cli=$([ -x "$CLI_BIN" ] && cli_version_of "$CLI_BIN")
    cli_sha=$([ -f "$CLI_BIN" ] && sha256_of "$CLI_BIN")
    log "    cli: version=${cli:-missing} sha256=${cli_sha:-missing}"
    log "    upgrade_script: sha256=$([ -f "$UPGRADE_SCRIPT" ] && sha256_of "$UPGRADE_SCRIPT" || printf 'missing')"
    log "    database: ledger=$(ledger_max) rows=$(ledger_rows) tables=$(table_count) indexes=$(index_state)"
    log "    health: $(health_body)"
}

record_failure() {
    local step=$1 code=$2
    log "FAILED at '$step' (exit $code); journal stage stays at '$(jget stage 2>/dev/null || printf 'unknown')' so a re-run resumes here"
    if ! jset last_error "$step failed"; then
        log "WARNING: cannot record the failure in the journal; the log above and the exit code are the record"
        return 0
    fi
    jset last_error_code "$code" >/dev/null 2>&1
    jset last_error_at "$(date '+%F %T')" >/dev/null 2>&1
    return 0
}

# stage_set: advance the journal. A write failure here would leave the run
# believing it is further along than the journal says, so it is fatal: the
# caller must treat a non-zero return as its own failure code.
stage_set() {
    # Stage and its timestamp are one write: two renames could leave a stage with
    # the previous stage's timestamp, and every reader treats stage_at as when the
    # stage was reached. A transition that also carries evidence uses `jcommit`.
    jcommit "$1" || {
        log "ERROR: cannot record stage '$1' in $JOURNAL; aborting rather than continuing unrecorded"
        return 1
    }
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
    ver=$(cli_version_of "$ASSETS/cli/unpack/multica")
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

# resolve_running_identity <container> <want-digest> <label>
#
# Identifies the running build without trusting how the compose file spells it.
# The real NAS keeps `image: ghcr.io/multica-ai/multica-backend:latest` while the
# container actually runs the validated build, so the reference alone says
# nothing. What decides identity is the image ID the container runs plus the
# repo digests recorded for that image.
#
# Sets RESOLVED_REF and RESOLVED_IMAGE_ID. It must not print: every line it logs
# would otherwise be captured by the caller's command substitution.
RESOLVED_REF=""
RESOLVED_IMAGE_ID=""
RESOLVED_VERIFIED_REF=""
resolve_running_identity() {
    local container=$1 want=$2 label=$3 ref id
    ref=$(container_image_ref "$container")
    if [ -z "$ref" ]; then
        log "ERROR: cannot read the $label image reference of container $container"
        return 1
    fi
    id=$(container_image_id "$container")
    if [ -z "$id" ]; then
        log "ERROR: cannot read the $label image ID of container $container"
        return 1
    fi
    if ! image_is_digest "$id" "$want"; then
        log "ERROR: $container runs $ref (image $id), whose repo digests do not include"
        log "       the validated $label digest $want"
        image_repo_digests "$id" | while IFS= read -r d; do log "       recorded: ${d:-none}"; done
        log "       the rollback baseline was gathered on that exact digest; re-verify it on the NAS"
        return 1
    fi
    # The rollback reference comes from the image's own RepoDigests, never from
    # rewriting the compose reference's repository prefix.
    local verified
    verified=$(image_ref_for_digest "$id" "$want")
    if [ -z "$verified" ]; then
        log "ERROR: image $id carries $want but reports no full repo digest for it,"
        log "       so there is no reference proven startable on this host"
        return 1
    fi

    if [ "$(digest_of_ref "$ref")" = "$want" ]; then
        log "$label identity ok: $ref pinned by digest, image $id"
    else
        log "$label identity ok by image ID: compose names $ref, which resolves to image $id carrying $want"
    fi
    log "$label rollback reference (from the image's RepoDigests): $verified"
    RESOLVED_REF=$ref
    RESOLVED_IMAGE_ID=$id
    RESOLVED_VERIFIED_REF=$verified
    return 0
}

# write_rollback_compose <new-file> <backend-ref> <web-ref>
#
# The rollback config pins the old builds by digest. It is derived from the live
# file so nothing else changes, but `latest` never decides what R1 starts: the
# digest written here is the one just proved to be running.
write_rollback_compose() {
    local dest=$1 backend_ref=$2 web_ref=$3
    awk -v be="$backend_ref" -v fe="$web_ref" '
        function indent(line,   copy) {
            copy = line
            sub(/[^ ].*/, "", copy)
            return length(copy)
        }
        /^[[:space:]]*#/ { print; next }
        /^services:[[:space:]]*$/ { in_services = 1; svc_indent = -1; print; next }
        {
            if (in_services && $0 !~ /^[[:space:]]*$/ && indent($0) == 0) in_services = 0
            if (in_services && svc_indent < 0 && $0 ~ /^[[:space:]]+[A-Za-z0-9_.-]+:[[:space:]]*$/) {
                svc_indent = indent($0)
            }
            if (in_services && svc_indent >= 0 && indent($0) == svc_indent && $0 ~ /:[[:space:]]*$/) {
                svc = $0
                sub(/^[[:space:]]+/, "", svc)
                sub(/:.*/, "", svc)
                print
                next
            }
            if (in_services && svc != "" && indent($0) > svc_indent && $0 ~ /^[[:space:]]+image:[[:space:]]*/) {
                if (svc == "backend") { sub(/image:.*/, "image: " be) }
                else if (svc == "frontend" || svc == "web") { sub(/image:.*/, "image: " fe) }
                print
                next
            }
            print
        }
    ' "$COMPOSE_FILE" >"$dest" || return 1
    # Both replacements must have landed exactly once, and no other image line
    # may have moved: a silent no-op would hand R1 the new build again.
    [ "$(grep -cE "^[[:space:]]*image:[[:space:]]*$backend_ref\$" "$dest")" -eq 1 ] || return 1
    [ "$(grep -cE "^[[:space:]]*image:[[:space:]]*$web_ref\$" "$dest")" -eq 1 ] || return 1
    [ "$(grep -cE '^[[:space:]]*image:' "$dest")" -eq "$(grep -cE '^[[:space:]]*image:' "$COMPOSE_FILE")" ] || return 1
    return 0
}

snapshot_state() {
    local backend_ref web_ref backend_id web_id backend_digest web_digest compose_sha
    local rollback_backend_ref rollback_web_ref
    local cli_sha cli_ver script_sha script_mode script_uid script_gid
    log "== snapshot of the pre-change state =="

    resolve_running_identity "$BACKEND_CONTAINER" "$PIN_BACKEND_DIGEST_OLD" backend || return $EXIT_PREPARE
    backend_ref=$RESOLVED_REF
    backend_id=$RESOLVED_IMAGE_ID
    rollback_backend_ref=$RESOLVED_VERIFIED_REF
    resolve_running_identity "$FRONTEND_CONTAINER" "$PIN_WEB_DIGEST_OLD" web || return $EXIT_PREPARE
    web_ref=$RESOLVED_REF
    web_id=$RESOLVED_IMAGE_ID
    rollback_web_ref=$RESOLVED_VERIFIED_REF
    backend_digest=$PIN_BACKEND_DIGEST_OLD
    web_digest=$PIN_WEB_DIGEST_OLD

    compose_sha=$(sha256_of "$COMPOSE_FILE")
    cp -p "$COMPOSE_FILE" "$ASSETS/compose/docker-compose.initial.yml" || return $EXIT_PREPARE
    [ "$(sha256_of "$ASSETS/compose/docker-compose.initial.yml")" = "$compose_sha" ] || {
        log "ERROR: compose snapshot does not match the live file"; return $EXIT_PREPARE; }

    # The live file may name a moving tag. R1 restores *this* file (so the box
    # returns to exactly what it ran before) but starts the containers from a
    # digest-pinned copy built from the references the running images reported.
    # Each of those references is re-resolved here: if it does not exist locally
    # as the same image, prepare fails now instead of after the writers are
    # stopped.
    local rb_id
    rb_id=$(image_id "$rollback_backend_ref")
    if [ -z "$rb_id" ]; then
        log "ERROR: rollback reference $rollback_backend_ref does not resolve locally"
        return $EXIT_PREPARE
    fi
    if [ "$rb_id" != "$backend_id" ]; then
        log "ERROR: $rollback_backend_ref resolves to image $rb_id, but the running backend is $backend_id"
        return $EXIT_PREPARE
    fi
    local rw_id
    rw_id=$(image_id "$rollback_web_ref")
    if [ -z "$rw_id" ]; then
        log "ERROR: rollback reference $rollback_web_ref does not resolve locally"
        return $EXIT_PREPARE
    fi
    if [ "$rw_id" != "$web_id" ]; then
        log "ERROR: $rollback_web_ref resolves to image $rw_id, but the running web container is $web_id"
        return $EXIT_PREPARE
    fi

    write_rollback_compose "$ASSETS/compose/docker-compose.rollback.yml" \
        "$rollback_backend_ref" "$rollback_web_ref" || {
        log "ERROR: cannot derive a digest-pinned rollback compose file from $COMPOSE_FILE"
        return $EXIT_PREPARE; }
    log "rollback compose pins backend=$rollback_backend_ref web=$rollback_web_ref (both verified locally)"

    if [ -f "$CLI_BIN" ]; then
        cp -p "$CLI_BIN" "$ASSETS/previous/multica" || return $EXIT_PREPARE
        cli_sha=$(sha256_of "$CLI_BIN")
        [ "$(sha256_of "$ASSETS/previous/multica")" = "$cli_sha" ] || { log "ERROR: CLI snapshot hash mismatch"; return $EXIT_PREPARE; }
        cli_ver=$(cli_version_of "$CLI_BIN")
        [ -n "$cli_ver" ] || { log "ERROR: cannot read the version of the installed CLI $CLI_BIN"; return $EXIT_PREPARE; }
    else
        cli_sha=""; cli_ver=""
    fi

    if [ -f "$UPGRADE_SCRIPT" ]; then
        script_sha=$(sha256_of "$UPGRADE_SCRIPT")
        cp -p "$UPGRADE_SCRIPT" "$ASSETS/previous/upgrade-multica.sh" || return $EXIT_PREPARE
        [ "$(sha256_of "$ASSETS/previous/upgrade-multica.sh")" = "$script_sha" ] || {
            log "ERROR: upgrade script snapshot hash mismatch"; return $EXIT_PREPARE; }
        script_mode=$(file_mode "$UPGRADE_SCRIPT")
        script_uid=$(file_uid "$UPGRADE_SCRIPT")
        script_gid=$(file_gid "$UPGRADE_SCRIPT")
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

    local d_state ut_state gs_state us_state gc_state
    d_state=$(unit_state "$DAEMON_UNIT")
    ut_state=$(unit_state "$UPGRADE_TIMER")
    gs_state=$(unit_state "$GC_TIMER")
    us_state=$(unit_state "$UPGRADE_SERVICE")
    gc_state=$(unit_state "$GC_SERVICE")
    local pair
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
    for pair in "$UPGRADE_SERVICE=$us_state" "$GC_SERVICE=$gc_state"; do
        if [ "${pair#*=}" = "active" ]; then
            log "ERROR: ${pair%%=*} is running; a timer job is in flight. Wait for it to finish and re-run prepare"
            return $EXIT_PREPARE
        fi
    done

    local lm lr tc ix
    lm=$(ledger_max); lr=$(ledger_rows); tc=$(table_count); ix=$(index_state)
    if [ "$lm" != "$PIN_LEDGER_BEFORE" ]; then
        log "ERROR: ledger is '${lm:-unreadable}', expected the pre-change $PIN_LEDGER_BEFORE"
        return $EXIT_PREPARE
    fi
    if [ "$lr" != "$PIN_LEDGER_ROWS_BEFORE" ] || [ "$tc" != "$PIN_TABLES_BEFORE" ] || [ "$ix" != "$PIN_INDEXES_BEFORE/0/0" ]; then
        log "ERROR: baseline is rows=$lr tables=$tc indexes=$ix, expected"
        log "       rows=$PIN_LEDGER_ROWS_BEFORE tables=$PIN_TABLES_BEFORE indexes=$PIN_INDEXES_BEFORE/0/0"
        return $EXIT_PREPARE
    fi

    local k v
    for k in "backend_image=$backend_ref" "web_image=$web_ref" \
             "backend_image_id=$backend_id" "web_image_id=$web_id" \
             "backend_digest=$backend_digest" "web_digest=$web_digest" \
             "compose_path=$COMPOSE_FILE" "compose_sha256=$compose_sha" \
             "compose_new_sha256=$(sha256_of "$ASSETS/compose/docker-compose.new.yml")" \
             "compose_rollback_sha256=$(sha256_of "$ASSETS/compose/docker-compose.rollback.yml")" \
             "rollback_backend_ref=$rollback_backend_ref" "rollback_web_ref=$rollback_web_ref" \
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
    log "snapshot: images backend=$backend_ref($backend_id) web=$web_ref($web_id)"
    log "snapshot: daemon=$d_state upgrade_timer=$ut_state gc_timer=$gs_state"
    return 0
}

# commit_snapshot <staging-assets> <final-assets> <staging-journal> <final-journal>
#
# The snapshot and the journal that describes it are one commit unit. Publishing
# them separately is what left a first `prepare` failure with a half-written
# journal (initial_* keys, no config_sha256) that no later run would accept: the
# operator's only way out was to delete files by hand.
#
# Order matters and is recoverable at every step:
#   1. move the previous assets aside (still intact on disk),
#   2. publish the new assets,
#   3. publish the journal.
# If step 3 fails the assets are rolled back to the previous copy, so the pair on
# disk is always either the old snapshot with the old journal, or the new
# snapshot with the new journal — never one of each.
commit_snapshot() {
    local staging=$1 final=$2 stage_journal=$3 final_journal=$4
    rm -rf "$final.old"
    if [ -d "$final" ]; then
        mv -f "$final" "$final.old" || { log "ERROR: cannot move the previous snapshot aside"; return 1; }
    fi
    if ! mv -f "$staging" "$final"; then
        log "ERROR: cannot publish the staged snapshot; restoring the previous one"
        [ -d "$final.old" ] && mv -f "$final.old" "$final"
        return 1
    fi
    if ! mv -f "$stage_journal" "$final_journal"; then
        log "ERROR: cannot publish the staged journal; rolling the snapshot back"
        rm -rf "$final"
        [ -d "$final.old" ] && mv -f "$final.old" "$final"
        return 1
    fi
    rm -rf "$final.old"
    return 0
}

# verify_existing_snapshot: read-only re-check of a completed snapshot.
#
# A second `prepare` must never rewrite the pre-change files: the journal keeps
# the first hashes, so overwriting them would leave R1 restoring nothing. This
# re-verifies the assets against those recorded hashes and reports whether the
# live host has since drifted, without touching a byte.
verify_existing_snapshot() {
    local drift=0 k want path got
    [ -n "${VERIFY_SNAPSHOT_QUIET:-}" ] || \
        log "note: a prepared snapshot already exists; re-verifying it read-only (nothing will be rewritten)"

    for k in compose_sha256 cli_sha256 upgrade_script_sha256 compose_new_sha256 compose_rollback_sha256; do
        want=$(jget "initial_$k" 2>/dev/null || true)
        case $k in
            compose_sha256) path=$ASSETS/compose/docker-compose.initial.yml ;;
            compose_new_sha256) path=$ASSETS/compose/docker-compose.new.yml ;;
            compose_rollback_sha256) path=$ASSETS/compose/docker-compose.rollback.yml ;;
            cli_sha256) path=$ASSETS/previous/multica ;;
            upgrade_script_sha256) path=$ASSETS/previous/upgrade-multica.sh ;;
        esac
        [ -n "$want" ] || continue          # recorded as absent at prepare
        if [ ! -f "$path" ]; then
            log "ERROR: snapshot file missing: $path"
            drift=1
            continue
        fi
        got=$(sha256_of "$path")
        if [ "$got" != "$want" ]; then
            log "ERROR: snapshot file $path is $got but the journal recorded $want"
            log "       the snapshot has been modified since prepare; R1 could not restore this item"
            drift=1
        fi
    done
    for k in cli_binary_sha256 approved_upgrade_sha256; do
        want=$(jget "$k" 2>/dev/null || true)
        case $k in
            cli_binary_sha256) path=$ASSETS/cli/unpack/multica ;;
            approved_upgrade_sha256) path=$ASSETS/approved-upgrade-multica.sh ;;
        esac
        [ -n "$want" ] || continue
        if [ ! -f "$path" ]; then
            log "ERROR: staged asset missing: $path"
            drift=1
            continue
        fi
        [ "$(sha256_of "$path")" = "$want" ] || { log "ERROR: staged asset $path no longer matches $want"; drift=1; }
    done
    [ "$drift" -eq 0 ] || return $EXIT_PREPARE

    # The live host is allowed to keep running, but a change to the things the
    # snapshot describes breaks the equivalence R1 relies on.
    local live_compose live_cli live_script
    live_compose=$(sha256_of "$COMPOSE_FILE")
    [ "$live_compose" = "$(jget initial_compose_sha256)" ] || {
        log "ERROR: $COMPOSE_FILE changed after prepare ($live_compose vs $(jget initial_compose_sha256));"
        log "       the recorded snapshot no longer describes this host"
        drift=1
    }
    live_script=$(sha256_of "$UPGRADE_SCRIPT")
    [ "$live_script" = "$(jget initial_upgrade_script_sha256)" ] || {
        log "ERROR: $UPGRADE_SCRIPT changed after prepare ($live_script vs $(jget initial_upgrade_script_sha256));"
        log "       the recorded snapshot no longer describes this host"
        drift=1
    }
    live_cli=$(sha256_of "$CLI_BIN")
    [ "$live_cli" = "$(jget initial_cli_sha256)" ] || {
        log "ERROR: $CLI_BIN changed after prepare ($live_cli vs $(jget initial_cli_sha256))"
        drift=1
    }
    [ "$drift" -eq 0 ] || {
        log "REFUSE: the prepared snapshot no longer matches this host; nothing was rewritten."
        log "        Restore the live files to the recorded versions, or archive $STATE_DIR and start again."
        return $EXIT_PREPARE
    }
    [ -n "${VERIFY_SNAPSHOT_QUIET:-}" ] || \
        log "verify ok: snapshot and live files still match the recorded hashes"
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
        '')
            ;;
        prepared)
            # Never rebuild: the first snapshot is the only true pre-change copy,
            # and the journal still records its hashes. Re-verify it read-only.
            verify_existing_snapshot || return $?
            log "prepare already complete at $(jget initial_prepared_at 2>/dev/null || printf 'unknown'); snapshot kept as recorded"
            return $EXIT_OK
            ;;
        *)
            log "REFUSE: maintenance already reached stage '$stage'; the initial snapshot must not be replaced"
            return $EXIT_REFUSED
            ;;
    esac

    log "== prepare (intent: verify assets and snapshot; no service is stopped) =="
    WORK=$(mktemp -d "$STATE_DIR/tmp.XXXXXX") || { log "ERROR: cannot create a work directory under $STATE_DIR"; return $EXIT_PREPARE; }

    local rc=0 ref staging="$ASSETS.new" stage_journal="$STATE_DIR/journal.new"
    local final_assets=$ASSETS final_journal=$JOURNAL
    rm -rf "$staging"
    rm -f "$stage_journal"
    mkdir -p "$staging" || { rm -rf "$WORK"; return $EXIT_PREPARE; }
    # Everything below writes into the staging copies. The real journal is not
    # touched until the snapshot is complete, so a failure here leaves no
    # half-written state behind: a journal with initial_* keys and no
    # config_sha256 is not resumable and must never reach disk.
    ASSETS=$staging
    JOURNAL=$stage_journal

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
    if [ "$rc" -eq 0 ]; then stage_assets || rc=$?; fi
    if [ "$rc" -eq 0 ]; then snapshot_state || rc=$?; fi
    if [ "$rc" -eq 0 ]; then
        # Every journal key the snapshot implies is written into the staged
        # journal, before the publish, so the pair is complete when it lands.
        jset config_sha256 "$(config_sha256)" || rc=$EXIT_PREPARE
        [ "$rc" -eq 0 ] && { jset intent switch || rc=$EXIT_PREPARE; }
        [ "$rc" -eq 0 ] && { stage_set prepared || rc=$EXIT_PREPARE; }
    fi
    if [ "$rc" -eq 0 ]; then
        commit_snapshot "$staging" "$final_assets" "$stage_journal" "$final_journal" || rc=$EXIT_PREPARE
    fi
    if [ "$rc" -ne 0 ]; then
        rm -rf "$staging"
        rm -f "$stage_journal"
    fi
    ASSETS=$final_assets
    JOURNAL=$final_journal
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
    if ! compose_run "$STOP_TIMEOUT" "$COMPOSE_FILE" stop backend frontend; then
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
    writers_stopped || { log "ERROR: refusing to call the database frozen"; return $EXIT_FREEZE; }
    log "writes frozen: timers+services stopped, daemon stopped, backend/frontend exited"
    return 0
}

# writers_stopped: every writer is provably down right now. Checked before the
# backup and again before migrate, because a resume must not inherit a stage's
# claim: between two runs an operator, a timer or a crash restart can bring the
# API or a oneshot service back.
writers_stopped() {
    local name st running failed=0 u
    for name in "$BACKEND_CONTAINER" "$FRONTEND_CONTAINER"; do
        running=$(container_running "$name")
        st=$(container_status "$name")
        if [ "$running" != "false" ]; then
            log "ERROR: $name is running (status=$st); writes are not frozen"
            failed=1
        fi
    done
    for u in "$DAEMON_UNIT" "$UPGRADE_TIMER" "$UPGRADE_SERVICE" "$GC_TIMER" "$GC_SERVICE"; do
        st=$(unit_state "$u")
        unit_state_stopped "$st" || {
            log "ERROR: $u is '$st'; writes are not frozen"
            failed=1
        }
    done
    [ "$failed" -eq 0 ] || return 1
    return 0
}

step_freeze() {
    local rc
    stop_writers || return $?
    jset freeze_at "$(date '+%F %T')" || { log "ERROR: cannot record freeze_at"; return $EXIT_FREEZE; }
    stage_set frozen || return $EXIT_FREEZE
    return 0
}

# step_backup: the recovery point.
#
# Resumable from `frozen`, because a failed or interrupted pg_dump leaves exactly
# that stage — the writers are down, no dump exists, and the operator's remedy is
# to fix the cause and take the backup, not to start the whole switch again. Two
# rules keep the retry safe:
#
#   * a backup that is already recorded and still matches its hash is *the*
#     recovery point: the step re-confirms the freeze and advances the stage
#     instead of writing a second dump over a good one;
#   * a new dump never overwrites an existing file. The name carries the second
#     it started in, and a collision means a previous attempt's evidence, so the
#     name is made unique rather than reused.
step_backup() {
    local dump stamp rc toc_out toc_rc toc_lines sha size attempt
    log "== final backup (writes are frozen) =="
    # Re-confirm the writers are still stopped right before the dump. A resume
    # from `frozen` must not inherit the earlier run's freeze claim.
    writers_stopped || { log "ERROR: refusing to dump a live database"; return $EXIT_FREEZE; }

    if backup_recorded; then
        # A previous attempt committed this dump in full; re-commit the same facts
        # with the stage, so a journal whose stage did not land is repaired
        # without touching the bytes on disk.
        log "an earlier attempt already recorded this backup; keeping it and continuing"
        jcommit backup \
            "backup_path=$(jget backup_path)" \
            "backup_sha256=$(jget backup_sha256)" \
            "backup_bytes=$(jget backup_bytes)" \
            "backup_toc_lines=$(jget backup_toc_lines)" \
            "backup_at=$(jget backup_at)" || return $EXIT_FREEZE
        return 0
    fi

    stamp=$(date '+%Y%m%d-%H%M%S')
    mkdir -p "$BACKUP_DIR" || { log "ERROR: cannot create $BACKUP_DIR"; return $EXIT_FREEZE; }
    dump="$BACKUP_DIR/multica-pre-myswy2-$stamp.dump"
    attempt=0
    while [ -e "$dump" ]; do
        attempt=$((attempt + 1))
        if [ "$attempt" -gt 99 ]; then
            log "ERROR: cannot find an unused dump name under $BACKUP_DIR; nothing was written"
            return $EXIT_FREEZE
        fi
        dump="$BACKUP_DIR/multica-pre-myswy2-$stamp-$attempt.dump"
    done
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
    # Every fact about this one dump, and the stage that says the recovery point
    # exists, are a single transition. Written separately, a process that died
    # after `backup_sha256` left `stage=frozen` with a half-described backup, and
    # the retry then either reused it (a recovery point with no byte or TOC
    # counts) or generated a second dump and mixed the two.
    if ! jcommit backup \
            "backup_path=$dump" \
            "backup_sha256=$sha" \
            "backup_bytes=$size" \
            "backup_toc_lines=$toc_lines" \
            "backup_at=$(date '+%F %T')"; then
        log "ERROR: the dump is complete but its description could not be committed;"
        log "       stage stays frozen and a re-run will take a fresh backup"
        return $EXIT_FREEZE
    fi
    log "backup ok: $dump sha256=$sha bytes=$size toc=$toc_lines"
    log "the data-loss window for any future recovery starts now (writes frozen)"
    return 0
}

database_url() {
    bounded "$PROBE_TIMEOUT" docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$BACKEND_CONTAINER" 2>/dev/null |
        sed -n 's/^DATABASE_URL=//p' | head -1
}

# backup_usable: the recorded dump is on disk and still matches its hash. Every
# entry point that resumes past the freeze re-proves this instead of trusting
# the stage: without a usable dump there is no recovery point, so migrating
# would strand the site.
# schema_shape: classify the live database as exactly the pre-change schema, the
# post-migration schema, or anything else. R1 may only start the old images on
# one of the two known-good shapes: the old backend fits both (it does not roll
# the ledger back), but a half-migrated schema is understood by neither build
# and has no verified recovery path in this tool.
schema_shape() {
    local lm lr tc ix
    lm=$(ledger_max); lr=$(ledger_rows); tc=$(table_count); ix=$(index_state)
    if [ "$lm" = "$PIN_LEDGER_BEFORE" ] && [ "$lr" = "$PIN_LEDGER_ROWS_BEFORE" ] \
       && [ "$tc" = "$PIN_TABLES_BEFORE" ] && [ "$ix" = "$PIN_INDEXES_BEFORE/0/0" ]; then
        printf 'pre'
        return 0
    fi
    if [ "$lm" = "$PIN_LEDGER_AFTER" ] && [ "$lr" = "$PIN_LEDGER_ROWS_AFTER" ] \
       && [ "$tc" = "$PIN_TABLES_AFTER" ] && [ "$ix" = "$PIN_INDEXES_AFTER/0/0" ]; then
        printf 'post'
        return 0
    fi
    printf 'unknown:ledger=%s rows=%s tables=%s indexes=%s' "${lm:-?}" "${lr:-?}" "${tc:-?}" "${ix:-?}"
    return 0
}

# backup_recorded: a backup is recorded *and* still matches its hash. Silent —
# for steps that ask the question as part of their own logic rather than as a
# precondition failure. `backup_usable` is the logging form.
backup_recorded() {
    local path want got k
    path=$(jget backup_path 2>/dev/null || true)
    want=$(jget backup_sha256 2>/dev/null || true)
    [ -n "$path" ] && [ -n "$want" ] || return 1
    # A recovery point is only recorded when it is fully described. Checking the
    # path and hash alone accepted a half-committed record and then wrote `done`
    # over a backup with no byte count and no TOC.
    for k in backup_bytes backup_toc_lines backup_at; do
        jget "$k" >/dev/null 2>&1 || return 1
    done
    [ -f "$path" ] || return 1
    got=$(sha256_of "$path")
    [ "$got" = "$want" ]
}

backup_usable() {
    local path want got k
    path=$(jget backup_path 2>/dev/null || true)
    want=$(jget backup_sha256 2>/dev/null || true)
    if [ -z "$path" ] || [ -z "$want" ]; then
        log "ERROR: the journal records no backup; there is no recovery point for this switch"
        return 1
    fi
    # A backup the journal only half-describes is not a recovery point. Saying so
    # here keeps a partial record from passing the resume gates that read it.
    for k in backup_bytes backup_toc_lines backup_at; do
        if ! jget "$k" >/dev/null 2>&1; then
            log "ERROR: the recorded backup is incomplete: $k is missing"
            log "        a partially committed backup record cannot stand as the recovery point"
            return 1
        fi
    done
    if [ ! -f "$path" ]; then
        log "ERROR: the recorded backup $path is missing"
        return 1
    fi
    got=$(sha256_of "$path")
    if [ "$got" != "$want" ]; then
        log "ERROR: the recorded backup $path is $got but the journal recorded $want"
        return 1
    fi
    log "backup verified: $path sha256=$got"
    return 0
}

# Migration attempt latch.
#
# `migration_attempt` says a migration command **may** have touched this
# database. It is written before the process starts, because the alternative —
# record the attempt after the command returns — leaves a window in which the
# database has been migrated and the journal says nothing, so the next run would
# treat the same command as a first attempt and run `up` again over an unknown
# schema. Four ways to arrive at that window are all covered by writing first:
#
#   * the process is interrupted (SIGTERM, power loss, a killed supervisor);
#   * the command exits 0 into a schema the gate rejects;
#   * the command exits non-zero;
#   * the outcome cannot be recorded (disk full, journal replaced).
#
# Only `migration_outcome=verified` — written after the command returned 0 AND
# every schema counter matched — lets a later run treat the migration as done.
# Anything else is a latch: `run` refuses before reaching the step again.
MIGRATION_ATTEMPT_NONE=none
MIGRATION_ATTEMPT_PENDING=pending
MIGRATION_ATTEMPT_DONE="done"

migration_attempt_state() { jget migration_attempt 2>/dev/null || printf '%s' "$MIGRATION_ATTEMPT_NONE"; }

migration_outcome_verified() { [ "$(jget migration_outcome 2>/dev/null || true)" = verified ]; }

# migration_settled: no migration command has been started, or the one that was
# started committed a complete verified result together with `stage=migrated`.
#
# This is the only test a resume may use to decide "may the first migration run
# now". `stage=backup` alone is not it: an interrupted commit, a journal from an
# older revision, or a `--once` write that landed without its companions all
# leave the attempt keys behind while the stage still reads `backup`, and running
# `up` over that is exactly the double migration this revision forbids.
# migration_missing_facts: the result keys a settled migration must carry but the
# journal does not hold. Used only for the operator-facing message.
migration_missing_facts() {
    local k
    for k in migration_attempt migration_outcome migrate_rc ledger_after \
             migration_ledger_rows migration_tables migration_indexes migration_verified_at; do
        jget "$k" >/dev/null 2>&1 || printf '%s ' "$k"
    done
    printf '\n'
}

migration_settled() {
    case $(migration_attempt_state) in
        "$MIGRATION_ATTEMPT_NONE") return 0 ;;
    esac
    migration_outcome_verified || return 1
    # A verified outcome is only half the proof: every fact the result consists
    # of must be there, or the commit was partial.
    local k
    for k in migration_attempt migration_outcome migrate_rc ledger_after \
             migration_ledger_rows migration_tables migration_indexes migration_verified_at; do
        jget "$k" >/dev/null 2>&1 || return 1
    done
    return 0
}

step_migrate() {
    local dburl rc lm lr tc ix
    log "== migrate: /app/migrate up from the exact .2 backend image (no server, no worker) =="

    # Both preconditions are re-proved here, not inherited from the stage: a
    # resumed run must not migrate a database whose backup has since been
    # deleted, nor one whose writers have come back.
    backup_usable || { log "ERROR: migrate was not attempted"; return $EXIT_FREEZE; }
    writers_stopped || { log "ERROR: migrate was not attempted; stop the writers first"; return $EXIT_FREEZE; }

    # A migration command that was started and did not commit a complete result
    # has no automatic path forward. This is checked against the journal's real
    # contents, never against the stage alone: an interrupted commit can leave
    # `stage=backup` while `migration_attempt` is already set, and that state must
    # not read as "never migrated".
    if ! migration_settled; then
        log "REFUSE: an earlier migration attempt here never committed a complete, verified result."
        migration_latch_report
        return $EXIT_REFUSED
    fi
    if migration_outcome_verified; then
        log "REFUSE: migration_attempt=$(migration_attempt_state) but stage is '$stage'."
        log "        A verified migration must be recorded with stage=migrated in one write;"
        log "        this journal has the facts without the stage, so it was written by an"
        log "        older or interrupted run. Migrating again over it is not authorised."
        migration_latch_report
        return $EXIT_REFUSED
    fi

    dburl=$(database_url)
    if [ -z "$dburl" ]; then
        log "ERROR: cannot read DATABASE_URL from $BACKEND_CONTAINER; migrate was not attempted"
        return $EXIT_MIGRATE
    fi
    log "using DATABASE_URL from $BACKEND_CONTAINER (host=$(printf '%s' "$dburl" | sed 's#.*@##; s#/.*##'))"

    # The latch reaches disk before the command does. If it cannot be written,
    # the command is not started: an unrecorded attempt is exactly the state a
    # later run would mistake for a clean one.
    if ! jset migration_attempt "$MIGRATION_ATTEMPT_PENDING"; then
        log "ERROR: cannot record the migration attempt in $JOURNAL; migrate was not started"
        return $EXIT_MIGRATE
    fi
    if ! jset migration_attempt_at "$(date '+%F %T')"; then
        log "ERROR: cannot record migration_attempt_at; migrate was not started"
        return $EXIT_MIGRATE
    fi

    bounded "$MIGRATE_TIMEOUT" docker run --rm --network "$DOCKER_NETWORK" \
        --entrypoint /app/migrate -e DATABASE_URL="$dburl" \
        "ghcr.io/zzttzzmyswy/multica-backend@$PIN_BACKEND_DIGEST_NEW" up
    rc=$?
    log "migrate exit=$rc"

    # From here the attempt is on disk whatever happens next. Every path that is
    # not a fully verified schema leaves it without `outcome=verified`.
    lm=$(ledger_max); lr=$(ledger_rows); tc=$(table_count); ix=$(index_state)
    log "post-migrate: ledger=$lm rows=$lr tables=$tc indexes(ok/invalid/notready)=$ix"

    if [ "$rc" -ne 0 ]; then
        jset migrate_rc "$rc" >/dev/null 2>&1
        jset migrate_failed "$rc" >/dev/null 2>&1
        migration_latch_failed "$rc" "$lm" "$lr" "$tc" "$ix"
        log "MIGRATION FAILED. Real state: ledger=$lm rows=$lr tables=$tc indexes=$ix"
        log "No automatic continuation and no claim that an intermediate schema is recoverable:"
        log "the site is preserved. Decide with the operator; rollback-r1 restores the old images only."
        return $EXIT_MIGRATE
    fi

    # The command returned 0. That authorises nothing on its own: a `/app/migrate
    # up` that exits 0 after a partially applied batch leaves a schema neither
    # build can read. The gate is the schema, not the exit status.
    if ! schema_ok; then
        jset migrate_rc 0 >/dev/null 2>&1
        migration_latch_failed "exit 0 but the schema is not the .2 schema" "$lm" "$lr" "$tc" "$ix"
        log "       the command reported success but the schema gate rejected it:"
        log "       an exit status is not evidence; this database is not a verified .2 schema"
        return $EXIT_MIGRATE
    fi

    # Command 0 and every counter verified. The complete result and the stage are
    # one transition: writing the facts first and the stage afterwards is what
    # let a failed last rename leave `stage=backup` with a finished migration
    # recorded, and the next run migrated a second time.
    if ! jcommit migrated \
            "migration_attempt=$MIGRATION_ATTEMPT_DONE" \
            "migration_outcome=verified" \
            "migrate_rc=0" \
            "ledger_after=$lm" \
            "migration_ledger_rows=$lr" \
            "migration_tables=$tc" \
            "migration_indexes=$ix" \
            "migration_verified_at=$(date '+%F %T')"; then
        migration_latch_failed "cannot commit the verified migration result" "$lm" "$lr" "$tc" "$ix"
        log "ERROR: the migration is verified but its result could not be committed with"
        log "       stage=migrated; the attempt stays latched and a re-run will refuse"
        return $EXIT_MIGRATE
    fi
    return 0
}

# migration_latch_failed <reason> <ledger> <rows> <tables> <indexes>
#
# Turns an attempted migration into the state only an operator may leave. The
# attempt key is never cleared and no `outcome=verified` is written, so every
# later `run` refuses before it reaches the step again.
migration_latch_failed() {
    local reason=$1 lm=$2 lr=$3 tc=$4 ix=$5 failed
    # The latch is the attempt key, already on disk before the command ran. These
    # facts describe the failure for the operator; none of them is what makes the
    # next run refuse, so a failure to write them cannot open the door. They are
    # written in one transition anyway, so a reader never sees half a diagnosis.
    failed=$(jget migrate_failed 2>/dev/null || true)
    if ! jcommit "$(jget stage 2>/dev/null || printf 'backup')" \
            "migration_outcome=failed: $reason" \
            "migration_observed=ledger=$lm rows=$lr tables=$tc indexes=$ix" \
            "migrate_failed=${failed:-$reason}"; then
        log "WARNING: cannot record the failure detail; the attempt key is still the latch"
    fi
    # The stage deliberately stays where it was: the position did not advance, and
    # the latch — an attempt without a verified outcome — is what makes a re-run
    # refuse. Moving the stage would suggest a step completed.
    log "MIGRATION NOT VERIFIED ($reason)."
    log "  the attempt is recorded and no verified schema authorises continuing."
    record_failure migrate "$EXIT_MIGRATE"
    return 0
}

# migration_latch_report: what a refused re-run tells the operator. Read-only.
migration_latch_report() {
    local outcome observed
    outcome=$(jget migration_outcome 2>/dev/null || printf 'none')
    observed=$(jget migration_observed 2>/dev/null || true)
    log "        the recorded outcome is '$outcome' (only 'verified' would continue)"
    if [ -n "$observed" ]; then
        log "        schema when the attempt stopped: $observed"
    fi
    log "        schema now: ledger=$(ledger_max) rows=$(ledger_rows) tables=$(table_count) indexes=$(index_state)"
    log "        Re-running is not an automatic licence to continue over a possibly half-migrated"
    log "        database. Inspect the real schema, then hand the decision to the operator:"
    log "        rollback-r1 restores the old images only and refuses an unknown schema shape."
    log "        The pre-change dump is evidence for a separate recovery, not an automatic restore."
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

    compose_run "$UP_TIMEOUT" "$COMPOSE_FILE" up -d backend frontend
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
    # Identity and service, from the same definition `verify` and `thaw` use.
    candidates_ok || return $EXIT_CANDIDATE
    jset switched_commit "$commit" --once || { log "ERROR: cannot record switched_commit"; return $EXIT_CANDIDATE; }
    log "candidate ok: commit=$commit backend=$PIN_BACKEND_DIGEST_NEW web=$PIN_WEB_DIGEST_NEW"
    stage_set switched || return $EXIT_CANDIDATE
    return 0
}

step_cli() {
    local staged installed_sha installed_ver old_mode old_uid old_gid rc=0 code
    log "== cli: install the frozen CLI, then the approved upgrade script (backend is already .2) =="

    # Nothing is replaced until the world this install assumes has been read
    # again. `switch` proved the candidate when it started it; a resume from
    # `switched` runs later, possibly after the backend was rolled back or the
    # frontend died, and replacing the CLI and updater first would mean mutating
    # the deployment on the strength of a stale claim.
    health_ok || rc=$?
    candidates_ok || { code=$?; [ "$rc" -eq 0 ] && rc=$code; }
    schema_ok || { code=$?; [ "$rc" -eq 0 ] && rc=$code; }
    if [ "$rc" -ne 0 ]; then
        log "REFUSE: the candidate is not the verified .2 deployment right now, so nothing was installed."
        log "        A resume re-proves the candidate before it touches the CLI or the updater."
        return "$rc"
    fi

    # The staged sources, verified again immediately before the copy: the state
    # directory is writable between runs, and a script that no longer matches its
    # recorded hash must fail here rather than be installed and detected after.
    staged_assets_ok || {
        log "REFUSE: a staged asset no longer matches the journal, so nothing was installed."
        return $EXIT_CLI
    }
    staged="$ASSETS/cli/unpack/multica"
    [ -x "$staged" ] || { log "ERROR: staged CLI missing at $staged"; return $EXIT_CLI; }

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
    installed_ver=$(cli_version_of "$CLI_BIN")
    if [ "$installed_ver" != "$PIN_CLI_VERSION_NEW" ]; then
        log "ERROR: installed CLI reports '${installed_ver:-none}', expected $PIN_CLI_VERSION_NEW"
        return $EXIT_CLI
    fi
    jset cli_installed_sha256 "$installed_sha" --once || { log "ERROR: cannot record cli_installed_sha256"; return $EXIT_CLI; }
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
    if [ -n "$old_uid" ] && [ -n "$old_gid" ] && [ "$(file_uid "$UPGRADE_SCRIPT")" != "$old_uid" ]; then
        log "ERROR: $UPGRADE_SCRIPT is owned by $(file_uid "$UPGRADE_SCRIPT"):$(file_gid "$UPGRADE_SCRIPT"), expected $old_uid:$old_gid"
        return $EXIT_CLI
    fi
    if [ "$(sha256_of "$UPGRADE_SCRIPT")" != "$(jget approved_upgrade_sha256)" ]; then
        log "ERROR: $UPGRADE_SCRIPT does not match the approved input hash after install"
        return $EXIT_CLI
    fi

    jset upgrade_script_installed_sha256 "$(sha256_of "$UPGRADE_SCRIPT")" --once \
        || { log "ERROR: cannot record upgrade_script_installed_sha256"; return $EXIT_CLI; }
    log "approved upgrade script installed: $(sha256_of "$UPGRADE_SCRIPT") (unit entry point verified)"
    stage_set cli || return $EXIT_CLI
    return 0
}

step_verify() {
    local rc=0 body
    log "== verify: version, schema, cli, and that writes are still frozen =="
    body=$(health_body)
    log "  commit=$(health_field "$body" commit) ledger=$(ledger_max) rows=$(ledger_rows) tables=$(table_count) indexes=$(index_state) cli=$([ -x "$CLI_BIN" ] && cli_version_of "$CLI_BIN")"
    # One definition of acceptance, shared with thaw. Re-listing the checks here
    # is exactly how the previous revision's copies drifted apart.
    final_acceptance || rc=$?
    # verify still runs before thaw, so no writer may have started yet: a daemon
    # that is already up was not frozen for this window.
    if [ "$(unit_state "$DAEMON_UNIT")" = "active" ]; then
        log "  MISMATCH: daemon is active before thaw"
        [ "$rc" -eq 0 ] && rc=$EXIT_FREEZE
    fi
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

# step_thaw: the only step that starts units, so it is the step where a wrong
# answer stops being cheap. Three things make it safe to resume:
#
#   1. it re-runs the complete final acceptance *before* any unit starts — a
#      previous run's `verified` says nothing about the CLI, the frontend or the
#      backup now;
#   2. it records `thaw_started`, so a run interrupted half-way is recognisable
#      as thaw's own partial work rather than as unexplained drift;
#   3. `restore_units` skips a unit already in its recorded state, so a resumed
#      thaw neither starts a restored unit twice nor mistakes a normal part-way
#      restore for a failure.
step_thaw() {
    local rc=0
    log "== thaw: re-accept the live system, then restore the recorded unit states =="
    final_acceptance
    rc=$?
    if [ "$rc" -ne 0 ]; then
        log "REFUSE: the final acceptance does not hold now, so no unit was started."
        log "        A previous 'verified' stage is not permission to release the writers: the"
        log "        CLI, the containers, the schema or the recorded backup changed since then."
        record_failure thaw "$rc"
        report_state
        return "$rc"
    fi
    if jget thaw_started >/dev/null 2>&1; then
        log "note: an earlier thaw began at $(jget thaw_started); units already in their recorded state are left alone"
    fi
    if ! jset thaw_started "$(date '+%F %T')" --once; then
        log "ERROR: cannot record thaw_started; refusing to start units unrecorded"
        return $EXIT_ROLLBACK
    fi
    restore_units
    rc=$?
    if [ "$rc" -ne 0 ]; then
        record_failure thaw "$rc"
        report_state
        return "$rc"
    fi
    # The units are back, but the acceptance must still hold with them running:
    # a daemon that comes up against a wrong schema would answer health and look
    # restored. This is the last read before `done` is written.
    final_acceptance
    rc=$?
    if [ "$rc" -ne 0 ]; then
        log "REFUSE: the units are restored but the acceptance no longer holds; not recording 'done'."
        record_failure thaw "$rc"
        report_state
        return "$rc"
    fi
    # `done` is the only stage that tells the operator the window is closed, so it
    # is written last and read back. A journal missing one of its facts — the
    # half-written record a failed `--once` write leaves — must not be reported as
    # a completed maintenance just because every live check passed.
    if ! jcommit "done" "completed_at=$(date '+%F %T')"; then
        log "ERROR: the maintenance succeeded but the terminal stage could not be recorded"
        return $EXIT_ROLLBACK
    fi
    if ! journal_complete "done"; then
        log "REFUSE: the terminal journal is incomplete after the final write; not reporting"
        log "        a completed maintenance. The live system is in its final state, but the"
        log "        record of it is not, so the next reader cannot trust the stage."
        return $EXIT_ROLLBACK
    fi
    log "maintenance complete: backend/web/CLI on .2, schema 660, services restored"
    return 0
}

# ---------------------------------------------------------------------------
# run
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Shared acceptance checks.
#
# Every gate that decides "this deployment is on .2 and healthy" is expressed
# once, here, and called from `switch`, `verify` and `thaw`. The previous
# revision wrote the same intent three times and the copies disagreed: the late
# resume path returned 0 without running any of them, so a resumed run could
# report success over an old CLI, a stopped frontend and a deleted backup. A
# resume must re-run the *same* checks as the first pass, not a summary of what
# the first pass concluded.
#
# The functions here never read the journal's `stage`: a stage is a position, and
# these are the measurements that decide whether a position may be left.
# ---------------------------------------------------------------------------

# health_ok: the backend answers /health with the exact .2 revision.
health_ok() {
    local body commit
    body=$(health_body)
    commit=$(health_field "$body" commit)
    if [ -z "$body" ] || [ -z "$commit" ]; then
        log "  MISMATCH: no backend commit at $BACKEND_URL"
        return $EXIT_CANDIDATE
    fi
    if [ "$commit" != "$PIN_BACKEND_REV_NEW" ]; then
        log "  MISMATCH: commit '${commit}' (expected $PIN_BACKEND_REV_NEW)"
        return $EXIT_CANDIDATE
    fi
    return 0
}

# schema_ok: the live database is exactly the post-migration schema. One
# definition, so `migrate`, `verify` and `thaw` cannot disagree about what the
# .2 schema is.
schema_ok() {
    local lm lr tc ix rc=0
    lm=$(ledger_max); lr=$(ledger_rows); tc=$(table_count); ix=$(index_state)
    if [ "$lm" != "$PIN_LEDGER_AFTER" ]; then
        log "  MISMATCH: ledger: ledger is '$lm', expected $PIN_LEDGER_AFTER"
        rc=$EXIT_MIGRATE
    fi
    if [ "$lr" != "$PIN_LEDGER_ROWS_AFTER" ]; then
        log "  MISMATCH: ledger rows: ledger row count is '$lr', expected $PIN_LEDGER_ROWS_AFTER"
        rc=$EXIT_MIGRATE
    fi
    if [ "$tc" != "$PIN_TABLES_AFTER" ]; then
        log "  MISMATCH: tables: table count is '$tc', expected $PIN_TABLES_AFTER"
        rc=$EXIT_MIGRATE
    fi
    case $ix in
        "$PIN_INDEXES_AFTER/0/0") ;;
        *) log "  MISMATCH: indexes: index state is '$ix', expected $PIN_INDEXES_AFTER/0/0 (all valid and ready)"
           rc=$EXIT_MIGRATE ;;
    esac
    return "$rc"
}

# candidates_ok: both containers run the exact .2 digests, the frontend process
# is up, and it answers HTTP. Running is not serving, so all three are asked.
candidates_ok() {
    local rc=0
    assert_container_digest "$BACKEND_CONTAINER" "$PIN_BACKEND_DIGEST_NEW" || rc=$EXIT_CANDIDATE
    assert_container_digest "$FRONTEND_CONTAINER" "$PIN_WEB_DIGEST_NEW" || rc=$EXIT_CANDIDATE
    if [ "$(container_running "$FRONTEND_CONTAINER")" != "true" ]; then
        log "  MISMATCH: $FRONTEND_CONTAINER is not running (status=$(container_status "$FRONTEND_CONTAINER"))"
        rc=$EXIT_CANDIDATE
    fi
    frontend_ready || { log "  MISMATCH: frontend is not serving"; rc=$EXIT_CANDIDATE; }
    return "$rc"
}

# cli_ok: the installed CLI is byte-identical to the staged binary and reports
# the pinned version. Both are reported: the hash proves what was installed, and
# `--version` proves the binary that claims to carry it.
cli_ok() {
    local want sha ver rc=0
    want=$(jget cli_binary_sha256 2>/dev/null || true)
    if [ -z "$want" ]; then
        log "  MISMATCH: the journal records no cli_binary_sha256"
        return $EXIT_CLI
    fi
    if [ ! -x "$CLI_BIN" ]; then
        log "  MISMATCH: $CLI_BIN is missing or not executable"
        return $EXIT_CLI
    fi
    sha=$(sha256_of "$CLI_BIN")
    ver=$(cli_version_of "$CLI_BIN")
    if [ "$ver" != "$PIN_CLI_VERSION_NEW" ]; then
        log "  MISMATCH: cli version '${ver:-none}' (expected $PIN_CLI_VERSION_NEW)"
        rc=$EXIT_CLI
    fi
    if [ "$sha" != "$want" ]; then
        log "  MISMATCH: cli sha256 is ${sha:-none}, expected $want"
        rc=$EXIT_CLI
    fi
    return "$rc"
}

# upgrade_script_ok: the installed script is the approved input, and the oneshot
# unit still executes that path. A verified script no unit runs is a dead
# callback: the next real upgrade would silently use the old entry point.
upgrade_script_ok() {
    local want sha exec_start
    want=$(jget approved_upgrade_sha256 2>/dev/null || true)
    if [ -z "$want" ]; then
        log "  MISMATCH: the journal records no approved_upgrade_sha256"
        return $EXIT_CLI
    fi
    if [ ! -f "$UPGRADE_SCRIPT" ]; then
        log "  MISMATCH: $UPGRADE_SCRIPT is missing"
        return $EXIT_CLI
    fi
    sha=$(sha256_of "$UPGRADE_SCRIPT")
    if [ "$sha" != "$want" ]; then
        log "  MISMATCH: upgrade script sha256 is ${sha:-none}, expected $want"
        return $EXIT_CLI
    fi
    exec_start=$(bounded "$PROBE_TIMEOUT" systemctl show -p ExecStart --value "$UPGRADE_SERVICE" 2>/dev/null)
    case $exec_start in
        *"$UPGRADE_SCRIPT"*) ;;
        *) log "  MISMATCH: unit $UPGRADE_SERVICE does not execute $UPGRADE_SCRIPT (ExecStart: ${exec_start:-unreadable})"
           return $EXIT_CLI ;;
    esac
    return 0
}

# staged_assets_ok: the two artifacts the remaining steps install still hash as
# recorded. Checked before any step that installs them and again by the final
# acceptance, because the state directory is writable between runs.
staged_assets_ok() {
    local k want path got rc=0
    for k in cli_binary_sha256 approved_upgrade_sha256; do
        want=$(jget "$k" 2>/dev/null || true)
        case $k in
            cli_binary_sha256) path=$ASSETS/cli/unpack/multica ;;
            approved_upgrade_sha256) path=$ASSETS/approved-upgrade-multica.sh ;;
        esac
        if [ -z "$want" ]; then
            log "ERROR: the journal records no $k; there is nothing verified left to install"
            rc=1
            continue
        fi
        if [ ! -f "$path" ]; then
            log "ERROR: staged asset for $k is missing: $path"
            rc=1
            continue
        fi
        got=$(sha256_of "$path")
        if [ "$got" != "$want" ]; then
            log "ERROR: staged asset $path is $got but the journal recorded $want"
            rc=1
        fi
    done
    return "$rc"
}

# prepared_state_ok: the read-only re-verification a resume needs before its
# first side effect. It is the same comparison `prepare` makes when it re-checks
# an existing snapshot — the journal's recorded hashes against the files on disk
# — plus the two staged release inputs that `cli` will install later.
#
# It deliberately reuses `verify_existing_snapshot` rather than restating the
# list: a second copy of "what the snapshot consists of" is what let this check
# and the install-time check drift apart.
prepared_state_ok() {
    # `verify_existing_snapshot` already covers the snapshot files, the two
    # staged release inputs, and the live host files the snapshot describes, and
    # it logs exactly which item drifted. Reusing it keeps one definition of
    # "what the snapshot consists of" instead of a second copy that can drift.
    local rc=0
    VERIFY_SNAPSHOT_QUIET=1 verify_existing_snapshot || rc=1
    # One line on success, so the operator can see the window was opened on
    # verified state; the item-by-item detail would only repeat prepare's output.
    [ "$rc" -ne 0 ] || log "prepared state re-verified: snapshot, staged assets and host binding all match the journal"
    return "$rc"
}

# final_acceptance: everything a `done` journal is allowed to mean, measured on
# the live system. Called by `verify`, by `thaw` before it starts anything, and
# by `thaw` again after the units are back — the last read before `done` is
# written. It never consults the journal's stage.
final_acceptance() {
    local rc=0 code
    health_ok || rc=$?
    schema_ok || { code=$?; [ "$rc" -eq 0 ] && rc=$code; }
    candidates_ok || { code=$?; [ "$rc" -eq 0 ] && rc=$code; }
    cli_ok || { code=$?; [ "$rc" -eq 0 ] && rc=$code; }
    upgrade_script_ok || { code=$?; [ "$rc" -eq 0 ] && rc=$code; }
    staged_assets_ok || { [ "$rc" -eq 0 ] && rc=$EXIT_CLI; }
    # The recovery point is part of what `done` claims: a completed window that
    # has lost its dump is not a completed window, and thaw is the last moment
    # at which saying so is still cheap.
    backup_usable || { [ "$rc" -eq 0 ] && rc=$EXIT_FREEZE; }
    return "$rc"
}

# ---------------------------------------------------------------------------
# resume_preconditions <stage> <first-step>
#
# A stage in the journal says what a previous run got through; it does not say
# the world still looks like that. Before any step runs, this re-proves — per
# stage — every fact the remaining steps will rely on, using the same checks the
# original pass used:
#
#   * before the application is started (backup/migrate/switch): every writer is
#     still down, and the recorded dump still exists and matches its hash;
#   * the staged CLIs and scripts still hash as recorded;
#   * a migration attempt without a verified outcome is a latch, not a
#     checkpoint to step over;
#   * from `switched` on the candidate is re-measured: the installed CLI, the
#     upgrade script and its unit entry point;
#   * at `verified` (i.e. before thaw) the whole final acceptance runs again.
#     A previous run's `verified` authorises nothing about now; it is thaw's
#     input, and thaw starts units.
resume_preconditions() {
    local stage=$1 start=$2 outcome observed failed

    # `freeze` is the first side effect of the window: it stops five units and
    # the two containers. Before that happens, the snapshot, the staged release
    # inputs and the host binding must still be exactly what prepare recorded.
    #
    # `journal_complete` only proves the keys are present — it says nothing about
    # whether the files those keys describe still match. Without this, a tampered
    # staged updater was discovered by the `cli` step after the writers had been
    # stopped and the migration had run.
    case $start in
        freeze)
            prepared_state_ok || {
                log "REFUSE: the prepared snapshot, the staged assets or the host binding"
                log "        no longer match the journal, so nothing was stopped or changed."
                log "        Restore the recorded versions, or archive $STATE_DIR and prepare again."
                return 1
            }
            return 0
            ;;
    esac

    # Everything up to and including `switch` runs with the application down:
    # the backup and the migration both require it, and the writers may have been
    # restarted by an operator, a timer or a crash between runs.
    case $start in
        backup|migrate|switch)
            writers_stopped || {
                log "REFUSE: stage '$stage' precedes the application start, but the writers are running now."
                log "        Stop them again (or re-run from a clean state) before continuing; nothing was changed."
                return 1
            }
            ;;
    esac

    # Two questions, not one: has a migration command been started, and if so did
    # it commit a complete verified result?
    #
    #   * `backup` with no attempt is a clean, normally-reached boundary — the
    #     window was frozen and dumped, and the first migration has not run. It
    #     must be resumable; requiring a verified outcome here made the ordinary
    #     "stopped before the migration" case unrecoverable.
    #   * `backup` with an attempt that never committed is a latch.
    #   * `migrated` and later require the complete committed result.
    #
    # The stage is deliberately not the input to this decision alone; see
    # migration_settled.
    if ! migration_settled; then
        outcome=$(jget migration_outcome 2>/dev/null || printf 'none')
        observed=$(jget migration_observed 2>/dev/null || true)
        failed=$(jget migrate_failed 2>/dev/null || true)
        if [ -n "$failed" ]; then
            log "REFUSE: a migration already failed here (migrate_failed=$failed)."
        else
            log "REFUSE: a migration was started here and never committed a complete verified result."
        fi
        log "        (migration_attempt=$(migration_attempt_state), outcome=$outcome)."
        # Only meaningful for a verified-but-partial record; a failed attempt has
        # no result to be missing.
        if migration_outcome_verified; then
            log "        the result is incomplete: $(migration_missing_facts | tr '\n' ' ')"
            log "        a verified migration must be committed with stage=migrated in one write;"
            log "        this journal has the outcome without its facts, so it was interrupted"
        fi
        if [ -n "$observed" ]; then
            log "        schema when the attempt stopped: $observed"
        fi
        log "        schema now: ledger=$(ledger_max) rows=$(ledger_rows) tables=$(table_count) indexes=$(index_state)"
        log "        Re-running is not an automatic licence to continue over a possibly half-migrated"
        log "        database. rollback-r1 restores the old images only and refuses an unknown schema"
        log "        shape. Inspect the real schema and hand the decision to the operator."
        return 1
    fi
    # `backup` and `migrate` both run *before* a committed migration: `backup`
    # is the stage, `migrate` is the step it maps to. Neither may demand a
    # verified outcome — that is the transition they are about to make.
    case $start in
        backup|migrate) ;;
        *)
            # Past the migration, the settled result is a precondition, not an
            # optional fact: without it the stage claims a step nobody proved.
            migration_outcome_verified || {
                log "REFUSE: stage '$stage' claims the migration finished, but this journal records"
                log "        no verified attempt (migration_attempt=$(migration_attempt_state))."
                log "        Nothing was changed; the migration has not been proved to have run."
                return 1
            }
            ;;
    esac

    # From `migrate` on there is a recovery point to re-prove. (The migrate step
    # re-checks it too; here it fails before any step is entered.)
    case $start in
        backup) ;;
        *)
            backup_usable || {
                log "REFUSE: stage '$stage' claims a final backup exists, but it is missing or altered."
                log "        Without a recovery point the switch cannot continue; nothing was changed."
                return 1
            }
            ;;
    esac
    case $start in
        migrate) return 0 ;;
    esac

    # `cli` installs from the staged assets, so they must still hash as recorded
    # before it replaces anything on the host.
    case $start in
        cli)
            staged_assets_ok || {
                log "REFUSE: the staged CLI or approved upgrade script no longer matches the journal;"
                log "        cli cannot install what it cannot verify. Nothing was changed."
                return 1
            }
            ;;
    esac

    # `verify` and `thaw` both run the full acceptance themselves — verify as its
    # own work, thaw because starting units on a stale acceptance is the failure
    # this revision exists to prevent. Running it here as well would only mean a
    # resumed run reports the refusal instead of the specific mismatch, so the
    # check stays in the step that owns it.
    return 0
}

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

    # The stage is a position, not evidence. Every fact the remaining steps rely
    # on is re-proved here, so a resumed run cannot inherit a claim that has
    # since stopped being true.
    journal_complete "$stage" || {
        log "REFUSE: the journal is incomplete for stage '$stage'; it cannot authorise continuing"
        return $EXIT_REFUSED
    }
    resume_preconditions "$stage" "$start" || return $EXIT_REFUSED

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
            if [ "$step" = "migrate" ]; then
                log "next: the schema state must be reviewed by the operator before anything else runs."
                log "      Do not re-run this command as a way past a failed migration."
                log "      rollback-r1 restores the old images (database kept) and refuses an unknown schema shape."
            else
                log "next: fix the reported condition and re-run 'run --intent=switch' (it resumes at '$step'),"
                log "      or restore the pre-change state with 'rollback-r1'"
            fi
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

    # R1 restores what `prepare` recorded. A journal without a complete prepared
    # stage describes no such state, so there is nothing to restore from.
    journal_complete prepared || {
        log "REFUSE: the journal has no complete prepare snapshot; R1 cannot restore an unrecorded state"
        return $EXIT_REFUSED
    }

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

    # The old backend is verified against the 616 and the 660 schema, not against
    # whatever a half-finished migration left behind. Starting it on an unknown
    # shape and reporting success because /health answers would hide a database
    # that neither build understands.
    local shape
    shape=$(schema_shape)
    case $shape in
        pre|post)
            log "current schema shape: $shape (verified for the old backend)"
            ;;
        *)
            log "REFUSE: the database shape is not a verified one: $shape"
            log "        R1 only starts the old images on the complete 616 or 660 schema."
            log "        Nothing was changed: the writers stay as they are, and the database keeps the"
            log "        evidence a manual NAS recovery needs. Hand this state to the operator."
            return $EXIT_REFUSED
            ;;
    esac

    backup_usable || log "WARNING: no usable backup is recorded; R1 keeps the current database anyway"

    stage_set rb-stopping || return $EXIT_ROLLBACK
    # Stop writers first: the upgrade timer must not swap the CLI back while we
    # are restoring it, and the old backend must not meet a new schema mid-write.
    stop_writers || { record_failure rollback-r1-stop $?; report_state; return $EXIT_ROLLBACK; }

    stage_set rb-images || return $EXIT_ROLLBACK

    # Two files, two jobs. The live file goes back to exactly what the box ran
    # before (so a later inspection sees the original configuration), but the
    # containers are started from the digest-pinned copy, because a compose file
    # naming a moving tag would let `latest` decide which build comes back.
    local rollback_compose="$ASSETS/compose/docker-compose.rollback.yml" rollback_sha
    rollback_sha=$(jget initial_compose_rollback_sha256 2>/dev/null || true)
    if [ ! -f "$rollback_compose" ]; then
        log "ERROR: the digest-pinned rollback compose file is missing: $rollback_compose"
        return $EXIT_ROLLBACK
    fi
    if [ -n "$rollback_sha" ] && [ "$(sha256_of "$rollback_compose")" != "$rollback_sha" ]; then
        log "ERROR: $rollback_compose no longer matches the hash recorded at prepare ($rollback_sha)"
        report_state; return $EXIT_ROLLBACK
    fi

    atomic_install "$ASSETS/compose/docker-compose.initial.yml" "$COMPOSE_FILE" || {
        log "ERROR: cannot restore $COMPOSE_FILE"; return $EXIT_ROLLBACK; }
    if [ "$(sha256_of "$COMPOSE_FILE")" != "$snapshot_compose" ]; then
        log "ERROR: $COMPOSE_FILE does not match the recorded snapshot hash after restore"
        report_state; return $EXIT_ROLLBACK
    fi
    local rc body commit
    # The rollback file lives under the state directory; the project directory
    # still has to be the deployment's, or its .env and env_file resolve against
    # the snapshot instead of the real configuration.
    compose_run "$UP_TIMEOUT" "$rollback_compose" up -d backend frontend
    rc=$?
    if [ "$rc" -ne 0 ]; then
        log "ERROR: compose up with the rollback file exited $rc; backend=$(container_status "$BACKEND_CONTAINER")"
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
    frontend_ready || { report_state; return $EXIT_ROLLBACK; }
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
        ver=$(cli_version_of "$CLI_BIN")
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
        local mode uid gid
        mode=$(jget initial_upgrade_script_mode 2>/dev/null || true)
        uid=$(jget initial_upgrade_script_uid 2>/dev/null || true)
        gid=$(jget initial_upgrade_script_gid 2>/dev/null || true)
        [ -n "$mode" ] || mode=755
        atomic_install "$ASSETS/previous/upgrade-multica.sh" "$UPGRADE_SCRIPT" "$mode" || {
            log "ERROR: cannot restore $UPGRADE_SCRIPT"; return $EXIT_ROLLBACK; }
        # The forward path restores ownership; the rollback must undo it the same
        # way, or the unit runs a file the wrong user owns.
        if [ -n "$uid" ] && [ -n "$gid" ] && [ "$(id -u)" = "0" ]; then
            chown "$uid:$gid" "$UPGRADE_SCRIPT" 2>/dev/null || {
                log "ERROR: cannot restore ownership $uid:$gid on $UPGRADE_SCRIPT"; return $EXIT_ROLLBACK; }
        fi
        if [ -n "$uid" ] && [ -n "$gid" ] && [ "$(file_uid "$UPGRADE_SCRIPT")" != "$uid" ]; then
            log "ERROR: $UPGRADE_SCRIPT is owned by $(file_uid "$UPGRADE_SCRIPT"):$(file_gid "$UPGRADE_SCRIPT"), expected $uid:$gid"
            report_state; return $EXIT_ROLLBACK
        fi
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
    # A journal that cannot record the terminal state means the next reader
    # cannot tell this rollback finished, so the exit code must not claim it did.
    stage_set rolled-back || return $EXIT_ROLLBACK
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
        "$([ -x "$CLI_BIN" ] && cli_version_of "$CLI_BIN" || printf 'missing')" \
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
