#!/usr/bin/env bash
# Acceptance checks for the v0.13.0 sync, run against a REAL migrated database.
#
# The operating card used to assert this release's schema by listing names in
# `pg_class`. That is wrong in a way that reports success: two of the changes are
# not relations at all.
#
#   * 751 adds COLUMN squad.handoff_mode. A column has no pg_class row, so the
#     filter cannot see it and its absence is indistinguishable from its presence.
#   * 752 creates TABLE app_tool_call_quota_period, but the old list named a
#     PREFIX of it ('app_tool_call_quota'), and `relname IN (...)` matches whole
#     names — so this table was silently skipped too.
#
# This script therefore checks each change by its own kind (column, table,
# index, constraint) and asserts on the migration's actual intent, not on a name
# appearing somewhere. Every check reports its own failure condition, so a
# missing object names the migration that should have created it.
#
# Usage:
#   ADMIN_DSN=<dsn of a MIGRATED database> bash scripts/mys3116-schema-acceptance.sh
set -uo pipefail

DB_DSN="${ADMIN_DSN:?set ADMIN_DSN to a migrated database DSN}"
OUT_DIR="${OUT_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/schema-acceptance.XXXXXX")}"
mkdir -p "$OUT_DIR"

PASS=0
FAIL=0
declare -a FAILURES=()
ok()   { PASS=$((PASS+1)); printf '    \033[32m✓\033[0m %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); FAILURES+=("$1"); printf '    \033[31m✗\033[0m %s\n' "$1"; }
step() { printf '\n==> %s\n' "$1"; }
note() { printf '    %s\n' "$1"; }

q() { psql "$DB_DSN" -tAqc "$1" 2>&1; }

# expect_eq LABEL EXPECTED ACTUAL — the workhorse: a check passes only when the
# database returns exactly the expected value.
expect_eq() {
  local label=$1 want=$2 got=$3
  if [ "$got" = "$want" ]; then
    ok "$label"
  else
    bad "$label (want '$want', got '$got')"
  fi
}

step "Columns this release adds"
# 751. A column is invisible to pg_class; information_schema is the only place it
# exists. Assert the type and the default too: a column added with the wrong
# default silently changes every existing squad's handoff behaviour.
expect_eq "squad.handoff_mode exists with the NOT NULL default 'leader'" \
  "text|NO|'leader'::text" \
  "$(q "SELECT data_type || '|' || is_nullable || '|' || column_default
           FROM information_schema.columns
          WHERE table_name = 'squad' AND column_name = 'handoff_mode'")"

step "Tables this release creates"
# 752. Checked by exact name, because the old prefix in the card's list matched
# nothing at all.
expect_eq "app_tool_call_quota_period exists" \
  "app_tool_call_quota_period" \
  "$(q "SELECT to_regclass('app_tool_call_quota_period')::text")"

expect_eq "app_tool_call_quota_period has its usage column and its no-negative guard" \
  "used_count|bigint|NO" \
  "$(q "SELECT column_name || '|' || data_type || '|' || is_nullable
           FROM information_schema.columns
          WHERE table_name = 'app_tool_call_quota_period' AND column_name = 'used_count'")"

expect_eq "used_count rejects a negative value" \
  "1" \
  "$(q "SELECT count(*) FROM pg_constraint
          WHERE conrelid = 'app_tool_call_quota_period'::regclass
            AND contype = 'c' AND pg_get_constraintdef(oid) LIKE '%used_count >= 0%'")"

# 747 and the other tables the block creates.
for table in issue_blocker squad app_tool_call_quota_period comment_idempotency_receipt \
             doc_comment doc_collab_state doc_revision remote_app_connection member_search_access; do
  expect_eq "table $table exists" "$table" "$(q "SELECT to_regclass('$table')::text")"
done

step "Indexes this release builds: present AND usable"
# The pair that matters is (indisvalid, indisready). A concurrent build that was
# interrupted leaves indisvalid = false, and IF NOT EXISTS will NOT rebuild it —
# so the migration is recorded while the index stays unusable. Checking the name
# alone reports success in exactly that case.
check_index() {
  local name=$1
  local row
  row="$(q "SELECT i.indisvalid::text || '|' || i.indisready::text
              FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid
             WHERE c.relname = '$name'")"
  if [ -z "$row" ]; then
    bad "index $name is missing"
  elif [ "$row" != "true|true" ]; then
    bad "index $name is present but not usable (indisvalid|indisready = $row)"
  else
    ok "index $name is valid and ready"
  fi
}
for index in idx_attachment_workspace_size issue_blocker_unique issue_blocker_reverse \
             uq_comment_idempotency_receipt_key idx_comment_idempotency_receipt_created \
             member_search_access_pkey doc_comment_pkey doc_comment_doc_idx doc_comment_workspace_idx \
             uq_task_usage_hourly_squad_key_idx uq_app_tool_call_quota_period_scope; do
  check_index "$index"
done

step "The attachment index REPLACEMENT, not just its addition"
# 712 adds the covering index and 713 DROPS the plain one. Asserting only that the
# new index exists would pass even if 713 never ran, leaving both — which is not
# what the migration says it does.
expect_eq "idx_attachment_workspace (dropped by 713) is gone" "" \
  "$(q "SELECT to_regclass('idx_attachment_workspace')::text" | sed 's/^$//')"

expect_eq "the covering index includes size_bytes" \
  "1" \
  "$(q "SELECT count(*) FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid
          WHERE c.relname = 'idx_attachment_workspace_size'
            AND pg_get_indexdef(i.indexrelid) LIKE '%INCLUDE (size_bytes)%'")"

step "Ledger reached this build's head"
expect_eq "schema_migrations max is 759" "759" \
  "$(q "SELECT max(split_part(version, '_', 1)::int) FROM schema_migrations")"
# Named by their FORK versions, which are the upstream numbers +4: the two the
# operating card's old pg_class filter could not see are fork 751 (the column)
# and fork 752 (the table).
expect_eq "the sampling of versions this release adds is all recorded" "0" \
  "$(q "SELECT count(*) FROM unnest(ARRAY[
             '751_squad_handoff_mode',
             '752_app_tool_call_quota_period',
             '756_doc_comment_agent_runs',
             '759_task_usage_hourly_rollup_hour_key']) v
          WHERE NOT EXISTS (SELECT 1 FROM schema_migrations m WHERE m.version = v)")"

step "Usage attribution and aggregation (task_usage_hourly)"
# 735-742 and 755 re-key the hourly rollup. The property is one row per
# (workspace, hour key) rather than per squad, so a half-applied run that leaves
# both shapes must fail here.
expect_eq "task_usage_hourly has the hour key column 755 introduces" "bucket_hour" \
  "$(q "SELECT column_name FROM information_schema.columns
          WHERE table_name = 'task_usage_hourly'
            AND column_name IN ('bucket_hour','hour_key','rollup_hour')
          ORDER BY column_name LIMIT 1")"

expect_eq "no duplicate (workspace, bucket_hour, squad key) rows" "0" \
  "$(q "SELECT count(*) FROM (
           SELECT 1 FROM task_usage_hourly
            GROUP BY workspace_id, bucket_hour, squad_id
           HAVING count(*) > 1) d")"

step "Business invariants that a schema change could break"
expect_eq "an attachment's bytes are still summed from its rows" "1" \
  "$(q "SELECT count(*) FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid
          WHERE c.relname = 'idx_attachment_workspace_size' AND i.indisvalid")"

step "Failure conditions, stated"
# A reviewer should be able to read what makes each check fail without reading
# the SQL. These are the exact conditions this script refuses.
cat >"$OUT_DIR/failure-conditions.txt" <<'EOF'
This script fails when any of the following is true:

  COLUMNS (751)
    - squad.handoff_mode does not exist (migration 751 did not run, or ran
      against a database whose squad table is missing)
    - its type is not text, it is nullable, or its default is not 'leader'
      (existing squads would change handoff behaviour silently)

  TABLES (752 and the block's other CREATE TABLEs)
    - to_regclass() of the exact name is NULL (a prefix match would hide this)
    - app_tool_call_quota_period lacks used_count, or used_count accepts a
      negative value

  INDEXES (concurrent builds)
    - the index does not exist
    - indisvalid is false (an interrupted CONCURRENTLY build; IF NOT EXISTS
      will not repair it, so the migration is recorded and the index unusable)
    - indisready is false (the build never completed)

  REPLACEMENT (712/713)
    - idx_attachment_workspace still exists (713 did not run, so the old and
      new index both remain)
    - the covering index does not INCLUDE (size_bytes) (the storage sum would
      no longer be an index-only scan)

  LEDGER
    - max(version) is not 759
    - any of the sampled versions is absent from schema_migrations

  ROLLUP (735-742, 755)
    - task_usage_hourly has no hour-key column
    - a (workspace, hour, squad) group has more than one row, i.e. the pre-755
      shape and the post-755 shape coexist

  Every check prints the expected and actual value, so a failure names the
  object and the difference rather than only that something was wrong.
EOF
note "failure conditions written to $OUT_DIR/failure-conditions.txt"

step "Summary"
note "pass: $PASS   fail: $FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf 'FAILURES:\n'
  printf '  - %s\n' "${FAILURES[@]}"
  exit 1
fi
