#!/usr/bin/env bash
# Self-test for the ledger comparison in mys3116-migration-rehearsal.sh.
#
# The function it guards had three bugs at once, and all three were invisible
# because a PASS is what a broken comparison returns:
#
#   1. the inline VALUES list was built with a sed that produced
#      `'v','t'),'v','t')` — no opening parenthesis, no FROM, so psql rejected
#      the whole statement;
#   2. `2>/dev/null || echo "0"` then turned that rejection into the string "0",
#      which compares equal to "0" and reports success;
#   3. joining on version alone cannot see a DELETED row: a snapshot row with no
#      partner produces no output row, so `count(*) = 0` and it passes again.
#
# So the test is written as counterexamples: each mutation MUST be reported. A
# version that only asserts "the unchanged case passes" would have passed against
# the broken function too, which is the whole reason the bug shipped.
#
# Usage: ADMIN_DSN=<isolated superuser dsn> bash scripts/mys3116-ledger-check.test.sh
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REHEARSAL="$ROOT_DIR/scripts/mys3116-migration-rehearsal.sh"
ADMIN_DSN="${ADMIN_DSN:?set ADMIN_DSN to an isolated superuser DSN}"

PASS=0
FAIL=0
declare -a FAILURES=()
ok()  { PASS=$((PASS+1)); printf '    \033[32m✓\033[0m %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); FAILURES+=("$1"); printf '    \033[31m✗\033[0m %s\n' "$1"; }
step() { printf '\n==> %s\n' "$1"; }

# Every resource name carries this run's id, so two runs cannot collide and
# cleanup only ever removes what this run created.
RUN_ID="$(date +%s)-$$"
DB="ledger_check_${RUN_ID//-/_}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/ledger-check.XXXXXX")"

psql_admin() { psql "$ADMIN_DSN" -v ON_ERROR_STOP=1 -tAqc "$1"; }
dsn_for() { printf '%s' "${ADMIN_DSN%/*}/$1"; }
db() { psql "$(dsn_for "$DB")" -tAqc "$1"; }

owned_db=false
cleanup() {
  local status=$?
  if "$owned_db"; then
    dropdb --maintenance-db="$ADMIN_DSN" "$DB" || status=1
  fi
  rm -rf "$WORK"
  exit "$status"
}
trap cleanup EXIT

# Load the functions under test out of the rehearsal script rather than copying
# them: a copy can pass while the shipped function is still broken. Only the two
# ledger helpers and their two dependencies are extracted; the rest of that
# script drives migrations, which is not what this test is about.
step "Extract the two ledger helpers from the rehearsal script"
awk '
  /^# ledger_ts_snapshot DB OUT:/ { capture = 1 }
  /^SHIPPED_COUNT=/ { capture = 0 }
  capture { print }
' "$REHEARSAL" >"$WORK/helpers.sh"

for fn in ledger_ts_snapshot ledger_ts_unchanged; do
  if grep -q "^${fn}()" "$WORK/helpers.sh"; then
    ok "extracted $fn"
  else
    bad "could not extract $fn from $REHEARSAL — the test cannot guard what it cannot see"
  fi
done
[ "$FAIL" -eq 0 ] || { printf 'cannot continue\n'; exit 1; }

# shellcheck disable=SC1091
. "$WORK/helpers.sh"
OUT_DIR="$WORK"
dsn_for() { printf '%s' "${ADMIN_DSN%/*}/$1"; }

step "Synthetic ledger"
psql_admin "CREATE DATABASE \"$DB\"" >/dev/null || { echo "could not create $DB" >&2; exit 1; }
owned_db=true
db "CREATE TABLE schema_migrations (version TEXT PRIMARY KEY, applied_at TIMESTAMPTZ NOT NULL)"
db "INSERT INTO schema_migrations (version, applied_at) VALUES
      ('657_attachment_upload_session',            '2026-01-01 00:00:00.123456+00'),
      ('658_attachment_upload_session_staging_key','2026-01-02 03:04:05.654321+00'),
      ('659_attachment_upload_session_due',        '2026-01-03 06:07:08.000001+00'),
      ('700_inbox_item_active_shown_idx',          '2026-02-01 12:00:00.000000+00')" >/dev/null
ok "created $DB with 4 ledger rows at microsecond precision"

SNAP="$WORK/snapshot.tsv"
if ledger_ts_snapshot "$DB" "$SNAP"; then
  ok "snapshot taken"
else
  bad "snapshot failed on a healthy ledger"
fi
if [ "$(wc -l <"$SNAP")" = "4" ]; then
  ok "snapshot holds every row (4)"
else
  bad "snapshot holds $(wc -l <"$SNAP") rows, want 4"
fi

step "1. Unchanged ledger must pass"
if ledger_ts_unchanged "$DB" "$SNAP"; then
  ok "an untouched ledger passes"
else
  bad "an untouched ledger was reported as changed"
fi

step "2. Counterexample: a timestamp was rewritten (must fail)"
db "UPDATE schema_migrations SET applied_at = '2027-01-01 00:00:00+00'
     WHERE version = '658_attachment_upload_session_staging_key'" >/dev/null
if ledger_ts_unchanged "$DB" "$SNAP" 2>"$WORK/err1"; then
  bad "a rewritten applied_at passed — the comparison cannot see timestamps"
else
  if grep -q '658_attachment_upload_session_staging_key' "$WORK/err1"; then
    ok "a rewritten applied_at fails and names the row"
  else
    bad "failed without naming the changed row"
  fi
fi
# Restore, so each counterexample starts from the same baseline.
db "UPDATE schema_migrations SET applied_at = '2026-01-02 03:04:05.654321+00'
     WHERE version = '658_attachment_upload_session_staging_key'" >/dev/null

step "3. Counterexample: a sub-microsecond change (must fail)"
# A comparison that renders the timestamp with to_char without %US, or compares
# after truncation, would call this unchanged.
db "UPDATE schema_migrations SET applied_at = '2026-01-02 03:04:05.654322+00'
     WHERE version = '658_attachment_upload_session_staging_key'" >/dev/null
if ledger_ts_unchanged "$DB" "$SNAP" 2>/dev/null; then
  bad "a one-microsecond change passed — the comparison truncates precision"
else
  ok "a one-microsecond change fails"
fi
db "UPDATE schema_migrations SET applied_at = '2026-01-02 03:04:05.654321+00'
     WHERE version = '658_attachment_upload_session_staging_key'" >/dev/null

step "4. Counterexample: a ledger row was deleted (must fail)"
db "DELETE FROM schema_migrations WHERE version = '659_attachment_upload_session_due'" >/dev/null
if ledger_ts_unchanged "$DB" "$SNAP" 2>"$WORK/err2"; then
  bad "a deleted ledger row passed — a join cannot see a missing right-hand row"
else
  if grep -q '659_attachment_upload_session_due' "$WORK/err2"; then
    ok "a deleted ledger row fails and names the row"
  else
    bad "failed without naming the deleted row"
  fi
fi
db "INSERT INTO schema_migrations (version, applied_at)
    VALUES ('659_attachment_upload_session_due', '2026-01-03 06:07:08.000001+00')" >/dev/null

step "5. An ADDED version is legitimate (the upgrade's whole purpose)"
# The mirror image of case 4, and the one my first fix got wrong: an upgrade
# adds ledger rows, so a new version must NOT fail. A check that rejects growth
# fails every real run, which is what happened before this case existed.
db "INSERT INTO schema_migrations (version, applied_at)
    VALUES ('759_task_usage_hourly_rollup_hour_key', '2026-03-01 00:00:00+00')" >/dev/null
if ledger_ts_unchanged "$DB" "$SNAP" 2>"$WORK/err3"; then
  ok "a version the upgrade added does not fail the check"
else
  bad "an added ledger row was reported as a violation: $(cat "$WORK/err3")"
fi
db "DELETE FROM schema_migrations WHERE version = '759_task_usage_hourly_rollup_hour_key'" >/dev/null

step "6. Counterexample: the query itself fails (must fail closed)"
# This is the state the old `2>/dev/null || echo 0` hid: an unreadable ledger
# reported success. Rename the table so the read errors without dropping data.
db "ALTER TABLE schema_migrations RENAME TO schema_migrations_moved" >/dev/null
if ledger_ts_unchanged "$DB" "$SNAP" 2>"$WORK/err4"; then
  bad "a failed query passed — an error must never be reported as 'unchanged'"
else
  ok "an unreadable ledger fails closed"
fi
db "ALTER TABLE schema_migrations_moved RENAME TO schema_migrations" >/dev/null

step "7. Counterexample: the database is unreachable (must fail closed)"
if ledger_ts_unchanged "definitely_not_a_database_$RUN_ID" "$SNAP" 2>/dev/null; then
  bad "an unreachable database passed"
else
  ok "an unreachable database fails closed"
fi

step "8. Counterexample: the snapshot file is empty or missing (must fail closed)"
: >"$WORK/empty.tsv"
if ledger_ts_unchanged "$DB" "$WORK/empty.tsv" 2>/dev/null; then
  bad "an empty snapshot passed"
else
  ok "an empty snapshot fails closed"
fi
if ledger_ts_unchanged "$DB" "$WORK/no-such-file.tsv" 2>/dev/null; then
  bad "a missing snapshot passed"
else
  ok "a missing snapshot fails closed"
fi

step "9. The untouched ledger still passes after every restore"
if ledger_ts_unchanged "$DB" "$SNAP"; then
  ok "restored ledger passes again (the counterexamples did not corrupt the baseline)"
else
  bad "restored ledger fails — an earlier case left a mutation behind"
fi

step "Summary"
printf '    pass: %s   fail: %s\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf 'FAILURES:\n'
  printf '  - %s\n' "${FAILURES[@]}"
  exit 1
fi
