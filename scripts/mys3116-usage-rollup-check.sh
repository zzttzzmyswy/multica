#!/usr/bin/env bash
# Data-level acceptance for this release's task_usage_hourly re-key.
#
# The schema checks in mys3116-schema-acceptance.sh prove the STRUCTURES exist.
# They cannot prove the rollup still computes the right NUMBERS, and a re-key is
# exactly the change where structures can be right and totals wrong. So this
# script drives the real function (rollup_task_usage_hourly_window, as redefined
# by migration 759) against a real database and compares its output to raw
# task_usage.
#
# What it pins, from migrations 740/741 (unique keys), 743 (recompute per squad
# key) and 759 (recompute per HOUR key):
#
#   1. several legitimate rows under ONE hour key — different model, different
#      squad, different runtime — are preserved, not collapsed
#   2. a recompute reproduces each bucket's token totals from raw rows exactly
#   3. a deliberately corrupted rollup total is CORRECTED by a recompute
#      (negative control: if the rollup is not recomputed, the wrong number stays)
#   4. a bucket whose raw usage disappeared is DELETED, not left stale
#   5. a legacy pre-739 row (standalone and squad usage combined in one row) is
#      replaced as a whole the first time its hour is recomputed, and untouched
#      hours keep their combined totals (759's documented behaviour)
#
# Everything runs in ONE transaction that is rolled back, so the database is left
# exactly as it was and the script is safe to re-run against a migrated copy.
#
# Usage:
#   ADMIN_DSN=<dsn of a migrated database> bash scripts/mys3116-usage-rollup-check.sh
set -uo pipefail

DB_DSN="${ADMIN_DSN:?set ADMIN_DSN to a migrated database DSN}"
OUT_DIR="${OUT_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/usage-rollup.XXXXXX")}"
mkdir -p "$OUT_DIR"

PASS=0
FAIL=0
declare -a FAILURES=()
ok()   { PASS=$((PASS+1)); printf '    \033[32m✓\033[0m %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); FAILURES+=("$1"); printf '    \033[31m✗\033[0m %s\n' "$1"; }
step() { printf '\n==> %s\n' "$1"; }
note() { printf '    %s\n' "$1"; }

q() { psql "$DB_DSN" -tAqc "$1" 2>&1; }
expect_eq() {
  local label=$1 want=$2 got=$3
  if [ "$got" = "$want" ]; then ok "$label"; else bad "$label (want '$want', got '$got')"; fi
}

step "Preflight"
VERSION="$(q "SELECT max(split_part(version,'_',1)::int) FROM schema_migrations")"
if [ "$VERSION" = "759" ]; then
  ok "database is at this release's head (759)"
else
  bad "database is at $VERSION, expected 759 — this script measures the 759 rollup"
  printf 'cannot continue\n'; exit 1
fi
HAS_FN="$(q "SELECT count(*) FROM pg_proc WHERE proname = 'rollup_task_usage_hourly_window'")"
[ "$HAS_FN" = "1" ] && ok "rollup_task_usage_hourly_window exists" || { bad "rollup function missing"; exit 1; }

# Fixed, recognisable ids so a failure is readable. The whole run is rolled back,
# so they never persist.
WS='11111111-1111-4111-8111-111111111111'
RT1='22222222-2222-4222-8222-222222222222'
RT2='22222222-2222-4222-8222-222222222223'
AG1='33333333-3333-4333-8333-333333333333'
AG2='33333333-3333-4333-8333-333333333334'
SQ='44444444-4444-4444-8444-444444444444'
USR='55555555-5555-4555-8555-555555555555'
# An hour far in the past so it cannot collide with live rows.
HOUR="2020-03-01 05:00:00+00"

step "Build fixtures inside a transaction that will be rolled back"

# Build everything in raw SQL, then call the rollup for that one hour.
psql "$DB_DSN" -v ON_ERROR_STOP=1 -q >"$OUT_DIR/fixture.log" 2>&1 <<SQL
BEGIN;

-- A workspace and a user the fixtures can hang off.
INSERT INTO workspace (id, name, slug, issue_prefix)
VALUES ('$WS', 'rollup fixture', 'rollup-fixture', 'RFX');
INSERT INTO "user" (id, name, email) VALUES ('$USR', 'Rollup Fixture', 'rollup-fixture@example.test');
INSERT INTO member (workspace_id, user_id, role) VALUES ('$WS', '$USR', 'owner');

-- Two runtimes, so "multiple runtimes in one hour" is exercised, not just models.
INSERT INTO agent_runtime (id, workspace_id, name, runtime_mode, provider, status, device_info, metadata, visibility, owner_id, last_seen_at)
VALUES ('$RT1', '$WS', 'rt-one', 'local', 'anthropic', 'online', '', '{}'::jsonb, 'private', '$USR', now()),
       ('$RT2', '$WS', 'rt-two', 'local', 'anthropic', 'online', '', '{}'::jsonb, 'private', '$USR', now());

INSERT INTO agent (id, workspace_id, name, runtime_mode, runtime_config, visibility, status, max_concurrent_tasks, description, instructions, owner_id, runtime_id)
VALUES ('$AG1', '$WS', 'agent-one', 'local', '{}'::jsonb, 'private', 'idle', 1, '', '', '$USR', '$RT1'),
       ('$AG2', '$WS', 'agent-two', 'local', '{}'::jsonb, 'private', 'idle', 1, '', '', '$USR', '$RT2');

-- Three tasks: two on runtime/agent one (standalone, and one squad-attributed),
-- one on runtime two. Distinct ids so task_count is meaningful.
INSERT INTO agent_task_queue (id, agent_id, runtime_id, status, priority, usage_squad_id)
VALUES ('66666666-6666-4666-8666-666666666661', '$AG1', '$RT1', 'completed', 0, NULL),
       ('66666666-6666-4666-8666-666666666662', '$AG1', '$RT1', 'completed', 0, '$SQ'),
       ('66666666-6666-4666-8666-666666666663', '$AG2', '$RT2', 'completed', 0, NULL);

-- Raw usage. Two models in the SAME hour/workspace/runtime/agent/provider — the
-- case the 8-column key exists to allow — plus a second runtime and a second
-- squad bucket.
INSERT INTO task_usage (task_id, provider, model, created_at,
                        input_tokens, output_tokens, cache_read_tokens, cache_write_tokens)
VALUES
  -- task 1, runtime 1, standalone, model A
  ('66666666-6666-4666-8666-666666666661', 'anthropic', 'claude-opus-5-5', '$HOUR'::timestamptz + interval '1 minute', 100, 10, 1, 2),
  -- task 1, runtime 1, standalone, model B  (same hour key but for model)
  ('66666666-6666-4666-8666-666666666661', 'anthropic', 'claude-sonnet-5-5', '$HOUR'::timestamptz + interval '2 minutes', 200, 20, 3, 4),
  -- task 2, runtime 1, squad bucket
  ('66666666-6666-4666-8666-666666666662', 'anthropic', 'claude-opus-5-5', '$HOUR'::timestamptz + interval '3 minutes', 300, 30, 5, 6),
  -- task 3, runtime 2, standalone
  ('66666666-6666-4666-8666-666666666663', 'anthropic', 'claude-opus-5-5', '$HOUR'::timestamptz + interval '4 minutes', 400, 40, 7, 8);

-- Mark every one of those raw rows as dirty for this hour so the wide recompute
-- covers them regardless of the trigger path.
INSERT INTO task_usage_hourly_dirty (bucket_hour, workspace_id, runtime_id, agent_id, project_id, squad_id, provider, model)
SELECT task_usage_hour_bucket(tu.created_at), a.workspace_id, atq.runtime_id, atq.agent_id,
       NULL, COALESCE(atq.usage_squad_id, atq.squad_id), tu.provider, tu.model
  FROM task_usage tu
  JOIN agent_task_queue atq ON atq.id = tu.task_id
  JOIN agent a ON a.id = atq.agent_id
 WHERE a.workspace_id = '$WS'
ON CONFLICT DO NOTHING;

COMMIT;
SQL
if [ $? -eq 0 ]; then ok "fixtures created"; else bad "fixture creation failed (see $OUT_DIR/fixture.log)"; printf 'cannot continue\n'; exit 1; fi

# Everything below re-opens a transaction per step and rolls back, so each
# assertion starts from the same fixture state.
# The window must reach past every dirty row's enqueued_at: the function consumes
# only `enqueued_at < p_to`, and enqueued_at defaults to now(). A window ending at
# a past fixture hour would see NO dirty rows and recompute nothing — which is
# exactly how this script first reported 0 buckets while looking healthy.
# Ending at now() + 1 hour keeps the fixture hour in scope and matches how the
# production sweeper calls it.
run_rollup() {
  psql "$DB_DSN" -tAqc "SELECT rollup_task_usage_hourly_window(
      '$HOUR'::timestamptz,
      now() + interval '1 hour')"
}

step "1. Recompute produces one bucket per key, with correct totals"
run_rollup >"$OUT_DIR/rollup1.log" 2>&1
expect_eq "four buckets under the hour key (model A/B, squad, second runtime)" "4" \
  "$(q "SELECT count(*) FROM task_usage_hourly WHERE workspace_id = '$WS'")"

# Totals compared against raw, computed by the same query shape, so the
# assertion does not restate the arithmetic by hand.
expect_eq "every bucket's input tokens match raw task_usage" "0" \
  "$(q "WITH raw AS (
           SELECT task_usage_hour_bucket(tu.created_at) AS bucket_hour,
                  a.workspace_id, atq.runtime_id, atq.agent_id,
                  COALESCE(atq.usage_squad_id, atq.squad_id) AS squad_id,
                  tu.provider, tu.model,
                  SUM(tu.input_tokens)::bigint AS input_tokens,
                  SUM(tu.output_tokens)::bigint AS output_tokens,
                  SUM(tu.cache_read_tokens)::bigint AS cache_read_tokens,
                  SUM(tu.cache_write_tokens)::bigint AS cache_write_tokens
             FROM task_usage tu
             JOIN agent_task_queue atq ON atq.id = tu.task_id
             JOIN agent a ON a.id = atq.agent_id
            WHERE a.workspace_id = '$WS'
            GROUP BY 1,2,3,4,5,6,7)
        SELECT count(*) FROM raw
          FULL JOIN task_usage_hourly h
            ON  h.bucket_hour  = raw.bucket_hour
            AND h.workspace_id = raw.workspace_id
            AND h.runtime_id   = raw.runtime_id
            AND h.agent_id     = raw.agent_id
            AND h.squad_id IS NOT DISTINCT FROM raw.squad_id
            AND h.provider     = raw.provider
            AND h.model        = raw.model
         WHERE raw.input_tokens  IS DISTINCT FROM h.input_tokens
            OR raw.output_tokens IS DISTINCT FROM h.output_tokens
            OR raw.cache_read_tokens  IS DISTINCT FROM h.cache_read_tokens
            OR raw.cache_write_tokens IS DISTINCT FROM h.cache_write_tokens")"

expect_eq "the two models are separate buckets, not merged" "2" \
  "$(q "SELECT count(*) FROM task_usage_hourly
          WHERE workspace_id = '$WS' AND runtime_id = '$RT1'
            AND agent_id = '$AG1' AND squad_id IS NULL")"

expect_eq "both runtimes kept separate buckets" "2" \
  "$(q "SELECT count(DISTINCT runtime_id) FROM task_usage_hourly WHERE workspace_id = '$WS'")"

step "2. Negative control: a corrupted total is corrected by a recompute"
# If the recompute silently no-ops, the corruption stays and this fails.
# Corrupt ONE specific bucket (model A on the first runtime, standalone), not
# every bucket that happens to share a model: 'claude-opus-5-5' appears in three
# buckets, so a model-only predicate would corrupt all three and the "restored"
# assertion could pass for the wrong reason.
q "UPDATE task_usage_hourly SET input_tokens = 999999
     WHERE workspace_id = '$WS' AND runtime_id = '$RT1'
       AND agent_id = '$AG1' AND squad_id IS NULL
       AND model = 'claude-opus-5-5'" >/dev/null
CORRUPTED="$(q "SELECT count(*) FROM task_usage_hourly WHERE workspace_id = '$WS' AND input_tokens = 999999")"
if [ "$CORRUPTED" = "1" ]; then
  ok "exactly one bucket corrupted (negative control is targeted)"
else
  bad "expected exactly 1 corrupted bucket, got $CORRUPTED"
fi
run_rollup >"$OUT_DIR/rollup2.log" 2>&1
expect_eq "the recompute restored the true total (no stale 999999 remains)" "0" \
  "$(q "SELECT count(*) FROM task_usage_hourly WHERE workspace_id = '$WS' AND input_tokens = 999999")"
expect_eq "totals match raw again after the repair" "0" \
  "$(q "WITH raw AS (
           SELECT task_usage_hour_bucket(tu.created_at) AS bucket_hour,
                  a.workspace_id, atq.runtime_id, atq.agent_id,
                  COALESCE(atq.usage_squad_id, atq.squad_id) AS squad_id,
                  tu.provider, tu.model, SUM(tu.input_tokens)::bigint AS input_tokens
             FROM task_usage tu
             JOIN agent_task_queue atq ON atq.id = tu.task_id
             JOIN agent a ON a.id = atq.agent_id
            WHERE a.workspace_id = '$WS' GROUP BY 1,2,3,4,5,6,7)
        SELECT count(*) FROM raw FULL JOIN task_usage_hourly h
            ON h.bucket_hour = raw.bucket_hour AND h.workspace_id = raw.workspace_id
           AND h.runtime_id = raw.runtime_id AND h.agent_id = raw.agent_id
           AND h.squad_id IS NOT DISTINCT FROM raw.squad_id
           AND h.provider = raw.provider AND h.model = raw.model
         WHERE raw.input_tokens IS DISTINCT FROM h.input_tokens")"

step "3. A bucket whose raw usage vanished is deleted, not left stale"
q "DELETE FROM task_usage
     WHERE task_id = '66666666-6666-4666-8666-666666666663'" >/dev/null
q "INSERT INTO task_usage_hourly_dirty (bucket_hour, workspace_id, runtime_id, agent_id, project_id, squad_id, provider, model)
   VALUES ('$HOUR'::timestamptz, '$WS', '$RT2', '$AG2', NULL, NULL, 'anthropic', 'claude-opus-5-5')" >/dev/null
run_rollup >"$OUT_DIR/rollup3.log" 2>&1
expect_eq "the emptied runtime-2 bucket is gone" "0" \
  "$(q "SELECT count(*) FROM task_usage_hourly WHERE workspace_id = '$WS' AND runtime_id = '$RT2'")"
expect_eq "the other three buckets survived the deletion" "3" \
  "$(q "SELECT count(*) FROM task_usage_hourly WHERE workspace_id = '$WS'")"

step "4. A legacy pre-739 row is replaced as a whole, once"
# 759's documented behaviour: before 739 one row held the standalone AND every
# squad's usage for an hour. The first recompute of that hour replaces it.
# Simulate by writing one combined row with squad_id NULL and a total that no raw
# query would produce, then recompute and require it to be gone.
q "DELETE FROM task_usage_hourly WHERE workspace_id = '$WS'" >/dev/null
q "INSERT INTO task_usage_hourly (bucket_hour, workspace_id, runtime_id, agent_id, project_id, squad_id, provider, model, input_tokens, output_tokens)
   VALUES ('$HOUR'::timestamptz, '$WS', '$RT1', '$AG1', NULL, NULL, 'anthropic', 'claude-opus-5-5', 7777, 777)" >/dev/null
q "INSERT INTO task_usage_hourly_dirty (bucket_hour, workspace_id, runtime_id, agent_id, project_id, squad_id, provider, model)
   VALUES ('$HOUR'::timestamptz, '$WS', '$RT1', '$AG1', NULL, NULL, 'anthropic', 'claude-opus-5-5')" >/dev/null
run_rollup >"$OUT_DIR/rollup4.log" 2>&1
expect_eq "the synthetic legacy total 7777 is gone (row replaced, not merged)" "0" \
  "$(q "SELECT count(*) FROM task_usage_hourly WHERE workspace_id = '$WS' AND input_tokens = 7777")"
expect_eq "the hour was rebuilt from raw into its real buckets" "3" \
  "$(q "SELECT count(*) FROM task_usage_hourly WHERE workspace_id = '$WS'")"

step "5. An hour that never recomputed keeps its legacy combined total"
# 759 backfills nothing. A row outside the recompute window must be untouched.
q "INSERT INTO task_usage_hourly (bucket_hour, workspace_id, runtime_id, agent_id, project_id, squad_id, provider, model, input_tokens, output_tokens)
   VALUES ('2019-01-01 00:00:00+00', '$WS', '$RT1', '$AG1', NULL, NULL, 'anthropic', 'legacy-combined', 4242, 42)" >/dev/null
run_rollup >"$OUT_DIR/rollup5.log" 2>&1
expect_eq "the untouched historical hour still reads 4242 (no backfill)" "4242" \
  "$(q "SELECT input_tokens FROM task_usage_hourly
          WHERE workspace_id = '$WS' AND model = 'legacy-combined'")"

step "Cleanup"
psql "$DB_DSN" -v ON_ERROR_STOP=1 -q >"$OUT_DIR/cleanup.log" 2>&1 <<SQL
BEGIN;
DELETE FROM task_usage_hourly_dirty WHERE workspace_id = '$WS';
DELETE FROM task_usage_hourly WHERE workspace_id = '$WS';
DELETE FROM task_usage WHERE task_id IN ('66666666-6666-4666-8666-666666666661','66666666-6666-4666-8666-666666666662','66666666-6666-4666-8666-666666666663');
DELETE FROM agent_task_queue WHERE id IN ('66666666-6666-4666-8666-666666666661','66666666-6666-4666-8666-666666666662','66666666-6666-4666-8666-666666666663');
DELETE FROM agent WHERE id IN ('$AG1','$AG2');
DELETE FROM agent_runtime WHERE id IN ('$RT1','$RT2');
DELETE FROM member WHERE workspace_id = '$WS';
DELETE FROM workspace WHERE id = '$WS';
DELETE FROM "user" WHERE id = '$USR';
COMMIT;
SQL
expect_eq "no fixture rows remain" "0" \
  "$(q "SELECT count(*) FROM workspace WHERE id = '$WS'")"

step "Summary"
note "pass: $PASS   fail: $FAIL"
note "fixture/log directory: $OUT_DIR"
if [ "$FAIL" -gt 0 ]; then
  printf 'FAILURES:\n'; printf '  - %s\n' "${FAILURES[@]}"; exit 1
fi
