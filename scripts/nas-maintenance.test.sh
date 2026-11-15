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
        "$CUR/state/images" "$CUR/scripts" "$CUR/compose" "$CUR/backup" \
        "$CUR/state-dir" "$CUR/work" "$CUR/cli-bin"
    : >"$CUR/state/calls.log"
    : >"$CUR/state/exec.log"
    : >"$CUR/state/compose.log"

    set_unit multica-daemon active
    set_unit multica-upgrade.timer active
    set_unit multica-upgrade.service inactive
    set_unit multica-attachment-gc.timer active
    set_unit multica-attachment-gc.service inactive
    # The old builds are present locally and carry their release digests, and
    # the two containers run them. That is the shape prepare verifies identity
    # against — not how the compose file happens to spell the reference.
    image_carries "$BACKEND_IMAGE_OLD" "ghcr.io/zzttzzmyswy/multica-backend" "$BACKEND_DIGEST_OLD"
    image_carries "$WEB_IMAGE_OLD" "ghcr.io/zzttzzmyswy/multica-web" "$WEB_DIGEST_OLD"
    image_carries "$BACKEND_IMAGE_NEW" "ghcr.io/zzttzzmyswy/multica-backend" "$BACKEND_DIGEST_NEW"
    image_carries "$WEB_IMAGE_NEW" "ghcr.io/zzttzzmyswy/multica-web" "$WEB_DIGEST_NEW"
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

# image_id_of_ref mirrors the docker stub: the same reference on the same host
# is the same image, and the digest table records what that image carries.
image_id_of_ref() {
    printf 'image-id-%s\n' "$(printf '%s' "$1" | cksum | awk '{print $1}')"
}

# key_of_ref mirrors the stub's filesystem-safe table key.
key_of_ref() {
    printf '%s' "$1" | tr '/:@' '___'
}

# image_carries <ref> <repo> <digest...>
#
# Record the repo digests this image reports, the way `docker image inspect
# .RepoDigests` does. A real RepoDigests list never contains a tag: pulling
# `repo:latest` records `repo@sha256:...`, and that is the full reference the
# daemon can start the image from.
#
# A real daemon accepts three spellings for one image and this models all of
# them: the reference a container was started from, the `repo@sha256:...` form,
# and the image ID `.Image` reports.
image_carries() {
    local ref=$1 repo=$2
    shift 2
    mkdir -p "$CUR/state/images"
    local id key dkey d
    id=$(image_id_of_ref "$ref")
    key=$(key_of_ref "$ref")
    : >"$CUR/state/images/$id.digests"
    : >"$CUR/state/images/$key.digests"
    printf '%s\n' "$id" >"$CUR/state/images/$id.imageid"
    printf '%s\n' "$id" >"$CUR/state/images/$key.imageid"
    for d in "$@"; do
        printf '%s@%s\n' "$repo" "$d" >>"$CUR/state/images/$id.digests"
        printf '%s@%s\n' "$repo" "$d" >>"$CUR/state/images/$key.digests"
        # A `repo@sha256:...` reference is content, not spelling: it resolves to
        # this same image.
        dkey=$(key_of_ref "$repo@$d")
        cp "$CUR/state/images/$id.digests" "$CUR/state/images/$dkey.digests"
        printf '%s\n' "$id" >"$CUR/state/images/$dkey.imageid"
    done
}

# image_carries_tag <tag-ref> <repo> <digest...>: a tag that resolves to the
# content of an image already registered. Used to model "`latest` currently
# points at the validated build", and to move it somewhere else.
image_carries_tag() {
    local ref=$1 repo=$2 digest=$3
    local key source id
    key=$(key_of_ref "$ref")
    source=$(key_of_ref "$repo@$digest")
    [ -f "$CUR/state/images/$source.digests" ] || {
        bad "fixture error: no image registered for $repo@$digest"
        return 1
    }
    # A tag and its digest are the same image: `.Image` reports one ID for both,
    # exactly like a real daemon.
    id=$(cat "$CUR/state/images/$source.imageid" 2>/dev/null || printf '%s' "$(image_id_of_ref "$repo@$digest")")
    cp "$CUR/state/images/$source.digests" "$CUR/state/images/$key.digests"
    printf '%s\n' "$id" >"$CUR/state/images/$key.imageid"
}

# set_container <name> <image-ref>: a running container on that reference.
#
# Its `.Image` is whatever image the reference resolves to, so a container
# started from `repo:latest` reports the same ID as the digest that tag points
# at — as a real daemon does. Falling back to a name-derived ID would let a test
# pass that a real host would reject.
set_container() {
    local ref=$2 key
    printf '%s\n' "$ref" >"$CUR/state/containers/$1.image"
    printf 'running\n' >"$CUR/state/containers/$1.status"
    printf 'true\n' >"$CUR/state/containers/$1.running"
    key=$(key_of_ref "$ref")
    if [ -f "$CUR/state/images/$key.imageid" ]; then
        cp "$CUR/state/images/$key.imageid" "$CUR/state/containers/$1.image_id"
    else
        image_id_of_ref "$ref" >"$CUR/state/containers/$1.image_id"
    fi
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
        printf 'FRONTEND_URL=http://127.0.0.1:3000/\n'
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
    # A journal that legitimately reached 'cli' also records every earlier
    # stage, including the verified migration attempt and the two artifacts
    # `cli` installed. The fixture has to look like one, or the completeness
    # gate (rightly) refuses it — which is the point of the gate.
    jset stage cli
    jset freeze_at '2026-01-01 00:00:00'
    jset backup_path "$CUR/backup/world.dump"
    printf 'world-dump' >"$CUR/backup/world.dump"
    jset backup_sha256 "$(sha256sum "$CUR/backup/world.dump" | awk '{ print $1 }')"
    jset backup_bytes 10
    jset backup_toc_lines 500
    jset backup_at '2026-01-01 00:00:00'
    jset migration_attempt "done"
    jset migration_outcome verified
    jset migrate_rc 0
    jset ledger_after 660_attachment_upload_session_workspace
    jset migration_ledger_rows 684
    jset migration_tables 148
    jset migration_indexes 799/0/0
    jset migration_verified_at '2026-01-01 00:00:00'
    jset switched_commit "$REV_NEW"
    # A world at 'cli' has already installed both artifacts, so the fixture
    # installs them instead of only writing the journal keys.
    cp -p "$FIXTURES/approved-upgrade.sh" "$CUR/scripts/upgrade-multica.sh"
    jset cli_installed_sha256 "$(sha256sum "$CUR/cli-bin/multica" | awk '{ print $1 }')"
    jset upgrade_script_installed_sha256 "$APPROVED_SHA"
    # Reaching 'cli' means switch already started the new application: the units
    # are still stopped, but the containers are up and serving.
    set_unit multica-daemon inactive
    set_unit multica-upgrade.timer inactive
    set_unit multica-upgrade.service inactive
    set_unit multica-attachment-gc.timer inactive
    set_unit multica-attachment-gc.service inactive
    set_unit multica-upgrade.timer inactive
    set_unit multica-attachment-gc.timer inactive
}

# jset <key> <value> — writes one journal key directly, for fixtures that need
# to stand in for a stage a normal run would have produced.
jset() {
    local f="$CUR/state-dir/journal" k="$1=" v=$2
    [ -f "$f" ] || : >"$f"
    awk -v k="$k" 'index($0, k) != 1' "$f" >"$f.tmp"
    printf '%s%s\n' "$k" "$v" >>"$f.tmp"
    mv -f "$f.tmp" "$f"
}

dump_count() { find "$CUR/backup" -name '*.dump' 2>/dev/null | wc -l | tr -d ' '; }

# mark_calls — everything logged after this point is "since the mark".
mark_calls() { printf 'MARK %s\n' "${1:-mark}" >>"$CUR/state/calls.log"; }

calls_since_mark() {
    awk 'f { print } /^MARK / { f = 1 }' "$CUR/state/calls.log"
}

# compose_calls_since_mark — the compose log has its own record, because a
# compose invocation is more than a command line: the suite needs the resolved
# project directory and project name to prove where it would have run.
compose_calls_since_mark() {
    awk 'f { print } /^MARK / { f = 1 }' "$CUR/state/compose.log"
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
# FRONTEND_URL decides whether the web container is serving, so a write config
# that leaves it out must not silently fall back to a built-in address.
sed -e '/^FRONTEND_URL=/d' "$CUR_CONFIG" >"$CUR/no-frontend-url.conf"
run_script prepare --config "$CUR/no-frontend-url.conf"
expect_rc 2
expect_log 'missing: FRONTEND_URL' 'refuses to guess the frontend address'
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
expect_log 'repo digests do not include' 'refuses an unexpected running image'
expect_log 'the validated backend digest' 'names the digest the baseline requires'

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

step "Re-running prepare never rewrites the original snapshot"
new_case prepare-twice
prepare_ok
snapshot_compose="$(journal_get initial_compose_sha256)"
snapshot_cli="$(journal_get initial_cli_sha256)"
snapshot_script="$(journal_get initial_upgrade_script_sha256)"
asset_script="$(sha256sum "$CUR/state-dir/assets/previous/upgrade-multica.sh" | awk '{ print $1 }')"
# An unchanged host: the re-run is a read-only re-verification and succeeds.
run_script prepare --config "$CUR_CONFIG"
expect_rc 0
expect_log 'snapshot kept as recorded' 'says the snapshot is kept'
expect_journal initial_compose_sha256 "$snapshot_compose"
expect_journal initial_cli_sha256 "$snapshot_cli"
expect_journal initial_upgrade_script_sha256 "$snapshot_script"
expect_sha "$CUR/state-dir/assets/previous/upgrade-multica.sh" "$asset_script"

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
cli_before="$(sha256sum "$CUR/cli-bin/multica" | awk '{ print $1 }')"
script_before="$(sha256sum "$CUR/scripts/upgrade-multica.sh" | awk '{ print $1 }')"
printf '#!/usr/bin/env bash\nprintf "multica %s (commit: deadbee, built: 2026-01-01T00:00:00Z)\\n"\n' "$CLI_VERSION_NEW" \
    >"$CUR/state-dir/assets/cli/unpack/multica"
chmod 755 "$CUR/state-dir/assets/cli/unpack/multica"
mark_calls cli-tampered
run_script run --intent=switch --config "$CUR_CONFIG"
# The refusal now happens before the window is opened at all: the staged binary
# is part of what `prepared` means, so it is checked before the first side effect
# rather than at install time.
expect_rc 80
expect_log 'staged asset .* no longer matches' 'refuses a mutated staged binary'
expect_no_log 'maintenance complete' 'never claims completion'
expect_no_call_since_mark 'systemctl stop' 'stopped nothing'
expect_no_call_since_mark 'docker run' 'migrated nothing'
expect_no_call_since_mark 'compose .* up' 'started nothing'
expect_sha "$CUR/cli-bin/multica" "$cli_before"
expect_sha "$CUR/scripts/upgrade-multica.sh" "$script_before"

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
expect_log 'no complete prepare snapshot' 'refuses to improvise'
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

step "a run interrupted before the migration resumes at the step it stopped on"
# Interrupting at `switch` (rather than at `migrate`) is the resume the tool
# supports on its own: a failed migration is a latch that needs an operator, so
# it gets its own case below.
new_case resume
prepare_ok
stub_opt compose-rc 1
run_script run --intent=switch --config "$CUR_CONFIG"
expect_rc 50
stub_opt compose-rc
run_script run --intent=switch --config "$CUR_CONFIG"
expect_rc 0
expect_log "resuming at 'switch'" 'resumes at the failed step'
expect_no_log '== freeze:' 'the resume does not repeat the freeze'
expect_no_log '== final backup' 'the resume does not re-take the backup'
expect_journal stage "done"
if [ "$(dump_count)" = 1 ]; then ok "the backup was taken exactly once"; else bad "$(dump_count) dumps exist; a resume re-took the backup"; fi
expect_order 'systemctl stop multica-upgrade.timer' 'exec .* pg_dump'

# ---------------------------------------------------------------------------
# Regressions for the first acceptance round (MYS-2872 review).
#
# Each case below reproduces a state the reviewer observed the executor accept,
# and pins the behaviour that must replace it. They are grouped by finding so a
# future change that reopens one is attributed to the right cause.
# ---------------------------------------------------------------------------

step "review 1: a real production tag reference prepares without rebuilding"
# The NAS compose file names ghcr.io/multica-ai/multica-{backend,web}:latest while
# the containers actually run the validated build. Identity comes from the image
# the container runs and the digests that image carries, not from the spelling.
new_case tag-reference
# The real baseline: the container was pulled from upstream as `:latest`, so its
# RepoDigests record upstream `repo@sha256:...`, not a fork reference.
image_carries "ghcr.io/multica-ai/multica-backend@$BACKEND_DIGEST_OLD" \
    "ghcr.io/multica-ai/multica-backend" "$BACKEND_DIGEST_OLD"
image_carries "ghcr.io/multica-ai/multica-web@$WEB_DIGEST_OLD" \
    "ghcr.io/multica-ai/multica-web" "$WEB_DIGEST_OLD"
image_carries_tag "ghcr.io/multica-ai/multica-backend:latest" \
    "ghcr.io/multica-ai/multica-backend" "$BACKEND_DIGEST_OLD"
image_carries_tag "ghcr.io/multica-ai/multica-web:latest" \
    "ghcr.io/multica-ai/multica-web" "$WEB_DIGEST_OLD"
set_container multica-backend-1 "ghcr.io/multica-ai/multica-backend:latest"
set_container multica-frontend-1 "ghcr.io/multica-ai/multica-web:latest"
prepare_ok
expect_log 'identity ok by image ID' 'accepts a tag whose image carries the validated digest'
expect_journal initial_backend_image "ghcr.io/multica-ai/multica-backend:latest"
expect_journal initial_backend_digest "$BACKEND_DIGEST_OLD"
# The rollback configuration must pin the digest, so `latest` cannot decide R1.
rollback_compose="$CUR/state-dir/assets/compose/docker-compose.rollback.yml"
if [ -f "$rollback_compose" ]; then
    ok "a digest-pinned rollback compose file was derived"
else
    bad "no rollback compose file was recorded"
fi
# The pinned reference must be the one the running image reported — upstream,
# not a fork prefix invented by rewriting the repository. Asserting a fork
# prefix here is what let the previous revision ship a reference nobody had
# verified.
expected_rb="ghcr.io/multica-ai/multica-backend@$BACKEND_DIGEST_OLD"
if grep -qE "^[[:space:]]*image:[[:space:]]*$expected_rb\$" "$rollback_compose" 2>/dev/null; then
    ok "the rollback file pins the digest against the verified upstream repo"
else
    bad "the rollback file does not pin $expected_rb: $(grep -E 'image:' "$rollback_compose" 2>/dev/null | tr '\n' '|')"
fi
if grep -qE "^[[:space:]]*image:[[:space:]]*ghcr.io/zzttzzmyswy/multica-backend@$BACKEND_DIGEST_OLD\$" "$rollback_compose" 2>/dev/null; then
    bad "the rollback file rewrote the repository prefix to this fork"
else
    ok "the rollback file keeps the repository the image was pulled from"
fi
if grep -q 'latest' "$rollback_compose" 2>/dev/null; then
    bad "the rollback file still contains a floating tag"
else
    ok "no floating tag survives in the rollback file"
fi
expect_sha "$CUR/compose/docker-compose.yml" "$(sha256sum "$FIXTURES/compose-live.yml" | awk '{ print $1 }')"

step "review 1: a tag that has drifted to another build is refused"
new_case tag-drift
image_carries "ghcr.io/multica-ai/multica-backend-drifted:latest" \
    "ghcr.io/multica-ai/multica-backend" "sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
image_carries_tag "ghcr.io/multica-ai/multica-backend:latest" \
    "ghcr.io/multica-ai/multica-backend" "sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
image_carries "ghcr.io/multica-ai/multica-web@$WEB_DIGEST_OLD" \
    "ghcr.io/multica-ai/multica-web" "$WEB_DIGEST_OLD"
image_carries_tag "ghcr.io/multica-ai/multica-web:latest" \
    "ghcr.io/multica-ai/multica-web" "$WEB_DIGEST_OLD"
set_container multica-backend-1 "ghcr.io/multica-ai/multica-backend:latest"
set_container multica-frontend-1 "ghcr.io/multica-ai/multica-web:latest"
run_script prepare --config "$CUR_CONFIG"
expect_rc 20
expect_log 'repo digests do not include' 'refuses a tag pointing somewhere else'
expect_log 'recorded: ' 'prints the digests it actually saw'
expect_no_journal initial_compose_sha256

step "review 1: a container on an unexpected image is refused"
new_case identity-wrong-image
# The image exists and carries a digest, just not the validated one.
set_container multica-backend-1 "ghcr.io/zzttzzmyswy/multica-backend@sha256:9999999999999999999999999999999999999999999999999999999999999999"
run_script prepare --config "$CUR_CONFIG"
expect_rc 20
expect_log 'repo digests do not include' 'compares digests, not reference text'

step "review 2: a second prepare cannot overwrite the original snapshot"
new_case snapshot-protected
prepare_ok
recorded_script="$(journal_get initial_upgrade_script_sha256)"
snapshot_script="$(sha256sum "$CUR/state-dir/assets/previous/upgrade-multica.sh" | awk '{ print $1 }')"
snapshot_cli="$(sha256sum "$CUR/state-dir/assets/previous/multica" | awk '{ print $1 }')"
snapshot_compose="$(sha256sum "$CUR/state-dir/assets/compose/docker-compose.initial.yml" | awk '{ print $1 }')"
# The live updater changes, then prepare runs again.
printf '# changed after preparation\n' >>"$CUR/scripts/upgrade-multica.sh"
run_script prepare --config "$CUR_CONFIG"
expect_rc 20
expect_log 'changed after prepare' 'detects the drift and refuses'
expect_sha "$CUR/state-dir/assets/previous/upgrade-multica.sh" "$snapshot_script"
expect_sha "$CUR/state-dir/assets/previous/multica" "$snapshot_cli"
expect_sha "$CUR/state-dir/assets/compose/docker-compose.initial.yml" "$snapshot_compose"
expect_journal initial_upgrade_script_sha256 "$recorded_script"
# And R1 must still find the recorded original, not the drifted live file.
run_script rollback-r1 --config "$CUR_CONFIG"
expect_sha "$CUR/scripts/upgrade-multica.sh" "$recorded_script"

step "review 2: a snapshot damaged after prepare is refused, not rebuilt"
new_case snapshot-damaged
prepare_ok
printf '# corrupted\n' >"$CUR/state-dir/assets/previous/upgrade-multica.sh"
run_script prepare --config "$CUR_CONFIG"
expect_rc 20
expect_log 'snapshot file .* is .* but the journal recorded' 'reports the mismatch'
if [ "$(sha256sum "$CUR/state-dir/assets/previous/upgrade-multica.sh" | awk '{ print $1 }')" = "$(printf '# corrupted\n' | sha256sum | awk '{ print $1 }')" ]; then
    ok "the corrupted file was left as evidence, not silently repaired"
else
    bad "the damaged snapshot was rewritten"
fi

step "review 2: a failing prepare leaves the previous snapshot intact"
new_case prepare-transactional
prepare_ok
snapshot_compose="$(sha256sum "$CUR/state-dir/assets/compose/docker-compose.initial.yml" | awk '{ print $1 }')"
# Force a failure after staging but before the publish: the rollback compose
# cannot be derived from a live file with the backend image line removed.
grep -v 'multica-backend@' "$CUR/compose/docker-compose.yml" >"$CUR/compose/tmp.yml"
mv "$CUR/compose/tmp.yml" "$CUR/compose/docker-compose.yml"
run_script prepare --config "$CUR_CONFIG"
if [ "$RC" -ne 0 ]; then
    ok "the re-prepare failed as arranged"
else
    bad "prepare succeeded on a compose file with no backend image line"
fi
expect_sha "$CUR/state-dir/assets/compose/docker-compose.initial.yml" "$snapshot_compose"
if [ -d "$CUR/state-dir/assets.new" ]; then bad "a staging directory was left behind"; else ok "no staging directory was left behind"; fi

step "review 3: a resume refuses when the backup is gone or the writers came back"
new_case resume-writers-back
prepare_ok
stub_opt compose-rc 1
run_script run --intent=switch --config "$CUR_CONFIG"
expect_rc 50
stub_opt compose-rc
# Between runs the API and a oneshot service come back, which the old executor
# did not notice before migrating.
set_unit multica-attachment-gc.service active
set_container multica-backend-1 "$BACKEND_IMAGE_OLD"
mark_calls resume-writers
run_script run --intent=switch --config "$CUR_CONFIG"
expect_rc 80
expect_log 'the writers are running now' 'refuses to inherit a stale "frozen" claim'
expect_log 'writes are not frozen' 'names the running writer'
expect_no_call_since_mark 'docker run' 'no migration was attempted'

new_case resume-backup-missing
prepare_ok
stub_opt compose-rc 1
run_script run --intent=switch --config "$CUR_CONFIG"
expect_rc 50
stub_opt compose-rc
rm -f "$(journal_get backup_path)"
mark_calls resume-no-backup
run_script run --intent=switch --config "$CUR_CONFIG"
expect_rc 80
expect_log 'the recorded backup .* is missing' 'refuses without a recovery point'
expect_no_call_since_mark 'docker run' 'no migration was attempted'

new_case resume-backup-altered
prepare_ok
stub_opt compose-rc 1
run_script run --intent=switch --config "$CUR_CONFIG"
expect_rc 50
stub_opt compose-rc
printf 'tampered' >>"$(journal_get backup_path)"
mark_calls resume-altered-backup
run_script run --intent=switch --config "$CUR_CONFIG"
expect_rc 80
expect_log 'but the journal recorded' 'detects a dump that no longer matches its hash'
expect_no_call_since_mark 'docker run' 'no migration was attempted'

step "review 3: a failed migration is a latch, not a checkpoint"
new_case migrate-latch
prepare_ok
stub_opt migrate-rc 1
run_script run --intent=switch --config "$CUR_CONFIG"
expect_rc 40
expect_journal migrate_failed 1
stub_opt migrate-rc
run_script run --intent=switch --config "$CUR_CONFIG"
expect_rc 80
expect_log 'a migration already failed here' 'refuses to treat a re-run as permission'
expect_no_log 'Do not re-run this command as a way past a failed migration' 'never offers the re-run as the remedy'
expect_no_call 'compose .* up' 'does not start the application over a half-migrated database'
if [ "$(dump_count)" = 1 ]; then ok "no extra backup was taken"; else bad "$(dump_count) dumps exist"; fi

step "review 4: an incomplete journal cannot claim completion"
new_case journal-truncated
prepare_ok
# Keep only a late stage: the old executor accepted this and printed success with
# an empty snapshot and three missing unit states.
printf 'stage=verified\n' >"$CUR/state-dir/journal"
set_unit multica-daemon inactive
set_unit multica-upgrade.timer inactive
set_unit multica-attachment-gc.timer inactive
run_script run --intent=switch --config "$CUR_CONFIG"
expect_rc 80
expect_log 'no config_sha256|missing required key' 'refuses a journal with no snapshot'
expect_no_log 'maintenance complete' 'never claims completion'
expect_unit multica-daemon inactive

new_case journal-missing-unit-state
prepare_ok
sed -i '/^initial_daemon_state=/d' "$CUR/state-dir/journal"
sed -i 's/^stage=prepared/stage=verified/' "$CUR/state-dir/journal"
run_script run --intent=switch --config "$CUR_CONFIG"
expect_rc 80
expect_log "missing required key 'initial_daemon_state'" 'names the missing fact'
expect_no_log 'maintenance complete' 'never claims completion'

new_case journal-missing-backup
prepare_ok
# A journal that reached 'verified' without ever recording a backup could not
# have had a recovery point; the old executor resumed straight to thaw.
sed -i 's/^stage=prepared/stage=verified/' "$CUR/state-dir/journal"
run_script run --intent=switch --config "$CUR_CONFIG"
expect_rc 80
expect_log "missing required key 'backup_path'" 'refuses a stage whose evidence is absent'
expect_no_log 'maintenance complete' 'never claims completion'

new_case journal-duplicate-key
prepare_ok
printf 'stage=done\n' >>"$CUR/state-dir/journal"
run_script run --intent=switch --config "$CUR_CONFIG"
expect_rc 80
expect_log 'duplicate key' 'refuses an ambiguous journal'
expect_no_log 'maintenance complete' 'never claims completion'

new_case journal-illegal-unit-state
prepare_ok
world_post_switch
sed -i 's/^initial_daemon_state=active/initial_daemon_state=maybe/' "$CUR/state-dir/journal"
run_script run --intent=switch --config "$CUR_CONFIG"
expect_rc 80
expect_log 'is not a legal unit state' 'rejects an impossible recorded state'

step "review 5: R1 refuses a database shape it has not verified"
new_case r1-partial-schema
prepare_ok
stub_opt migrate-rc 1
run_script run --intent=switch --config "$CUR_CONFIG"
expect_rc 40
# The half-migrated shape the reviewer reproduced.
printf '650_partial\n' >"$CUR/state/ledger"
printf '670\n' >"$CUR/state/ledger_rows"
mark_calls r1-partial
run_script rollback-r1 --config "$CUR_CONFIG"
expect_rc 80
expect_log 'not a verified one' 'refuses an unknown schema shape'
expect_log '650_partial' 'reports the shape it saw'
expect_no_call_since_mark 'compose .* up' 'starts no container'
expect_no_call_since_mark 'systemctl start' 'restarts no unit'
expect_unit multica-daemon inactive

new_case r1-post-schema-ok
prepare_ok
stub_opt compose-rc 1
run_script run --intent=switch --config "$CUR_CONFIG"
expect_rc 50
stub_opt compose-rc
# The migration completed; the old backend is verified against both shapes.
run_script rollback-r1 --config "$CUR_CONFIG"
expect_rc 0
expect_log 'current schema shape: post' 'accepts the complete 660 schema'
expect_container_image multica-backend-1 "$BACKEND_IMAGE_OLD"

new_case r1-partial-tables
prepare_ok
stub_opt compose-rc 1
run_script run --intent=switch --config "$CUR_CONFIG"
expect_rc 50
stub_opt compose-rc
# Right ledger, wrong table count: not a shape anyone verified.
printf '140\n' >"$CUR/state/tables"
run_script rollback-r1 --config "$CUR_CONFIG"
expect_rc 80
expect_log 'not a verified one' 'refuses a shape mismatch'

step "review 6: a frontend that is up but not serving is not acceptable"
new_case frontend-not-serving
prepare_ok
stub_opt frontend-never 1
run_script run --intent=switch --config "$CUR_CONFIG"
expect_rc 50
expect_log "answered 'no response'|frontend at" 'reports the missing frontend'
expect_no_log 'candidate ok' 'never accepts the switch'

new_case frontend-500
prepare_ok
stub_opt frontend-code 500
run_script run --intent=switch --config "$CUR_CONFIG"
expect_rc 50
expect_log "answered '500'" 'reports the status code'

new_case frontend-exits-before-verify
prepare_ok
# The frontend passes the switch and then dies before final acceptance.
stub_opt frontend-never 1
run_script run --intent=switch --config "$CUR_CONFIG"
expect_rc 50
expect_no_log 'maintenance complete' 'does not report completion'

new_case verify-rechecks-frontend
prepare_ok
world_post_switch
# A world that reached 'cli' with the frontend now failing the probe.
stub_opt frontend-code 502
run_script run --intent=switch --config "$CUR_CONFIG"
expect_rc 50
expect_log 'MISMATCH: frontend is not serving' 'verify re-asks the frontend'
expect_no_log 'maintenance complete' 'never claims completion'

new_case r1-frontend-not-serving
prepare_ok
stub_opt compose-rc 1
run_script run --intent=switch --config "$CUR_CONFIG"
expect_rc 50
stub_opt compose-rc
stub_opt frontend-code 503
run_script rollback-r1 --config "$CUR_CONFIG"
expect_rc 70
expect_log "answered '503'" 'R1 refuses an unrestored frontend'

step "review 7: execution stays bounded and every failure is reported"
new_case zero-timeout
prepare_ok
write_config 'PROBE_TIMEOUT=0'
run_script prepare --config "$CUR_CONFIG"
expect_rc 2
expect_log 'must be greater than zero' 'rejects a zero timeout instead of running unbounded'

new_case blank-timeout-key
prepare_ok
# An explicitly blank timeout is a configuration mistake, not a request for the
# default: the tool refuses instead of guessing or running unbounded.
sed -i 's/^QUERY_TIMEOUT=.*/QUERY_TIMEOUT=/' "$CUR_CONFIG"
rm -f "$CUR/state-dir/journal"
run_script prepare --config "$CUR_CONFIG"
expect_rc 2
expect_log 'timeout QUERY_TIMEOUT must be a positive integer' 'rejects a blank timeout'

new_case nonnumeric-timeout
sed -i 's/^STOP_TIMEOUT=.*/STOP_TIMEOUT=ten/' "$CUR_CONFIG"
run_script prepare --config "$CUR_CONFIG"
expect_rc 2
expect_log 'timeout STOP_TIMEOUT must be a positive integer' 'rejects a non-numeric timeout'

new_case terminal-journal-write-fails
prepare_ok
stub_opt compose-rc 1
run_script run --intent=switch --config "$CUR_CONFIG"
expect_rc 50
stub_opt compose-rc
# The rollback restores every file and unit, and the journal breaks at the last
# possible moment (during the final unit start). The exit code must not claim
# the terminal state was recorded.
stub_opt break-journal-on-start 1
run_script rollback-r1 --config "$CUR_CONFIG"
expect_rc 70
expect_log 'cannot record stage' 'reports the failed terminal write'
expect_log 'aborting rather than continuing unrecorded' 'says why it aborted'
# The restore work itself did happen; only the record failed, and that is exactly
# what the non-zero exit reports. The original hashes were captured before the
# journal broke.
expect_sha "$CUR/scripts/upgrade-multica.sh" "$(sha256sum "$CUR/state-dir/assets/previous/upgrade-multica.sh" | awk '{ print $1 }')"
expect_sha "$CUR/cli-bin/multica" "$(sha256sum "$CUR/state-dir/assets/previous/multica" | awk '{ print $1 }')"


step "review 7: a CLI that hangs cannot hold the window open"
new_case cli-hangs
prepare_ok
# The installed CLI never returns from --version; the bounded probe must time out
# and the step must fail instead of waiting forever.
cat >"$CUR/cli-bin/multica" <<'STUB'
#!/usr/bin/env bash
sleep 600
STUB
chmod 755 "$CUR/cli-bin/multica"
write_config 'PROBE_TIMEOUT=2'
start=$(date +%s)
run_script prepare --config "$CUR_CONFIG"
elapsed=$(( $(date +%s) - start ))
if [ "$RC" -ne 0 ]; then
    ok "a hanging CLI fails the probe (exit $RC)"
else
    bad "a hanging CLI was accepted"
fi
if [ "$elapsed" -le 120 ]; then
    ok "the probe was bounded (${elapsed}s)"
else
    bad "the probe ran for ${elapsed}s"
fi

step "review 7: ownership is restored on both paths"
new_case ownership-forward
if [ "$(id -u)" != "0" ]; then
    ok "skipped: ownership assertions need root"
else
    prepare_ok
    chown 1234:5678 "$CUR/scripts/upgrade-multica.sh"
    run_script prepare --config "$CUR_CONFIG"
    expect_rc 0
    run_script run --intent=switch --config "$CUR_CONFIG"
    expect_rc 0
    if [ "$(stat -c '%u:%g' "$CUR/scripts/upgrade-multica.sh")" = "1234:5678" ]; then
        ok "the installed script keeps its owner"
    else
        bad "owner is $(stat -c '%u:%g' "$CUR/scripts/upgrade-multica.sh"), expected 1234:5678"
    fi
fi

# ---------------------------------------------------------------------------
# A: real image references, compose resolution, and the prepare transaction.
#
# These three are the scope of this card. Each case below reproduces the state
# the reviewer reached with real Docker / real Compose, using stubs only where a
# daemon would otherwise be required.
# ---------------------------------------------------------------------------

step "A1: every compose call resolves against the deployment directory"
new_case compose-project-dir
prepare_ok
run_script run --intent=switch --config "$CUR_CONFIG"
expect_rc 0
# Both compose actions must name the deployment directory, not the directory the
# file happens to live in. A snapshot under STATE_DIR has no .env of its own.
if grep -q "project_dir=$CUR/compose " "$CUR/state/compose.log"; then
    ok "stop/up carry --project-directory=$CUR/compose"
else
    bad "compose calls did not pin the project directory: $(head -3 "$CUR/state/compose.log" | tr '\n' '|')"
fi
if grep -q "project=multica " "$CUR/state/compose.log"; then
    ok "the project name is explicit on every call"
else
    bad "compose calls did not pin the project name"
fi

step "A1: the rollback compose file is started from the deployment directory"
new_case compose-project-dir-rollback
prepare_ok
stub_opt compose-rc 1
run_script run --intent=switch --config "$CUR_CONFIG"
expect_rc 50
stub_opt compose-rc
printf 'MARK rollback\n' >>"$CUR/state/compose.log"
run_script rollback-r1 --config "$CUR_CONFIG"
expect_rc 0
# The rollback file lives under STATE_DIR/assets/compose; without the project
# directory its `env_file: .env` and ${...} interpolation would resolve there.
if compose_calls_since_mark | grep -q "project_dir=$CUR/compose .*action=up"; then
    ok "the rollback up pins the deployment directory"
else
    bad "the rollback up did not pin the project directory: $(compose_calls_since_mark | tr '\n' '|')"
fi
if compose_calls_since_mark | grep -q "file=$CUR/state-dir/assets/compose/docker-compose.rollback.yml"; then
    ok "the rollback up uses the digest-pinned snapshot file"
else
    bad "the rollback up did not use the verified rollback file: $(compose_calls_since_mark | tr '\n' '|')"
fi

step "A2: the rollback reference is the image's own repository"
new_case rollback-ref-upstream
# The real baseline: containers pulled from upstream as :latest. The rollback
# reference must be upstream's repo@digest, because that is the reference the
# image reports and the only one proven resolvable here.
image_carries "ghcr.io/multica-ai/multica-backend@$BACKEND_DIGEST_OLD" \
    "ghcr.io/multica-ai/multica-backend" "$BACKEND_DIGEST_OLD"
image_carries "ghcr.io/multica-ai/multica-web@$WEB_DIGEST_OLD" \
    "ghcr.io/multica-ai/multica-web" "$WEB_DIGEST_OLD"
image_carries_tag "ghcr.io/multica-ai/multica-backend:latest" \
    "ghcr.io/multica-ai/multica-backend" "$BACKEND_DIGEST_OLD"
image_carries_tag "ghcr.io/multica-ai/multica-web:latest" \
    "ghcr.io/multica-ai/multica-web" "$WEB_DIGEST_OLD"
set_container multica-backend-1 "ghcr.io/multica-ai/multica-backend:latest"
set_container multica-frontend-1 "ghcr.io/multica-ai/multica-web:latest"
prepare_ok
expect_journal initial_rollback_backend_ref \
    "ghcr.io/multica-ai/multica-backend@$BACKEND_DIGEST_OLD"
expect_journal initial_rollback_web_ref \
    "ghcr.io/multica-ai/multica-web@$WEB_DIGEST_OLD"
if journal_get initial_rollback_backend_ref 2>/dev/null | grep -q zzttzzmyswy; then
    bad "the recorded rollback reference was rewritten to this fork"
else
    ok "the recorded rollback reference keeps the original repository"
fi

# Note: a rollback reference that resolves to no local image at all cannot be
# constructed here without also failing the earlier digest-identity gate, which
# already refuses an image the host does not carry. The check that matters — the
# derived reference must be the *same* image that is running — is the case below.

step "A2: a rollback reference resolving to a different image fails prepare"
new_case rollback-ref-wrong-image
image_carries "ghcr.io/multica-ai/multica-backend:latest" \
    "ghcr.io/multica-ai/multica-backend" "$BACKEND_DIGEST_OLD"
image_carries "ghcr.io/multica-ai/multica-web:latest" \
    "ghcr.io/multica-ai/multica-web" "$WEB_DIGEST_OLD"
set_container multica-backend-1 "ghcr.io/multica-ai/multica-backend:latest"
set_container multica-frontend-1 "ghcr.io/multica-ai/multica-web:latest"
# The digest-form row resolves, but to an image that is not what is running.
printf 'image-id-something-else\n' \
    >"$CUR/state/images/$(key_of_ref "ghcr.io/multica-ai/multica-backend@$BACKEND_DIGEST_OLD").imageid"
run_script prepare --config "$CUR_CONFIG"
expect_rc 20
expect_log 'but the running backend is' 'refuses a reference that resolves elsewhere'
expect_no_journal initial_compose_sha256

step "A3: a first prepare that fails leaves nothing behind and can be retried"
new_case prepare-first-failure
# The reviewer's counter-example: the very first prepare fails (a oneshot GC job
# is in flight). The old executor had already written half a journal by then, so
# the retry hit "unbound journal" and the operator had to delete files by hand.
set_unit multica-attachment-gc.service active
run_script prepare --config "$CUR_CONFIG"
expect_rc 20
expect_log 'is running; a timer job is in flight' 'refuses while a timer job runs'
if [ -f "$CUR/state-dir/journal" ]; then
    bad "a failed first prepare left a journal behind: $(cat "$CUR/state-dir/journal" | tr '\n' '|' | cut -c1-200)"
else
    ok "no journal was published by the failed prepare"
fi
if [ -d "$CUR/state-dir/assets" ]; then bad "a failed first prepare published assets"; else ok "no assets were published"; fi
if [ -d "$CUR/state-dir/assets.new" ]; then bad "a staging directory was left behind"; else ok "no staging directory was left behind"; fi
if [ -f "$CUR/state-dir/journal.new" ]; then bad "a staged journal was left behind"; else ok "no staged journal was left behind"; fi
# The obstruction clears; a retry must now succeed with no manual cleanup.
set_unit multica-attachment-gc.service inactive
run_script prepare --config "$CUR_CONFIG"
expect_rc 0
expect_journal stage prepared
expect_journal config_sha256 "$(sha256sum "$CUR_CONFIG" | awk '{ print $1 }')"

step "A3: a prepare failing after staging can be retried"
new_case prepare-late-failure
# Fail after the assets are staged and the snapshot is written but before the
# publish: the rollback compose cannot be derived when the live file has no
# backend image line.
grep -v 'multica-backend@' "$CUR/compose/docker-compose.yml" >"$CUR/compose/tmp.yml"
mv "$CUR/compose/tmp.yml" "$CUR/compose/docker-compose.yml"
run_script prepare --config "$CUR_CONFIG"
if [ "$RC" -ne 0 ]; then ok "the prepare failed as arranged (exit $RC)"; else bad "prepare succeeded on a broken compose file"; fi
if [ -f "$CUR/state-dir/journal" ]; then
    bad "a late prepare failure left a journal behind"
else
    ok "no journal was published"
fi
if [ -d "$CUR/state-dir/assets.new" ]; then bad "staging left behind"; else ok "staging cleaned up"; fi
# Fix the input and retry.
cp "$FIXTURES/compose-live.yml" "$CUR/compose/docker-compose.yml"
run_script prepare --config "$CUR_CONFIG"
expect_rc 0
expect_journal stage prepared

step "A3: a successful snapshot is never overwritten or half-replaced"
new_case prepare-publish-atomic
prepare_ok
snapshot_journal="$(sha256sum "$CUR/state-dir/journal" | awk '{ print $1 }')"
snapshot_assets="$(find "$CUR/state-dir/assets" -type f | sort | xargs sha256sum | sha256sum | awk '{ print $1 }')"
# Any later attempt, successful or not, must leave both untouched.
run_script prepare --config "$CUR_CONFIG"
expect_rc 0
expect_sha "$CUR/state-dir/journal" "$snapshot_journal"
if [ "$(find "$CUR/state-dir/assets" -type f | sort | xargs sha256sum | sha256sum | awk '{ print $1 }')" = "$snapshot_assets" ]; then
    ok "the published assets are byte-identical"
else
    bad "the published assets changed on a re-run"
fi
# Journal and assets must always agree: every initial_* hash is present on disk.
for pair in "initial_compose_sha256:$CUR/state-dir/assets/compose/docker-compose.initial.yml" \
            "initial_compose_new_sha256:$CUR/state-dir/assets/compose/docker-compose.new.yml" \
            "initial_compose_rollback_sha256:$CUR/state-dir/assets/compose/docker-compose.rollback.yml" \
            "initial_cli_sha256:$CUR/state-dir/assets/previous/multica" \
            "initial_upgrade_script_sha256:$CUR/state-dir/assets/previous/upgrade-multica.sh"; do
    k=${pair%%:*}; path=${pair#*:}
    want=$(journal_get "$k")
    got=$(sha256sum "$path" 2>/dev/null | awk '{ print $1 }')
    if [ "$want" = "$got" ]; then
        ok "journal $k matches the published file"
    else
        bad "journal $k=$want but $path is $got"
    fi
done

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
# B: the resume and migration state machine.
#
# Three defects from the second acceptance round, each reproduced on its own:
#
#   3. a late resume (from `verified`) returned 0 without re-measuring anything,
#      so an old CLI, a stopped frontend and a deleted backup all "succeeded";
#   4. only a non-zero `docker run` was latched, so a migration that exited 0
#      into the wrong schema — or that was interrupted — was simply re-run;
#   5. `frozen` demanded the backup fields, so a failed dump could never be
#      retried: the only way out was editing the journal by hand.
#
# Every case below is driven through the executor's own CLI. Nothing edits the
# journal to clear a latch: a latch that can be cleared by hand is not a latch.
# ---------------------------------------------------------------------------

# thaw_then_break — reach `verified` legitimately (a real run whose thaw fails),
# then damage the world in a named way. Each case separates one fault from the
# others, so a single early mismatch cannot hide the rest.
thaw_then_break() {
    prepare_ok || return 1
    stub_opt start-fail-unit multica-daemon
    run_script run --intent=switch --config "$CUR_CONFIG"
    if [ "$RC" -ne 70 ]; then
        bad "the arranged thaw failure did not happen (exit $RC)"
        return 1
    fi
    if [ "$(journal_get stage)" != verified ]; then
        bad "the arranged thaw left stage '$(journal_get stage)', expected verified"
        return 1
    fi
    stub_opt start-fail-unit
    return 0
}

step "B1: a late resume re-measures the installed CLI"
new_case late-resume-old-cli
thaw_then_break || true
write_cli "$CUR/cli-bin/multica" "$CLI_VERSION_OLD"
mark_calls late-cli
run_script run --intent=switch --config "$CUR_CONFIG"
if [ "$RC" -ne 0 ]; then ok "the resume refused (exit $RC)"; else bad "the resume reported success over an old CLI"; fi
expect_log "cli version '$CLI_VERSION_OLD'" 'names the CLI it actually found'
expect_no_log 'maintenance complete' 'never claims completion'
expect_no_call_since_mark 'systemctl start' 'starts no unit on a stale candidate'
if [ "$(journal_get stage)" = "done" ]; then bad "the journal reached done"; else ok "the journal did not reach done"; fi

step "B1: a late resume notices a frontend that is no longer serving"
new_case late-resume-frontend-down
thaw_then_break || true
printf 'false\n' >"$CUR/state/containers/multica-frontend-1.running"
printf 'exited\n' >"$CUR/state/containers/multica-frontend-1.status"
mark_calls late-frontend
run_script run --intent=switch --config "$CUR_CONFIG"
if [ "$RC" -ne 0 ]; then ok "the resume refused (exit $RC)"; else bad "the resume reported success over a stopped frontend"; fi
expect_no_log 'maintenance complete' 'never claims completion'
expect_no_call_since_mark 'systemctl start' 'starts no unit'

step "B1: a late resume notices the backup is gone"
new_case late-resume-backup-gone
thaw_then_break || true
rm -f "$(journal_get backup_path)"
mark_calls late-backup
run_script run --intent=switch --config "$CUR_CONFIG"
if [ "$RC" -ne 0 ]; then ok "the resume refused (exit $RC)"; else bad "the resume reported success without a recovery point"; fi
expect_log 'the recorded backup .* is missing' 'names the missing recovery point'
expect_no_log 'maintenance complete' 'never claims completion'
expect_no_call_since_mark 'systemctl start' 'starts no unit'

step "B1: a late resume notices a staged asset that no longer matches"
new_case late-resume-staged-script
thaw_then_break || true
printf '# tampered after prepare\n' >>"$CUR/state-dir/assets/approved-upgrade-multica.sh"
mark_calls late-staged
run_script run --intent=switch --config "$CUR_CONFIG"
if [ "$RC" -ne 0 ]; then ok "the resume refused (exit $RC)"; else bad "the resume reported success over a tampered staged asset"; fi
expect_no_log 'maintenance complete' 'never claims completion'
expect_no_call_since_mark 'systemctl start' 'starts no unit'

step "B1: a late resume notices the migration outcome no longer matches the database"
new_case late-resume-schema-drift
thaw_then_break || true
printf '616_member_pinned\n' >"$CUR/state/ledger"
mark_calls late-schema
run_script run --intent=switch --config "$CUR_CONFIG"
if [ "$RC" -ne 0 ]; then ok "the resume refused (exit $RC)"; else bad "the resume reported success over an unmigrated schema"; fi
expect_log 'MISMATCH: ledger' 'names the schema it actually read'
expect_no_log 'maintenance complete' 'never claims completion'
expect_no_call_since_mark 'systemctl start' 'starts no unit'

step "B1: a healthy late resume still completes"
new_case late-resume-healthy
thaw_then_break || true
run_script run --intent=switch --config "$CUR_CONFIG"
expect_rc 0
expect_journal stage "done"
expect_log 'maintenance complete' 'accepts a genuinely complete resume'
expect_unit multica-daemon active

step "B1: a thaw that is resumed after a partial unit restore does not start twice"
# The units were restored in a previous attempt except the daemon. Resuming must
# start only what is missing, and must not treat the already-active timers as an
# unauthorised success or start them again.
new_case thaw-partial-units
prepare_ok
stub_opt start-fail-unit multica-daemon
run_script run --intent=switch --config "$CUR_CONFIG"
expect_rc 70
stub_opt start-fail-unit
# The two timers were restored before the daemon failed; they are active now.
expect_unit multica-upgrade.timer active
expect_unit multica-attachment-gc.timer active
expect_unit multica-daemon inactive
mark_calls thaw-partial
run_script run --intent=switch --config "$CUR_CONFIG"
expect_rc 0
expect_journal stage "done"
expect_unit multica-daemon active
expect_no_call_since_mark 'systemctl start multica-upgrade.timer' 'does not restart a unit already restored'
expect_no_call_since_mark 'systemctl start multica-attachment-gc.timer' 'does not restart a unit already restored'
if calls_since_mark | grep -q 'systemctl start multica-daemon'; then
    ok "starts only the unit that was still down"
else
    bad "never started the daemon that was still down: $(calls_since_mark | tr '\n' '|')"
fi

step "B2: a migration that exits 0 into the wrong schema is latched"
new_case migrate-shape-latch
prepare_ok
# The command reports success; the schema is not the .2 schema.
stub_opt ledger-after 650_partial
stub_opt rows-after 670
run_script run --intent=switch --config "$CUR_CONFIG"
expect_rc 40
expect_log 'the command reported success but the schema gate rejected it' 'says the exit status was not the gate'
expect_log 'MISMATCH: ledger' 'names what it actually read'
expect_log 'MIGRATION NOT VERIFIED' 'records the attempt as unverified'
if [ "$(journal_get migration_outcome)" != verified ]; then
    ok "no verified outcome was recorded"
else
    bad "a non-.2 schema was recorded as verified"
fi
expect_no_call 'compose .* up' 'never starts the application'
if [ "$(dump_count)" = 1 ]; then ok "exactly one backup exists"; else bad "$(dump_count) dumps exist"; fi

new_case migrate-shape-latch-retry
prepare_ok
stub_opt tables-after 131
run_script run --intent=switch --config "$CUR_CONFIG"
expect_rc 40
stub_opt tables-after
mark_calls shape-retry
run_script run --intent=switch --config "$CUR_CONFIG"
if [ "$RC" -ne 0 ]; then ok "the re-run refused (exit $RC)"; else bad "the re-run performed the migration again"; fi
expect_no_call_since_mark 'docker run' 'the migration was not called a second time'
expect_no_call_since_mark 'compose .* up' 'the application was not started'
expect_no_log 'maintenance complete' 'never claims completion'
expect_journal stage backup

step "B2: a migration interrupted while running is latched"
new_case migrate-interrupted
prepare_ok
# The command changes the schema and then dies. Nothing after it runs, so the
# journal holds an attempt with no outcome — exactly the state a re-run must not
# treat as "the migration never happened".
stub_opt migrate-killed 1
run_script run --intent=switch --config "$CUR_CONFIG"
expect_rc 40
expect_log 'MIGRATION NOT VERIFIED' 'records the attempt as unverified'
stub_opt migrate-killed
mark_calls interrupted-retry
run_script run --intent=switch --config "$CUR_CONFIG"
if [ "$RC" -ne 0 ]; then ok "the re-run refused (exit $RC)"; else bad "the re-run continued after an interrupted migration"; fi
expect_no_call_since_mark 'docker run' 'the migration was not called again'
expect_no_call_since_mark 'compose .* up' 'the application was not started'

step "B2: a migration whose outcome cannot be recorded is latched"
new_case migrate-ledger-write-fails
prepare_ok
# The journal breaks while the migration is running: the command succeeded, but
# the verified outcome cannot be written. The attempt is on disk and the outcome
# is not, which is the latch.
stub_opt break-migration-journal 1
run_script run --intent=switch --config "$CUR_CONFIG"
if [ "$RC" -ne 0 ]; then ok "the run failed (exit $RC)"; else bad "the run reported success without a recorded outcome"; fi
expect_no_log 'maintenance complete' 'never claims completion'

step "B2: the attempt is on disk before the command runs"
new_case migrate-attempt-order
prepare_ok
# The latch has to reach disk *before* the process starts. A journal written
# afterwards leaves the window this card exists to close, so the case makes the
# command itself read the journal from inside the stub: what it sees is what was
# on disk at the instant the migration ran.
stub_opt migrate-observe-journal "$CUR/state-dir/journal"
run_script run --intent=switch --config "$CUR_CONFIG"
expect_rc 0
observed="$(cat "$CUR/state/migrate-journal-at-start" 2>/dev/null)"
case $observed in
    *migration_attempt=pending*) ok "the attempt was recorded before the command ran" ;;
    *) bad "the journal did not hold the attempt when the command ran: $(printf '%s' "$observed" | tr '\n' '|' | cut -c1-200)" ;;
esac
expect_journal migration_attempt "done"
expect_journal migration_outcome verified
expect_log 'migrate exit=0' 'the command actually ran'
if [ "$(journal_get stage)" = "done" ]; then ok "the journal reached done"; else bad "stage is $(journal_get stage)"; fi

step "B2: an intact success path records every migration fact"
new_case migrate-facts
prepare_ok
run_script run --intent=switch --config "$CUR_CONFIG"
expect_rc 0
expect_journal migration_attempt "done"
expect_journal migration_outcome verified
expect_journal migrate_rc 0
expect_journal ledger_after 660_attachment_upload_session_workspace
expect_journal migration_ledger_rows 684
expect_journal migration_tables 148
expect_journal migration_indexes 799/0/0
expect_no_journal migration_failed

step "B3: a failed dump keeps exactly the frozen stage and can be retried"
new_case dump-retry
prepare_ok
stub_opt dump-rc 1
run_script run --intent=switch --config "$CUR_CONFIG"
expect_rc 30
# The old requirement set made this stage unresumable: it demanded a backup the
# step had just failed to take, so the operator's only way forward was editing
# the journal.
expect_journal stage frozen
expect_no_journal backup_path
if [ "$(dump_count)" = 0 ]; then ok "no partial dump was recorded"; else bad "a partial dump was left"; fi
echo
stub_opt dump-rc
run_script run --intent=switch --config "$CUR_CONFIG"
expect_rc 0
expect_journal stage "done"
if [ "$(dump_count)" = 1 ]; then ok "exactly one successful dump exists"; else bad "$(dump_count) dumps exist"; fi
expect_log 'backup ok' 'took the backup after the cause was corrected'

step "B3: retrying the dump never overwrites an earlier recorded backup"
new_case dump-retry-keeps-first
prepare_ok
stub_opt dump-rc 1
run_script run --intent=switch --config "$CUR_CONFIG"
expect_rc 30
stub_opt dump-rc
# A stray file with the second attempt's name must not be overwritten: an
# earlier attempt's bytes are evidence, not scratch space.
run_script run --intent=switch --config "$CUR_CONFIG"
expect_rc 0
recorded="$(journal_get backup_path)"
expect_sha "$recorded" "$(journal_get backup_sha256)"
if [ "$(dump_count)" = 1 ]; then ok "one dump exists"; else bad "$(dump_count) dumps exist"; fi

step "B3: a recorded backup is never replaced by a second one"
new_case backup-not-replaced
prepare_ok
stub_opt compose-rc 1
run_script run --intent=switch --config "$CUR_CONFIG"
expect_rc 50
first_path="$(journal_get backup_path)"
first_sha="$(journal_get backup_sha256)"
stub_opt compose-rc
run_script run --intent=switch --config "$CUR_CONFIG"
expect_rc 0
expect_journal backup_path "$first_path"
expect_journal backup_sha256 "$first_sha"
if [ "$(dump_count)" = 1 ]; then ok "the first backup is still the only one"; else bad "$(dump_count) dumps exist"; fi

step "B: no case has to edit the journal to clear a latch"
# A latch an operator can clear by hand is not a latch, and a resume that needs a
# hand-edited journal is the defect these cases exist to prevent. Every latch in
# the suite must be cleared by its own cause, through the executor's CLI. The
# pattern matches a key *assignment* so this check does not match itself.
latch_edits=$(grep -nE 'sed -i .*(migrate_failed|migration_attempt|migration_outcome)=' "$0" || true)
if [ -n "$latch_edits" ]; then
    bad "a case clears a migration latch by editing the journal: $latch_edits"
else
    ok "no case clears a migration latch by hand"
fi

step "the documented config example is usable as written"
# The runbook hands the operator a KEY=VALUE block to copy. If it omits a key the
# executor requires, following the document produces exit 2 — the document would
# be the defect, not the operator. Extract the block and feed it to the executor
# after pointing its paths at the sandbox.
new_case documented-config
DOC="$SCRIPT_DIR/../docs/nas-myswy-maintenance.md"
if [ ! -f "$DOC" ]; then
    bad "the runbook is missing at $DOC"
else
    awk '/^COMPOSE_DIR=/{inside=1} inside && /^[A-Z0-9_]+=/{print} inside && /^```/{exit}' "$DOC" >"$CUR/doc.conf"
    if [ ! -s "$CUR/doc.conf" ]; then
        bad "no config example could be extracted from $DOC"
    else
        # Point every path and hash at the fixture; the example's *keys* are what
        # is under test, not its production values.
        sed -i \
            -e "s|^COMPOSE_DIR=.*|COMPOSE_DIR=$CUR/compose|" \
            -e "s|^COMPOSE_FILE=.*|COMPOSE_FILE=$CUR/compose/docker-compose.yml|" \
            -e "s|^COMPOSE_FILE_NEW=.*|COMPOSE_FILE_NEW=$CUR/compose/docker-compose.approved.yml|" \
            -e "s|^CLI_BIN=.*|CLI_BIN=$CUR/cli-bin/multica|" \
            -e "s|^UPGRADE_SCRIPT=.*|UPGRADE_SCRIPT=$CUR/scripts/upgrade-multica.sh|" \
            -e "s|^CLI_ARCHIVE=.*|CLI_ARCHIVE=$CUR/multica-cli.tar.gz|" \
            -e "s|^APPROVED_UPGRADE_SCRIPT=.*|APPROVED_UPGRADE_SCRIPT=$CUR/approved-upgrade-multica.sh|" \
            -e "s|^STATE_DIR=.*|STATE_DIR=$CUR/state-dir|" \
            -e "s|^LOG=.*|LOG=$CUR/maintenance.log|" \
            -e "s|^BACKUP_DIR=.*|BACKUP_DIR=$CUR/backup|" \
            -e "s|^CLI_ARCHIVE_SHA256=.*|CLI_ARCHIVE_SHA256=$CLI_ARCHIVE_SHA|" \
            -e "s|^APPROVED_UPGRADE_SHA256=.*|APPROVED_UPGRADE_SHA256=$APPROVED_SHA|" \
            "$CUR/doc.conf"
        run_script prepare --config "$CUR/doc.conf"
        expect_rc 0
        expect_log 'prepare ok' 'the documented example drives a real prepare'
        for k in FRONTEND_URL BACKEND_URL DOCKER_NETWORK STATE_DIR; do
            if grep -qE "^$k=" "$CUR/doc.conf"; then
                ok "the example names $k"
            else
                bad "the documented example omits $k"
            fi
        done
    fi
fi

step "the documented recovery table names every resumable stage"
DOC="$SCRIPT_DIR/../docs/nas-myswy-maintenance.md"
if [ ! -f "$DOC" ]; then
    bad "the runbook is missing"
else
    for stage in prepared frozen backup migrated switched cli verified "done"; do
        if grep -qE "^\| \`$stage\`" "$DOC"; then
            ok "the runbook says what \`$stage\` allows"
        else
            bad "the runbook's recovery table does not cover \`$stage\`"
        fi
    done
fi

step "B4: drift injected at every stage boundary cannot produce a false success"
# The general form of the three findings: for each stage a re-run can start from,
# break one thing the remaining steps depend on and assert the run does not
# report success. The damage is applied to the *live* system and to the staged
# assets — exactly what an operator, a timer, a crash or another process can do
# between two runs — never to the journal.
#
# Each entry is "<stage>|<damage key>|<human label>". The key selects the
# mutation in break_thing; the label only appears in the case header.
#
# Only drift the remaining steps cannot legitimately repair belongs here. A live
# CLI broken before `cli` runs is *repaired* by the install, and a watcher that
# came back before `freeze` is *stopped* by the freeze — both are the tool doing
# its job, not a false success. Those are asserted separately below.
drift_matrix() {
    cat <<'ENTRIES'
prepared|staged-cli|the staged CLI
prepared|staged-script|the approved upgrade script
frozen|writer|a writer that came back
frozen|staged-script|the approved upgrade script
backup|backup|the recorded backup
backup|staged-cli|the staged CLI
migrated|schema|the database schema
migrated|writer|a writer that came back
switched|frontend|the frontend process
switched|backend-image|the backend container image
switched|staged-script|the staged upgrade script
cli|cli|the installed CLI
cli|script|the installed upgrade script
cli|frontend|the frontend process
cli|schema|the database schema
verified|cli|the installed CLI
verified|backup|the recorded backup
verified|staged-cli|the staged CLI
verified|frontend|the frontend process
ENTRIES
}

# reach_stage <stage> — drive a real run to the named stage and leave it there.
reach_stage() {
    case $1 in
        prepared) prepare_ok || return 1; return 0 ;;
        frozen)
            prepare_ok || return 1
            stub_opt dump-rc 1
            run_script run --intent=switch --config "$CUR_CONFIG"
            stub_opt dump-rc
            ;;
        backup)
            prepare_ok || return 1
            stub_opt migrate-rc 1
            run_script run --intent=switch --config "$CUR_CONFIG"
            stub_opt migrate-rc
            ;;
        migrated)
            prepare_ok || return 1
            stub_opt compose-rc 1
            run_script run --intent=switch --config "$CUR_CONFIG"
            stub_opt compose-rc
            ;;
        switched)
            # Reach `migrated`, then let only the cli step fail: an unexecutable
            # staged CLI makes `cli` fail without changing the world.
            prepare_ok || return 1
            if [ -f "$CUR/state-dir/assets/cli/unpack/multica" ]; then
                chmod 644 "$CUR/state-dir/assets/cli/unpack/multica"
            fi
            run_script run --intent=switch --config "$CUR_CONFIG"
            chmod 755 "$CUR/state-dir/assets/cli/unpack/multica" 2>/dev/null
            ;;
        cli)
            prepare_ok || return 1
            world_post_switch
            stub_opt frontend-never 1
            run_script run --intent=switch --config "$CUR_CONFIG"
            stub_opt frontend-never
            ;;
        verified) thaw_then_break ;;
    esac
    if [ "$(journal_get stage)" != "$1" ]; then
        bad "could not reach stage '$1' (it is '$(journal_get stage)')"
        return 1
    fi
    return 0
}

# break_thing <what> — the drift, applied after the stage was reached.
break_thing() {
    case $1 in
        cli) write_cli "$CUR/cli-bin/multica" "$CLI_VERSION_OLD" ;;
        staged-cli) printf '#!/bin/sh\nprintf "multica 0.9.0-myswy.2\\n"\n' >"$CUR/state-dir/assets/cli/unpack/multica"; chmod 755 "$CUR/state-dir/assets/cli/unpack/multica" ;;
        staged-script) printf '# changed\n' >>"$CUR/state-dir/assets/approved-upgrade-multica.sh" ;;
        script) printf '# changed\n' >>"$CUR/scripts/upgrade-multica.sh" ;;
        backup) rm -f "$(journal_get backup_path)" ;;
        schema) printf '616_member_pinned\n' >"$CUR/state/ledger" ;;
        writer) set_unit multica-attachment-gc.service active ;;
        frontend) printf 'false\n' >"$CUR/state/containers/multica-frontend-1.running"
                  printf 'exited\n' >"$CUR/state/containers/multica-frontend-1.status" ;;
        backend-image) set_container multica-backend-1 "$BACKEND_IMAGE_OLD" ;;
        *) return 1 ;;
    esac
    return 0
}

while IFS='|' read -r stage damage what; do
    [ -n "$stage" ] || continue
    case $stage in \#*) continue ;; esac
    step "B4: $stage + drift in $what must not report success"
    new_case "drift-$stage-$damage"
    if reach_stage "$stage"; then
        break_thing "$damage" || { bad "unknown drift key '$damage'"; continue; }
        mark_calls "drift-$stage-$damage"
        run_script run --intent=switch --config "$CUR_CONFIG"
        case "$stage" in
            prepared|frozen|backup|migrated)
                # Up to the application start the drift must either re-freeze the
                # world or refuse; what it must never do is continue past it.
                if [ "$RC" -eq 0 ]; then
                    bad "[$stage/$what] the run reported success after the drift"
                else
                    ok "the run refused or stopped (exit $RC)"
                fi
                expect_no_log 'maintenance complete' '[no completion claimed]'
                ;;
            *)
                if [ "$RC" -eq 0 ]; then
                    # A successful continue is only acceptable if the drift was
                    # actually repaired by the step, which none of these can be.
                    bad "[$stage/$what] the run reported success over a drifted $what"
                else
                    ok "the run refused (exit $RC)"
                fi
                expect_no_log 'maintenance complete' '[no completion claimed]'
                if [ "$(journal_get stage)" = "done" ]; then
                    bad "[$stage/$what] the journal reached done"
                else
                    ok "the journal did not reach done"
                fi
                ;;
        esac
        # Whatever it decided, it must not have written a success over the drift.
        if [ "$(journal_get stage)" = "done" ] && [ "$RC" -ne 0 ]; then
            bad "[$stage/$what] the journal reached done but the run failed"
        fi
    fi
done < <(drift_matrix)

step "B4: drift the remaining steps can legitimately repair is repaired, not faked"
# The counterpart of the matrix, in the other direction: a broken live CLI before
# `cli` and a watcher that came back before `freeze` are exactly what those steps
# exist to fix. Each case asserts the step really did the work — a new installed
# binary with the recorded hash, a re-stopped unit — rather than that the run
# merely returned zero.
new_case drift-repaired-by-steps
prepare_ok
write_cli "$CUR/cli-bin/multica" "$CLI_VERSION_OLD"
set_unit multica-attachment-gc.service active
run_script run --intent=switch --config "$CUR_CONFIG"
expect_rc 0
expect_log 'maintenance complete' 'the run completes'
expect_sha "$CUR/cli-bin/multica" "$(journal_get cli_binary_sha256)"
expect_unit multica-attachment-gc.service inactive
expect_unit multica-daemon active

step "B4: a repaired drift resumes to a real success"
# The counterpart of the matrix: after the operator fixes the cause, the run must
# complete. Otherwise every drift case above could pass by refusing forever.
new_case drift-repaired
if reach_stage verified; then
    write_cli "$CUR/cli-bin/multica" "$CLI_VERSION_OLD"
    run_script run --intent=switch --config "$CUR_CONFIG"
    if [ "$RC" -eq 0 ]; then bad "the drifted run succeeded"; else ok "the drifted run refused (exit $RC)"; fi
    # Put the installed CLI back the way `cli` left it and resume.
    write_cli "$CUR/cli-bin/multica" "$CLI_VERSION_NEW"
    run_script run --intent=switch --config "$CUR_CONFIG"
    expect_rc 0
    expect_journal stage "done"
    expect_log 'maintenance complete' 'completes once the drift is repaired'
fi

# ---------------------------------------------------------------------------
# C: atomic evidence commits and pre-side-effect verification.
#
# Round 3 found that several transitions wrote their facts and their stage as
# separate renames, so an interruption between them produced a journal that read
# like a different state than the host was in. Every case below injects a failure
# at one exact write and then asserts on the things an exit code cannot show:
# how many times a command ran, whether a file on disk changed, and whether the
# journal holds the complete set of facts it claims.
# ---------------------------------------------------------------------------

# install_mv_fault <signature> [kill]
#
# A `mv` placed ahead of the real one on PATH. It matches the committed journal
# by *content* — the signature must appear in the temp file being renamed — so a
# case can fail exactly one transition and let every other one through. Matching
# on the transition's position would fail whichever write happened to be first.
#
# With "kill" the rename is performed and then the executor is signalled, which
# is how a process interruption at a known point is reproduced without racing.
install_mv_fault() {
    # The signature is read from mv-fault-sig by the stub, not by this function;
    # $1 documents it at the call site.
    local _sig=$1 action=${2:-fail} dir="$CUR/fault-stubs"
    mkdir -p "$dir"
    cp -a "$STUBS/systemctl" "$STUBS/docker" "$STUBS/curl" "$dir/"
    cat >"$dir/mv" <<STUB
#!/usr/bin/env bash
sig=\$(cat "\$TB/state/opt/mv-fault-sig" 2>/dev/null)
dst=\${!#}
src=\${@: -2:1}
if [ -n "\$sig" ] && [ "\$dst" = "\$TB/state-dir/journal" ] && grep -qF -- "\$sig" "\$src" 2>/dev/null; then
    rm -f "\$TB/state/opt/mv-fault-sig"
    if [ "$action" = kill ]; then
        /usr/bin/mv "\$@" || exit \$?
        cmd=\$(tr '\\0' ' ' <"/proc/\$PPID/cmdline")
        case "\$cmd" in *nas-maintenance.sh*run*) kill -TERM "\$PPID" ;; *) exit 99 ;; esac
        exit 0
    fi
    exit 1
fi
exec /usr/bin/mv "\$@"
STUB
    chmod +x "$dir/mv"
    RUN_STUBS="$dir"
}

run_faulty() {
    local saved=$STUBS
    STUBS="$RUN_STUBS"
    run_script "$@"
    STUBS=$saved
}

# Counts that survive `grep` finding nothing: `grep -c` prints 0 *and* exits 1,
# so a bare `|| printf 0` would append a second zero.
count_calls() { grep -c -- "$1" "$CUR/state/calls.log" 2>/dev/null | head -1; }
migration_calls() { local n; n=$(count_calls '^docker run '); printf '%s' "${n:-0}"; }
unit_stop_calls() { local n; n=$(count_calls '^systemctl stop '); printf '%s' "${n:-0}"; }

step "C1: a failed migrated commit does not authorise a second migration"
# The commit that carries the verified result *and* stage=migrated is refused.
# What must be true afterwards: the result facts are not on disk without the
# stage, and a retry does not run the migration a second time.
new_case migrated-commit-fail
prepare_ok
# Fail the rename that carries `stage=migrated`. On a revision that writes the
# result first and the stage second, this leaves the result on disk without the
# stage — the exact state that made a retry migrate twice. On this revision both
# are in one write, so the whole transition is refused and nothing lands.
install_mv_fault 'stage=migrated'
stub_opt mv-fault-sig 'stage=migrated'
run_faulty run --intent=switch --config "$CUR_CONFIG"
if [ "$RC" -ne 0 ]; then ok "the run failed (exit $RC)"; else bad "the run reported success without committing its stage"; fi
# The failure record legitimately writes `migration_outcome=failed: ...`; what
# must never appear is a *verified* outcome, because that is the fact a resume
# reads as "the migration is done".
if [ "$(journal_get migration_outcome 2>/dev/null)" = verified ]; then
    bad "a verified migration outcome was committed without stage=migrated"
else
    ok "no verified migration result was committed without its stage"
fi
expect_journal migration_attempt pending
expect_journal stage backup
first_calls="$(migration_calls)"
if [ "$first_calls" = 1 ]; then ok "the migration ran once"; else bad "the migration ran $first_calls times"; fi
stub_opt mv-fault-sig
mark_calls migrated-retry
run_faulty run --intent=switch --config "$CUR_CONFIG"
if [ "$RC" -ne 0 ]; then ok "the retry refused (exit $RC)"; else bad "the retry reported success"; fi
expect_no_log 'maintenance complete' 'never claims completion'
after_calls="$(migration_calls)"
if [ "$after_calls" = "$first_calls" ]; then
    ok "the retry did not run the migration again ($after_calls calls)"
else
    bad "migration calls went $first_calls -> $after_calls"
fi
expect_no_call_since_mark 'compose .* up' 'the application was not started'

step "C2: a partially written migration result cannot reach done"
new_case migration-fact-write-fail
prepare_ok
# Fail only the commit that carries the verified result, leaving the attempt and
# every live check intact. The run must not exit 0.
install_mv_fault 'migration_outcome=verified'
stub_opt mv-fault-sig 'migration_outcome=verified'
run_faulty run --intent=switch --config "$CUR_CONFIG"
stub_opt mv-fault-sig
if [ "$RC" -ne 0 ]; then ok "the run failed (exit $RC)"; else bad "the run reported success with no committed result"; fi
if [ "$(journal_get stage)" = "done" ]; then bad "the journal reached done"; else ok "the journal did not reach done"; fi
for k in migration_tables migration_indexes migration_verified_at; do
    if journal_get "$k" >/dev/null 2>&1; then
        bad "journal holds $k even though the commit failed"
    else
        ok "journal has no $k"
    fi
done
if [ "$(journal_get migration_outcome 2>/dev/null)" = verified ]; then
    bad "the failed commit still recorded a verified outcome"
else
    ok "the failed commit did not record a verified outcome"
fi

step "C2: a done journal is only written together with its completion fact"
new_case done-completes-journal
prepare_ok
run_script run --intent=switch --config "$CUR_CONFIG"
expect_rc 0
expect_journal stage "done"
expect_journal completed_at "$(journal_get completed_at)"
if journal_get completed_at >/dev/null 2>&1; then
    ok "the terminal stage carries its completion time"
else
    bad "the terminal stage was written without completed_at"
fi
# And the whole record must still satisfy the done-stage key list.
run_script status --config "$CUR_CONFIG"
expect_rc 0
expect_no_log 'CORRUPT' 'the terminal journal is not corrupt'

step "C3: a clean backup with no migration attempt continues the first migration"
# The ordinary "the window stopped before migrating" state, built through the
# real flow: a full backup is committed and the process is interrupted right
# after. That leaves stage=backup with a complete recovery point and no attempt
# key — which must be resumable, and must run the first migration.
new_case backup-clean-resume
prepare_ok
install_mv_fault 'backup_path=' kill
stub_opt mv-fault-sig 'backup_path='
run_faulty run --intent=switch --config "$CUR_CONFIG"
stub_opt mv-fault-sig
if [ "$(journal_get stage)" = "backup" ]; then
    ok "the window stopped at backup"
else
    bad "could not arrange a clean backup stage (stage=$(journal_get stage))"
fi
# A clean backup: the recovery point is fully described and nothing migrated.
expect_no_journal migration_attempt
for k in backup_path backup_sha256 backup_bytes backup_toc_lines backup_at; do
    if journal_get "$k" >/dev/null 2>&1; then
        ok "the recovery point is complete ($k)"
    else
        bad "the recovery point has no $k"
    fi
done
before="$(migration_calls)"
run_script run --intent=switch --config "$CUR_CONFIG"
expect_rc 0
expect_journal stage "done"
after="$(migration_calls)"
if [ "$after" -gt "$before" ]; then
    ok "the resume ran the first migration ($before -> $after)"
else
    bad "the resume did not run the migration ($before -> $after)"
fi
expect_log 'maintenance complete' 'completes the window'

step "C4: a drifted candidate is refused before the CLI and updater are replaced"
# Reach `switched` through the real flow (the staged CLI made non-executable
# stops the cli step after switch committed), then restore it and drift the
# candidate. Nothing may be installed once the candidate is wrong.
new_case switched-drift-before-install
prepare_ok
chmod 644 "$CUR/state-dir/assets/cli/unpack/multica"
run_script run --intent=switch --config "$CUR_CONFIG"
chmod 755 "$CUR/state-dir/assets/cli/unpack/multica"
if [ "$(journal_get stage)" = "switched" ]; then
    ok "the window stopped at switched"
else
    bad "could not stop at switched (stage=$(journal_get stage))"
fi
cli_sha_before="$(sha256sum "$CUR/cli-bin/multica" | awk '{ print $1 }')"
script_sha_before="$(sha256sum "$CUR/scripts/upgrade-multica.sh" | awk '{ print $1 }')"
set_container multica-backend-1 "$BACKEND_IMAGE_OLD"
mark_calls switched-drift
run_script run --intent=switch --config "$CUR_CONFIG"
if [ "$RC" -ne 0 ]; then ok "the resume refused (exit $RC)"; else bad "the resume reported success over a drifted candidate"; fi
expect_sha "$CUR/cli-bin/multica" "$cli_sha_before"
expect_sha "$CUR/scripts/upgrade-multica.sh" "$script_sha_before"
expect_no_call_since_mark 'systemctl start' 'started no unit'
expect_no_log 'maintenance complete' 'never claims completion'

step "C4: each candidate dimension is checked before the install"
# The same case for the frontend and the schema: the CLI and updater must be
# untouched in every one of them.
for drift in frontend schema; do
    if [ "$drift" = frontend ]; then
        step "C4: a frontend that stopped before the resume blocks the install"
    else
        step "C4: a schema that regressed before the resume blocks the install"
    fi
    new_case "switched-drift-$drift"
    prepare_ok
    chmod 644 "$CUR/state-dir/assets/cli/unpack/multica"
    run_script run --intent=switch --config "$CUR_CONFIG"
    chmod 755 "$CUR/state-dir/assets/cli/unpack/multica"
    cli_sha_before="$(sha256sum "$CUR/cli-bin/multica" | awk '{ print $1 }')"
    script_sha_before="$(sha256sum "$CUR/scripts/upgrade-multica.sh" | awk '{ print $1 }')"
    if [ "$drift" = frontend ]; then
        printf 'false\n' >"$CUR/state/containers/multica-frontend-1.running"
        printf 'exited\n' >"$CUR/state/containers/multica-frontend-1.status"
    else
        printf '616_member_pinned\n' >"$CUR/state/ledger"
    fi
    run_script run --intent=switch --config "$CUR_CONFIG"
    if [ "$RC" -ne 0 ]; then ok "the resume refused (exit $RC)"; else bad "the resume reported success"; fi
    expect_sha "$CUR/cli-bin/multica" "$cli_sha_before"
    expect_sha "$CUR/scripts/upgrade-multica.sh" "$script_sha_before"
    expect_no_log 'maintenance complete' 'never claims completion'
done

step "C5: tampered staged assets stop the window before it opens"
new_case prepared-updater-tamper
prepare_ok
target_before="$(sha256sum "$CUR/scripts/upgrade-multica.sh" | awk '{ print $1 }')"
printf '# tampered staged source\n' >>"$CUR/state-dir/assets/approved-upgrade-multica.sh"
mark_calls prepared-tamper
run_script run --intent=switch --config "$CUR_CONFIG"
if [ "$RC" -ne 0 ]; then ok "the run refused (exit $RC)"; else bad "the run reported success over a tampered staged asset"; fi
stops="$(unit_stop_calls)"; stops=${stops:-0}
if [ "$stops" -eq 0 ]; then ok "stopped no unit before noticing"; else bad "stopped $stops units before noticing"; fi
migs="$(migration_calls)"; migs=${migs:-0}
if [ "$migs" -eq 0 ]; then ok "ran no migration before noticing"; else bad "ran the migration $migs times before noticing"; fi
expect_no_call_since_mark 'compose .* up' 'started no container'
expect_sha "$CUR/scripts/upgrade-multica.sh" "$target_before"
expect_no_log 'maintenance complete' 'never claims completion'

step "C5: a snapshot that drifted after prepare stops the window before it opens"
new_case prepared-snapshot-drift
prepare_ok
printf '\n# drifted\n' >>"$CUR/state-dir/assets/compose/docker-compose.initial.yml"
mark_calls prepared-snapshot
run_script run --intent=switch --config "$CUR_CONFIG"
if [ "$RC" -ne 0 ]; then ok "the run refused (exit $RC)"; else bad "the run reported success over a drifted snapshot"; fi
stops="$(unit_stop_calls)"; stops=${stops:-0}
if [ "$stops" -eq 0 ]; then ok "stopped no unit"; else bad "stopped $stops units"; fi
migs="$(migration_calls)"; migs=${migs:-0}
if [ "$migs" -eq 0 ]; then ok "ran no migration"; else bad "ran the migration $migs times"; fi

step "C6: an interrupted backup record never becomes a recovery point"
new_case backup-partial-record
prepare_ok
# Fail the one commit that would publish the backup facts and stage. The dump
# itself exists on disk; the record must not claim a recovery point exists.
install_mv_fault 'backup_toc_lines='
stub_opt mv-fault-sig 'backup_toc_lines='
run_faulty run --intent=switch --config "$CUR_CONFIG"
stub_opt mv-fault-sig
if [ "$RC" -ne 0 ]; then ok "the run failed (exit $RC)"; else bad "the run reported success with no committed backup"; fi
expect_journal stage frozen
for k in backup_path backup_sha256 backup_bytes backup_toc_lines; do
    if journal_get "$k" >/dev/null 2>&1; then
        bad "journal holds $k without the stage that describes it"
    else
        ok "journal has no $k"
    fi
done
# The retry takes a backup and must end with one fully described recovery point.
run_script run --intent=switch --config "$CUR_CONFIG"
expect_rc 0
for k in backup_path backup_sha256 backup_bytes backup_toc_lines backup_at; do
    if journal_get "$k" >/dev/null 2>&1; then
        ok "the recovery point is recorded with $k"
    else
        bad "the recovery point has no $k"
    fi
done
recorded="$(journal_get backup_path)"
expect_sha "$recorded" "$(journal_get backup_sha256)"
if [ "$(journal_get backup_bytes)" = "$(stat -c '%s' "$recorded")" ]; then
    ok "the recorded byte count matches the file"
else
    bad "the recorded byte count does not match the file"
fi
# Every dump an earlier attempt left behind is kept as evidence.
if [ "$(dump_count)" -ge 2 ]; then
    ok "the interrupted attempt's dump was kept ($(dump_count) dumps)"
else
    bad "an earlier dump was deleted ($(dump_count) dumps)"
fi


# D: every resumed side effect keeps the recovery evidence and actual schema valid.
stop_at_committed_stage() {
    local wanted=$1
    prepare_ok || return 1
    install_mv_fault "stage=$wanted" kill
    stub_opt mv-fault-sig "stage=$wanted"
    run_faulty run --intent=switch --config "$CUR_CONFIG"
    expect_rc 143
    expect_journal stage "$wanted"
}

step "D1: immutable rollback files are checked at every resume boundary"
while IFS='|' read -r boundary snapshot; do
    new_case "resume-snapshot-$boundary"
    stop_at_committed_stage "$boundary"
    printf '# damaged recovery material\n' >>"$CUR/state-dir/assets/$snapshot"
    cli_before=$(sha256sum "$CUR/cli-bin/multica" | awk '{print $1}')
    compose_before=$(sha256sum "$CUR/compose/docker-compose.yml" | awk '{print $1}')
    mark_calls snapshot-drift
    run_script run --intent=switch --config "$CUR_CONFIG"
    expect_rc 80
    expect_journal stage "$boundary"
    expect_no_call_since_mark 'docker run|compose .* up|systemctl start' 'no migration, application or unit start'
    expect_sha "$CUR/cli-bin/multica" "$cli_before"
    expect_sha "$CUR/compose/docker-compose.yml" "$compose_before"
done <<'BOUNDARIES'
frozen|previous/multica
backup|compose/docker-compose.initial.yml
migrated|compose/docker-compose.rollback.yml
switched|previous/upgrade-multica.sh
cli|compose/docker-compose.new.yml
verified|previous/multica
BOUNDARIES

step "D2: staged input drift is refused before resumed database work"
for boundary in frozen backup migrated; do
    new_case "resume-source-$boundary"
    stop_at_committed_stage "$boundary"
    printf '# damaged staged input\n' >>"$CUR/state-dir/assets/approved-upgrade-multica.sh"
    mark_calls staged-drift
    run_script run --intent=switch --config "$CUR_CONFIG"
    expect_rc 80
    expect_journal stage "$boundary"
    expect_no_call_since_mark 'docker run|compose .* up|systemctl start' 'nothing migrated or started'
done

step "D3: migration and candidate startup require the current schema"
for boundary in backup migrated; do
    new_case "resume-schema-$boundary"
    stop_at_committed_stage "$boundary"
    printf '130\n' >"$CUR/state/tables"
    compose_before=$(sha256sum "$CUR/compose/docker-compose.yml" | awk '{print $1}')
    mark_calls schema-drift
    run_script run --intent=switch --config "$CUR_CONFIG"
    expect_rc 40
    expect_journal stage "$boundary"
    expect_no_call_since_mark 'docker run|compose .* up' 'schema drift cannot migrate or start candidates'
    expect_sha "$CUR/compose/docker-compose.yml" "$compose_before"
done

step "D4: journal construction errors cannot erase prior evidence"
for fault in attempt backup migrated; do
    new_case "journal-read-$fault"
    prepare_ok
    initial_hash=$(journal_get initial_compose_sha256)
    fault_stubs="$TMP/journal-fault-$fault"
    cp -a "$STUBS" "$fault_stubs"
    cat >"$fault_stubs/awk" <<'AWK_STUB'
#!/usr/bin/env bash
if [ "${!#}" = "$TB/state-dir/journal" ]; then
    mode=$(cat "$TB/state/opt/journal-read-fault" 2>/dev/null)
    case "$mode:${2:-}" in
        attempt:k=migration_attempt_at=)
            [ "${3:-}" != 'index($0, k) != 1' ] || exit 1 ;;
        backup:drop=*) [[ "$2" != *backup_path* ]] || exit 1 ;;
        migrated:drop=*) [[ "$2" != *migration_verified_at* ]] || exit 1 ;;
    esac
fi
exec /usr/bin/awk "$@"
AWK_STUB
    chmod +x "$fault_stubs/awk"
    saved_stubs=$STUBS
    STUBS=$fault_stubs
    stub_opt journal-read-fault "$fault"
    run_script run --intent=switch --config "$CUR_CONFIG"
    STUBS=$saved_stubs
    case $fault in
        backup) expect_rc 30; expect_journal stage frozen; expected_calls=0 ;;
        attempt) expect_rc 40; expect_journal stage backup; expect_journal migration_attempt pending; expected_calls=0 ;;
        migrated) expect_rc 40; expect_journal stage backup; expect_journal migration_attempt pending; expected_calls=1 ;;
    esac
    expect_journal initial_compose_sha256 "$initial_hash"
    if [ "$(migration_calls)" = "$expected_calls" ]; then ok "only $expected_calls authorised migration calls"; else bad "unexpected migration call count"; fi
    expect_no_call 'compose .* up' 'no candidates started after a journal construction failure'
    expect_no_log 'maintenance complete' 'no false completion'
done

# ---------------------------------------------------------------------------
printf '\n'
if [ "$FAIL" -eq 0 ]; then
    printf '\033[32m%s checks passed\033[0m\n' "$PASS"
    exit 0
fi
printf '\033[31m%s passed, %s failed\033[0m\n' "$PASS" "$FAIL"
for f in "${FAILURES[@]}"; do printf '  - %s\n' "$f"; done
exit 1
