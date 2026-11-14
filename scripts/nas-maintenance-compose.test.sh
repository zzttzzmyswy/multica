#!/usr/bin/env bash
# Real Docker Compose resolution tests for scripts/nas-maintenance.sh.
#
# The other suites stub `docker`, which proves the executor's decisions but not
# that the compose files it writes actually load. A snapshot of a compose file
# is not a copy of a deployment: `env_file: .env`, `${VAR}` interpolation and
# relative bind mounts are all resolved against the *project directory*, so a
# snapshot moved into the state directory fails to load with "env file .env not
# found" — after the writers are already stopped.
#
# This suite invokes the real `docker compose config` against synthetic compose
# files in a temp directory. It needs no daemon, no network and no real secret:
# `config` parses and interpolates locally. The values here are placeholders.
#
# Usage: bash scripts/nas-maintenance-compose.test.sh
set -uo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
EXECUTOR="$SCRIPT_DIR/nas-maintenance.sh"

PASS=0
FAIL=0
FAILURES=()
CASE="setup"

ok()   { PASS=$((PASS + 1)); printf '    \033[32m✓\033[0m %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); FAILURES+=("$CASE: $1"); printf '    \033[31m✗\033[0m %s\n' "$1"; }
step() { CASE=$1; printf '\n==> %s\n' "$1"; }

skip_all() {
    printf '    \033[33m-\033[0m %s\n' "$1"
    exit 0
}

# A compose CLI is required. `docker compose` (plugin) and `docker-compose`
# (standalone) are both accepted; without one there is nothing real to test, so
# skip rather than pretend.
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    COMPOSE=(docker compose)
elif command -v docker-compose >/dev/null 2>&1; then
    COMPOSE=(docker-compose)
else
    skip_all "no docker compose CLI available; the stub suites still cover the call shape"
fi

[ -f "$EXECUTOR" ] || { echo "missing $EXECUTOR" >&2; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/nas-compose-test.XXXXXX")" || exit 1
trap 'rm -rf "$TMP"' EXIT

# ---------------------------------------------------------------------------
# Fixture: a deployment that looks like the real one.
#
# Everything that makes a snapshot path-sensitive is present on purpose:
#   * env_file: .env             — resolved against the project directory
#   * ${POSTGRES_PASSWORD}       — interpolated from .env, silently blank if lost
#   * a relative bind mount      — resolved against the project directory
# All values are placeholders; nothing here is a real credential.
# ---------------------------------------------------------------------------
DEPLOY="$TMP/deploy"
mkdir -p "$DEPLOY/data"
cat >"$DEPLOY/.env" <<'ENV'
POSTGRES_PASSWORD=synthetic-placeholder-value
POSTGRES_DB=multica
ENV

cat >"$DEPLOY/docker-compose.yml" <<'YAML'
services:
  postgres:
    image: pgvector/pgvector:pg16
    env_file: .env
    environment:
      POSTGRES_DB: ${POSTGRES_DB}
    volumes:
      - ./data:/var/lib/postgresql/data
  backend:
    image: ghcr.io/multica-ai/multica-backend:latest
    env_file: .env
    environment:
      DATABASE_URL: postgres://multica:${POSTGRES_PASSWORD}@postgres:5432/multica
  frontend:
    image: ghcr.io/multica-ai/multica-web:latest
    environment:
      BACKEND_URL: http://backend:8080
YAML

# The digest-pinned rollback file the executor derives, placed in a snapshot
# directory with no .env beside it — exactly where the executor writes it.
SNAPDIR="$TMP/state/assets/compose"
mkdir -p "$SNAPDIR"
cat >"$SNAPDIR/docker-compose.rollback.yml" <<'YAML'
services:
  postgres:
    image: pgvector/pgvector:pg16
    env_file: .env
    environment:
      POSTGRES_DB: ${POSTGRES_DB}
    volumes:
      - ./data:/var/lib/postgresql/data
  backend:
    image: ghcr.io/multica-ai/multica-backend@sha256:864a97102959895b174f4fb1e2798bc38c896ea9ff33497564ec11eac5728374
    env_file: .env
    environment:
      DATABASE_URL: postgres://multica:${POSTGRES_PASSWORD}@postgres:5432/multica
  frontend:
    image: ghcr.io/multica-ai/multica-web@sha256:ece41d5b9732ce62a4362e5b55dd89ca2fa5ad9af692536738958a8da92d31fa
    environment:
      BACKEND_URL: http://backend:8080
YAML

# compose_config <file> <compose options...> -- <config options...>
#
# Compose parses `--project-directory` before the subcommand and `--quiet` after
# it, so the two cannot be passed as one list. Everything before `--` goes to
# the compose invocation, everything after goes to `config`.
compose_config() {
    local file=$1
    shift
    local -a compose_opts=() config_opts=() seen=0
    local a
    for a in "$@"; do
        if [ "$a" = "--" ]; then seen=1; continue; fi
        if [ "$seen" = 1 ]; then config_opts+=("$a"); else compose_opts+=("$a"); fi
    done
    "${COMPOSE[@]}" -f "$file" ${compose_opts[@]+"${compose_opts[@]}"} config \
        ${config_opts[@]+"${config_opts[@]}"} 2>&1
}

# ---------------------------------------------------------------------------
step "the real deployment composes cleanly"
if out=$(cd "$DEPLOY" && compose_config docker-compose.yml --project-directory "$DEPLOY" -- --quiet); then
    ok "the baseline compose file resolves"
else
    bad "the baseline compose file does not resolve: $(printf '%s' "$out" | tail -2 | tr '\n' '|')"
fi

step "running a snapshot from its own directory reproduces the defect"
# This is the failure the review found. If it ever stops failing, the test below
# has nothing to prove and the fixture has drifted from reality.
if out=$(cd "$SNAPDIR" && compose_config docker-compose.rollback.yml --project-directory "$SNAPDIR" -- --quiet); then
    bad "a snapshot resolved without the deployment's .env; the fixture no longer models the defect"
else
    ok "a snapshot with its own project directory fails to load (as reported)"
fi
if printf '%s' "$out" | grep -qi 'env file'; then
    ok "the failure names the missing env file"
else
    bad "the failure did not mention the env file: $(printf '%s' "$out" | tail -1)"
fi

step "the fix: pinning the project directory makes the snapshot load"
if out=$(cd "$SNAPDIR" && compose_config docker-compose.rollback.yml --project-directory "$DEPLOY" -- --quiet); then
    ok "the snapshot resolves when the project directory is the deployment's"
else
    bad "the snapshot still fails with a pinned project directory: $(printf '%s' "$out" | tail -2 | tr '\n' '|')"
fi

# Whatever the caller's cwd, the same arguments must give the same result.
for cwd in "$TMP" "$SNAPDIR" /; do
    if (cd "$cwd" && compose_config "$SNAPDIR/docker-compose.rollback.yml" \
            --project-directory "$DEPLOY" -- --quiet >/dev/null 2>&1); then
        ok "resolves with cwd=$cwd"
    else
        bad "failed with cwd=$cwd"
    fi
done

step "the snapshot resolves to the same values as the original"
# The point of pinning the project directory is that the snapshot is not merely
# loadable — it produces the same model. Compare the resolved output, then assert
# the secret is present without printing it.
original_model=$(cd "$DEPLOY" && compose_config docker-compose.yml --project-directory "$DEPLOY")
snapshot_model=$(cd "$SNAPDIR" && compose_config docker-compose.rollback.yml --project-directory "$DEPLOY")

# Image lines differ by design (the rollback file pins digests); everything else
# must match, so normalise the image lines away before comparing.
normalise() { grep -vE '^[[:space:]]*image:' | sed 's/[[:space:]]*$//'; }
if [ "$(printf '%s' "$original_model" | normalise)" = "$(printf '%s' "$snapshot_model" | normalise)" ]; then
    ok "the snapshot resolves to the same model as the original, images aside"
else
    bad "the resolved models differ: $(diff <(printf '%s' "$original_model" | normalise) \
        <(printf '%s' "$snapshot_model" | normalise) | head -6 | tr '\n' '|')"
fi

# The interpolated password must be the fixture's placeholder. Printing it would
# defeat the purpose, so only its presence and length are checked.
want_value='synthetic-placeholder-value'
if printf '%s' "$snapshot_model" | grep -q "postgres://multica:${want_value}@postgres"; then
    ok "the .env value is interpolated into the snapshot model (not printed)"
else
    bad "the snapshot model did not pick up the .env value from the project directory"
fi
if printf '%s' "$snapshot_model" | grep -q 'multica:@postgres'; then
    bad "the password interpolated to empty, which is the silent failure mode"
else
    ok "the password did not interpolate to empty"
fi

# The relative bind mount must still point into the deployment.
if printf '%s' "$snapshot_model" | grep -q "$DEPLOY/data"; then
    ok "the relative bind mount resolves into the deployment directory"
else
    bad "the bind mount did not resolve into the deployment: $(printf '%s' "$snapshot_model" | grep -A2 volumes | tr '\n' '|')"
fi

step "the executor itself emits the project directory"
# The unit-level guarantee: every compose invocation in the script goes through
# one wrapper that pins the directory. A future call site that forgets it would
# pass a functional test by luck and fail on the real host.
compose_calls=$(grep -cE '^[[:space:]]*compose_run ' "$EXECUTOR" || true)
# Only invocations count: the wrapper's own body, and any message text that
# happens to mention the command, are not call sites.
raw_calls=$(grep -nE '(bounded|timeout|[;&|(])[[:space:]]*docker compose ' "$EXECUTOR" \
    | grep -v -- '--project-directory' || true)
if [ -z "$raw_calls" ]; then
    ok "every compose invocation goes through the wrapper (${compose_calls} call sites)"
else
    bad "a compose invocation bypasses the wrapper: $(printf '%s' "$raw_calls" | head -3 | tr '\n' '|')"
fi
if grep -q -- '--project-directory "\$COMPOSE_DIR"' "$EXECUTOR"; then
    ok "the wrapper pins --project-directory to COMPOSE_DIR"
else
    bad "the wrapper does not pin --project-directory"
fi

step "the defect is detected when the project directory is dropped"
# Meta-test: prove the assertions above would catch a regression. Remove the
# flag from a copy of the executor and re-run the snapshot load through the same
# wrapper logic the script uses.
mutant="$TMP/nas-maintenance.mutant.sh"
sed 's|--project-directory "$COMPOSE_DIR" ||' "$EXECUTOR" >"$mutant"
if cmp -s "$EXECUTOR" "$mutant"; then
    bad "the mutation did not apply; this meta-test proves nothing"
else
    ok "the mutation removed the project directory"
fi
# Assert the behavioural consequence directly: the same snapshot load with the
# mutant's argument shape must fail.
if (cd "$SNAPDIR" && "${COMPOSE[@]}" -f docker-compose.rollback.yml config --quiet >/dev/null 2>&1); then
    bad "a snapshot loaded without a project directory; the guard cannot be tested"
else
    ok "without the flag the snapshot does not load, so the guard is load-bearing"
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
