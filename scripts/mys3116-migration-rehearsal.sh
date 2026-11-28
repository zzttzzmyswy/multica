#!/usr/bin/env bash
# Migration rehearsal for a fork sync. Three starting points, each upgraded by
# the CANDIDATE build twice, on an isolated PostgreSQL. Nothing here touches
# production, and every DSN comes from ADMIN_DSN.
#
#   1. from700  — a database the PREVIOUS release actually built: its own migrate
#                 binary applied at the previous tag, then seeded with
#                 representative rows.
#   2. from_empty — a fresh database (what a new install gets).
#   3. from660 — a database at the upload feature's block (the oldest supported
#                 starting point), built the same way from `v0.9.0-myswy.2`.
#
# Each case asserts: the first candidate run adds exactly the new block, the
# second adds nothing, both converge on the head, the old ledger rows keep their
# applied_at, and seeded business rows survive byte-identically.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ADMIN_DSN="${ADMIN_DSN:?set ADMIN_DSN to an isolated superuser DSN}"
BASE_TAG="${BASE_TAG:?set BASE_TAG to the previous release tag, e.g. v0.11.1-myswy.1}"
OLD_TAG="${OLD_TAG:-v0.9.0-myswy.2}"
HEAD_VERSION="${HEAD_VERSION:?set HEAD_VERSION to the highest migration number of this build}"
OUT_DIR="${OUT_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/fork-sync-rehearsal.XXXXXX")}"
RUN_ID="$(python3 -c 'import uuid; print(uuid.uuid4().hex)')"
owned_databases=()

mkdir -p "$OUT_DIR"
LOG="$OUT_DIR/rehearsal.log"
: >"$LOG"
say() { printf '%s\n' "$*" | tee -a "$LOG"; }
fail() { say "FAIL: $*"; exit 1; }

psql_admin() { psql "$ADMIN_DSN" -v ON_ERROR_STOP=1 -tAqc "$1"; }
dsn_for() { printf '%s' "${ADMIN_DSN%/*}/$1"; }

cleanup() {
  local status=$? name
  for name in "${owned_databases[@]}"; do
    dropdb --maintenance-db="$ADMIN_DSN" "$name" || status=1
  done
  exit "$status"
}
trap cleanup EXIT

fresh_db() {
  local name=$1
  createdb --maintenance-db="$ADMIN_DSN" --template=template0 "$name"
  owned_databases+=("$name")
  psql "$(dsn_for "$name")" -v ON_ERROR_STOP=1 -q >>"$LOG" 2>&1 <<'SQL'
CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE EXTENSION IF NOT EXISTS pgcrypto;
SQL
}

ledger_count() { psql "$(dsn_for "$1")" -tAqc 'SELECT count(*) FROM schema_migrations'; }
ledger_max() { psql "$(dsn_for "$1")" -tAqc 'SELECT max(version) FROM schema_migrations'; }

say "rehearsal start $(date -Is)"
say "base tag $BASE_TAG, oldest supported tag $OLD_TAG, head $HEAD_VERSION"
say "postgres: $(psql "$ADMIN_DSN" -tAqc 'SELECT version()' | cut -c1-40)"

# A worktree at BASE_TAG gives the previous release's OWN migrations directory and
# runner, so the 700 base is what that release really produced — not a subset of
# today's files played back in today's order.
BASE_WT="$OUT_DIR/base-$BASE_TAG"
OLD_WT="$OUT_DIR/base-$OLD_TAG"
if [ ! -d "$BASE_WT" ]; then
  git -C "$REPO_ROOT" worktree add --detach "$BASE_WT" "$BASE_TAG" >>"$LOG" 2>&1 || fail "worktree $BASE_TAG"
fi
if [ ! -d "$OLD_WT" ]; then
  git -C "$REPO_ROOT" worktree add --detach "$OLD_WT" "$OLD_TAG" >>"$LOG" 2>&1 || fail "worktree $OLD_TAG"
fi

run_migrate() {
  local tree=$1 db=$2 label=$3
  ( cd "$tree/server" && DATABASE_URL="$(dsn_for "$db")" go run ./cmd/migrate up ) >>"$LOG" 2>&1 \
    || fail "$label: migrate up failed (see $LOG)"
}

# seed_business_rows DB: rows that a schema change could plausibly disturb. The
# values are synthetic; the point is that the upgrade must leave them alone.
seed_business_rows() {
  local db=$1
  psql "$(dsn_for "$db")" -v ON_ERROR_STOP=1 -q >>"$LOG" 2>&1 <<'SQL'
DO $$
DECLARE ws uuid := '11111111-1111-4111-8111-111111111111';
        usr uuid := '22222222-2222-4222-8222-222222222222';
        iss uuid := '33333333-3333-4333-8333-333333333333';
        att uuid := '44444444-4444-4444-8444-444444444444';
BEGIN
  INSERT INTO "user" (id, email, name) VALUES (usr, 'seed@example.test', 'Seed')
    ON CONFLICT (id) DO NOTHING;
  INSERT INTO workspace (id, name, slug) VALUES (ws, 'Seed WS', 'seed-ws')
    ON CONFLICT (id) DO NOTHING;
  INSERT INTO issue (id, workspace_id, number, title, description, creator_type, creator_id)
    VALUES (iss, ws, 1, 'Seeded issue', 'Seeded description', 'member', usr)
    ON CONFLICT (id) DO NOTHING;
  INSERT INTO attachment (id, workspace_id, issue_id, uploader_type, uploader_id, filename,
                          url, content_type, size_bytes)
    VALUES (att, ws, iss, 'member', usr, 'seed.bin',
            'https://files.invalid/seed.bin', 'application/octet-stream', 12345)
    ON CONFLICT (id) DO NOTHING;
END $$;
SQL
}

# fingerprint DB: a stable digest of the seeded rows, so "unchanged" is a
# measured claim rather than an assertion.
fingerprint() {
  # A heredoc, not a quoted argument: the query names the reserved table "user",
  # and a double-quoted shell string would swallow those double quotes.
  psql "$(dsn_for "$1")" -tAq >>"${2:-/dev/stdout}" <<'SQL'
SELECT md5(string_agg(x, '|' ORDER BY x)) FROM (
  SELECT 'issue:'||id||':'||number||':'||title||':'||coalesce(description,'') AS x FROM issue
  UNION ALL SELECT 'att:'||id||':'||filename||':'||size_bytes||':'||url FROM attachment
  UNION ALL SELECT 'ws:'||id||':'||name||':'||slug FROM workspace
  UNION ALL SELECT 'usr:'||id||':'||email||':'||name FROM "user"
) s;
SQL
}

# ledger_ts_snapshot DB OUT: record every row present now, so after the upgrade
# each of those rows can be shown to still carry its original timestamp. The
# timestamp is printed with full precision and an explicit UTC zone: a ledger
# comparison that silently truncates or re-renders a zone cannot tell a rewritten
# row from an untouched one.
ledger_ts_snapshot() {
  psql "$(dsn_for "$1")" -tAqc "
    SELECT version || E'\t' || to_char(applied_at AT TIME ZONE 'UTC',
                                      'YYYY-MM-DD HH24:MI:SS.US')
      FROM schema_migrations ORDER BY version" >"$2" \
    || { echo "ledger_ts_snapshot: could not read schema_migrations in $1" >&2; return 1; }
  [ -s "$2" ] || { echo "ledger_ts_snapshot: snapshot $2 is empty" >&2; return 1; }
}

# ledger_ts_unchanged DB SNAPSHOT: every version in the snapshot is still present
# with the same applied_at, AND no version has disappeared from the ledger.
#
# Three separate comparisons, because a single join answers only the first and
# silently ignores the rest:
#   1. a snapshot row whose timestamp changed  -> rewritten ledger row
#   2. a snapshot row with no ledger row left  -> deleted ledger row
#   3. a ledger row with no snapshot row       -> an unexpected extra version
# Comparing the two row SETS by exact (version, timestamp) text catches all
# three at once; the join alone cannot, because a missing right-hand row simply
# produces no result rather than a mismatch.
#
# Failures are reported, never swallowed: a query error must fail the check, so
# there is no `|| echo 0` and no discarded stderr. An unreadable ledger is
# exactly the state this function exists to detect.
ledger_ts_unchanged() {
  local db=$1 snapshot=$2 current actual
  local -a problems=()

  [ -s "$snapshot" ] || { echo "ledger_ts_unchanged: snapshot $snapshot is empty" >&2; return 1; }

  current="$(mktemp "$OUT_DIR/.ledger-now.XXXXXX")"
  if ! psql "$(dsn_for "$db")" -tAqc "
        SELECT version || E'\t' || to_char(applied_at AT TIME ZONE 'UTC',
                                          'YYYY-MM-DD HH24:MI:SS.US')
          FROM schema_migrations ORDER BY version" >"$current" 2>&1; then
    echo "ledger_ts_unchanged: could not read schema_migrations in $db:" >&2
    sed 's/^/    /' "$current" >&2
    rm -f "$current"
    return 1
  fi

  # Row counts first: a deleted row is invisible to the join below.
  local want_n have_n
  want_n=$(wc -l <"$snapshot")
  have_n=$(wc -l <"$current")
  if [ "$have_n" -lt "$want_n" ]; then
    problems+=("ledger lost rows: $want_n before, $have_n after")
  fi

  # Exact line-set comparison. `comm` needs sorted input; both sides are already
  # ordered by version, and a duplicate version cannot occur (PRIMARY KEY).
  while IFS= read -r line; do
    case "$line" in
      '') continue ;;
    esac
    version=${line%%$'\t'*}
    before=${line#*$'\t'}
    actual="$(awk -F'\t' -v v="$version" '$1 == v { print $2; exit }' "$current")"
    if [ -z "$actual" ]; then
      problems+=("$version disappeared from schema_migrations")
    elif [ "$actual" != "$before" ]; then
      problems+=("$version applied_at changed: $before -> $actual")
    fi
  done <"$snapshot"

  # Rows the upgrade ADDS are the point of running it, so the ledger legitimately
  # grows; only a row that disappeared or changed is a problem. That is why the
  # count comparison above is one-directional in intent: it catches a deletion,
  # and the caller separately asserts how many rows the run was expected to add.
  # An extra version is therefore NOT a failure here — asserting otherwise would
  # fail every real upgrade, which is how this check first behaved.

  rm -f "$current"

  if [ "${#problems[@]}" -gt 0 ]; then
    local p
    for p in "${problems[@]}"; do
      echo "ledger_ts_unchanged: $p" >&2
    done
    return 1
  fi
  return 0
}

SHIPPED_COUNT=$(ls "$REPO_ROOT/server/migrations"/*.up.sql | wc -l | tr -d ' ')
say "candidate tree ships $SHIPPED_COUNT up migrations"
RESULTS="$OUT_DIR/results.tsv"
: >"$RESULTS"

rehearse() {
  local label=$1 base_tree=$2 db="sync_${1}_$RUN_ID"
  say ""
  say "=== case $label"
  fresh_db "$db"

  local base_count=0
  if [ -n "$base_tree" ]; then
    run_migrate "$base_tree" "$db" "$label base ($(basename "$base_tree"))"
    base_count=$(ledger_count "$db")
    say "  base built by the previous release: $base_count rows, head $(ledger_max "$db")"
    seed_business_rows "$db"
  fi
  local fp_before ts_before
  if [ "$base_count" -gt 0 ]; then
    fp_before=$(fingerprint "$db")
    ledger_ts_snapshot "$db" "$OUT_DIR/$label-ledger-before.txt"
  fi

  run_migrate "$REPO_ROOT" "$db" "$label candidate run 1"
  local after_first; after_first=$(ledger_count "$db")
  say "  after candidate run 1: $after_first rows (added $((after_first - base_count)))"

  run_migrate "$REPO_ROOT" "$db" "$label candidate run 2"
  local after_second; after_second=$(ledger_count "$db")
  say "  after candidate run 2: $after_second rows (added $((after_second - after_first)))"

  local head; head=$(ledger_max "$db")
  say "  head version: $head"

  # What the first run must add is the distance from the starting point to the
  # shipped head, measured on the shipped tree — NOT a fixed number. A database
  # at 700 gains only this sync's block; one at 660 also gains the previous
  # sync's 40; an empty one gains everything. Pinning one number would make the
  # two older cases assert the wrong thing.
  local expected=$((SHIPPED_COUNT - base_count))
  [ $((after_first - base_count)) -eq "$expected" ] \
    || fail "$label: first run added $((after_first - base_count)), expected $expected (from $base_count to $SHIPPED_COUNT)"
  [ $((after_second - after_first)) -eq 0 ] \
    || fail "$label: second run added $((after_second - after_first)), expected 0"
  case "$head" in "${HEAD_VERSION}_"*) ;; *) fail "$label: head is $head, expected a ${HEAD_VERSION}_ prefix";; esac

  if [ "$base_count" -gt 0 ]; then
    local fp_after
    fp_after=$(fingerprint "$db")
    [ "$fp_before" = "$fp_after" ] || fail "$label: seeded business rows changed ($fp_before -> $fp_after)"
    say "  seeded business rows unchanged: $fp_after"
    ledger_ts_unchanged "$db" "$OUT_DIR/$label-ledger-before.txt" \
      || fail "$label: an already-applied ledger row was rewritten"
    say "  every pre-existing ledger row kept its applied_at"
  fi

  printf '%s\t%s\t%s\t%s\t%s\n' "$label" "$base_count" "$after_first" "$after_second" "$head" >>"$RESULTS"
}

rehearse from700 "$BASE_WT"
rehearse from_empty ""
rehearse from660 "$OLD_WT"

say ""
say "=== summary (label, base rows, after run1, after run2, head)"
column -t -s $'\t' "$RESULTS" | tee -a "$LOG"
say ""
say "rehearsal complete $(date -Is)"
