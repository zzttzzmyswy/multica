package main

import (
	"context"
	"fmt"
	"math/rand/v2"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/multica-ai/multica/server/internal/migrations"
)

// This distribution released its upload feature as migrations 657-660 and moved
// the whole upstream block up by four (657-696 -> 661-700). A database that
// upstream migrated records DIFFERENT filenames under 657-700: the two lineages
// share numbers but not objects. A database built from the historical upstream
// CANDIDATE is worse: it records the upload feature at yet another set of
// numbers (660-663), which collide with this build's upstream block.
//
// The first version of the guard listed the 40 upstream filenames and refused
// only those. That let a MIXED ledger through — a legitimate `.2` prefix plus one
// leftover candidate stem — and the run appended 40 migrations on top of it
// (ledger 685 -> 725, tables 148 -> 159). The reviewer caught it. The guard is
// now an allowlist: every version in an existing ledger must be one this build
// ships or a verified historical alias.
//
// These tests pin the contract from both sides: foreign and unknown ledgers are
// refused with no side effect, and every ledger this distribution can legitimately
// produce is accepted.

// ledgerFixture is one scratch schema with a ledger the test seeds itself.
type ledgerFixture struct {
	ctx   context.Context
	pool  *pgxpool.Pool
	table string
	// seeded and seededRelations snapshot the ledger and relation count right
	// before the run under test, so a refusal can be shown to have changed
	// neither.
	seeded          []string
	seededRelations int
}

func newLedgerFixture(t *testing.T, prefix string) *ledgerFixture {
	t.Helper()
	admin := openTestPool(t)
	ctx, cancel := context.WithTimeout(t.Context(), 60*time.Second)
	t.Cleanup(cancel)
	schema := createScratchSchema(t, ctx, admin, prefix)
	pool := openTestPoolWithSearchPath(t, schema)
	if _, err := pool.Exec(ctx, `CREATE TABLE schema_migrations (
		version TEXT PRIMARY KEY, applied_at TIMESTAMPTZ NOT NULL DEFAULT now()
	)`); err != nil {
		t.Fatal(err)
	}
	return &ledgerFixture{ctx: ctx, pool: pool, table: schema + ".schema_migrations"}
}

func (f *ledgerFixture) seed(t *testing.T, versions ...string) {
	t.Helper()
	for _, version := range versions {
		if _, err := f.pool.Exec(f.ctx, "INSERT INTO schema_migrations (version) VALUES ($1)", version); err != nil {
			t.Fatalf("seed ledger row %s: %v", version, err)
		}
	}
}

func (f *ledgerFixture) ledger(t *testing.T) []string {
	t.Helper()
	rows, err := f.pool.Query(f.ctx, "SELECT version FROM schema_migrations ORDER BY version")
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	var out []string
	for rows.Next() {
		var v string
		if err := rows.Scan(&v); err != nil {
			t.Fatal(err)
		}
		out = append(out, v)
	}
	if err := rows.Err(); err != nil {
		t.Fatal(err)
	}
	return out
}

// migratedTableCount counts this schema's relations, so a refusal can be shown
// to have created nothing.
func (f *ledgerFixture) relationCount(t *testing.T) int {
	t.Helper()
	var n int
	if err := f.pool.QueryRow(f.ctx, `
		SELECT count(*) FROM pg_class c
		JOIN pg_namespace n ON n.oid = c.relnamespace
		WHERE n.nspname = current_schema()`).Scan(&n); err != nil {
		t.Fatal(err)
	}
	return n
}

// runOnce applies the given versions' real files through the production code
// path, with the production preflight enabled.
// runOnce drives the production path with the FULL shipped migration set, which
// is what the lineage preflight assumes. These tests are about refusing a bad
// ledger before anything runs, so the files are never applied — passing the whole
// set keeps the preflight enabled rather than opting out via a subset.
func (f *ledgerFixture) runOnce(t *testing.T, _ ...string) error {
	t.Helper()
	files, err := shippedMigrationFiles(t)
	if err != nil {
		t.Fatal(err)
	}
	return runMigrations(f.ctx, f.pool, runOptions{
		Direction:             "up",
		Files:                 files,
		SchemaMigrationsTable: f.table,
		AdvisoryLockKey:       int64(rand.Uint64()&0x7fffffffffffffff) | 1,
		Hooks:                 hooksForDirection("up"),
		Conditions:            conditionsForDirection("up"),
	})
}

// assertRefusedWithNoSideEffect checks the run failed AND changed neither the
// schema nor the ledger. A guard that refuses only after its first statement is
// the bug this covers.
func (f *ledgerFixture) assertRefusedWithNoSideEffect(t *testing.T, err error, wantSubstring string) {
	t.Helper()
	if err == nil {
		t.Fatal("run succeeded; it must refuse this ledger")
	}
	if wantSubstring != "" && !strings.Contains(err.Error(), wantSubstring) {
		t.Errorf("refusal does not mention %q: %v", wantSubstring, err)
	}
	after := f.ledger(t)
	if len(after) != len(f.seeded) {
		t.Errorf("ledger changed: %d rows after refusal, %d seeded (%v)", len(after), len(f.seeded), after)
	}
	for i := range f.seeded {
		if after[i] != f.seeded[i] {
			t.Errorf("ledger row %d = %q, want %q", i, after[i], f.seeded[i])
		}
	}
	if got := f.relationCount(t); got != f.seededRelations {
		t.Errorf("schema changed: %d relations after refusal, %d before", got, f.seededRelations)
	}
}

// TestMixedLedgerIsRefused reproduces the acceptance finding exactly: a database
// at the released `.2` ledger, plus one stem the historical upstream candidate
// used for the same upload feature. The allowlist must refuse it.
//
// The intruder matters because it is a REAL name from this project's history, not
// a random string: it is what an operator who tried the candidate build would
// have left behind. It shares the number 661 with this build's
// 661_inbox_item_snoozed_until while meaning a different object.
func TestMixedLedgerIsRefused(t *testing.T) {
	t.Parallel()
	f := newLedgerFixture(t, "mixed_ledger_")

	// A representative `.2` ledger: the frozen upload set, its predecessors, and
	// one of the historical duplicate-number pairs (020 appears twice in the
	// shipped tree and must stay acceptable).
	f.seed(t,
		"019_inbox_details",
		"020_issue_number",
		"020_task_session",
		"657_attachment_upload_session",
		"658_attachment_upload_session_staging_key",
		"659_attachment_upload_session_due",
		"660_attachment_upload_session_workspace",
	)
	// The historical candidate's name for the staging-key index.
	f.seed(t, "661_attachment_upload_session_staging_key")

	f.seeded = f.ledger(t)
	f.seededRelations = f.relationCount(t)

	err := f.runOnce(t, "001_init", "002_agent_config")
	f.assertRefusedWithNoSideEffect(t, err, "661_attachment_upload_session_staging_key")

	// It is foreign, not merely unknown: the message names the historical
	// candidate so an operator knows which lineage the stray row came from.
	if !strings.Contains(err.Error(), "historical upstream candidate") {
		t.Errorf("refusal should explain the candidate-lineage collision: %v", err)
	}
}

// TestRecordedVersionAheadOfItsPredecessorsIsRefused is the acceptance finding
// for round 2: every name in the ledger is legitimate, but one of them is
// recorded while the migrations before it are not.
//
// Reproduced against a real `v0.9.0-myswy.2` database plus a single added
// `700_inbox_item_active_shown_idx`: two `up` runs exited 0, the ledger reached
// 724 rows, and `idx_inbox_active_shown` was never created — the runner saw 700
// recorded and skipped the only migration that builds it. Name-level checking
// cannot catch this, because 700 IS a version this build ships.
func TestRecordedVersionAheadOfItsPredecessorsIsRefused(t *testing.T) {
	t.Parallel()
	f := newLedgerFixture(t, "ahead_of_prefix_")
	// A plausible prefix: the first shipped versions, then a jump to the last.
	f.seed(t, "001_init", "002_agent_config", "003_task_context")
	f.seed(t, "700_inbox_item_active_shown_idx")
	f.seeded = f.ledger(t)
	f.seededRelations = f.relationCount(t)

	err := f.runOnce(t, "001_init", "002_agent_config", "003_task_context")
	if err == nil {
		t.Fatal("run succeeded with a version recorded ahead of its predecessors; it must refuse")
	}
	// The message names the first gap — the migration that would be skipped —
	// which is more actionable than naming the version recorded too early.
	if !strings.Contains(err.Error(), "004_agent_runtime_loop") {
		t.Errorf("refusal does not name the missing migration: %v", err)
	}
	if !strings.Contains(err.Error(), "contiguous prefix") {
		t.Errorf("refusal does not explain the ordering rule: %v", err)
	}
	f.assertRefusedWithNoSideEffect(t, err, "contiguous prefix")
}

// A hole in the middle of an otherwise complete ledger is refused too — the
// ledger must cover a contiguous prefix, not merely start at the beginning and
// end at the end.
func TestMidLedgerHoleIsRefused(t *testing.T) {
	t.Parallel()
	f := newLedgerFixture(t, "mid_hole_")
	f.seed(t, "001_init", "002_agent_config", "003_task_context")
	// 005 recorded, 004 missing.
	f.seed(t, "005_daemon_pairing")
	f.seeded = f.ledger(t)
	f.seededRelations = f.relationCount(t)

	err := f.runOnce(t, "001_init", "002_agent_config", "003_task_context")
	if err == nil {
		t.Fatal("run succeeded across a hole in the ledger; it must refuse")
	}
	if !strings.Contains(err.Error(), "004_") {
		t.Errorf("refusal does not name the missing migration: %v", err)
	}
	f.assertRefusedWithNoSideEffect(t, err, "004_")
}

// The other half of the historical upload numbering: the candidate's table and
// its two remaining indexes. Each is refused on its own, so no member of that
// set slips through.
func TestEveryHistoricalCandidateUploadStemIsRefused(t *testing.T) {
	t.Parallel()
	// The candidate numbered the upload feature 660-663 (see
	// docs/upload-patch-contract.md). This build numbers it 657-660 and its
	// upstream block 661-700, so all four are foreign names.
	for _, version := range []string{
		"660_attachment_upload_session",
		"661_attachment_upload_session_staging_key",
		"662_attachment_upload_session_due",
		"663_attachment_upload_session_workspace",
	} {
		t.Run(version, func(t *testing.T) {
			t.Parallel()
			f := newLedgerFixture(t, "candidate_stem_")
			f.seed(t, "657_attachment_upload_session")
			f.seed(t, version)
			f.seeded = f.ledger(t)
			f.seededRelations = f.relationCount(t)
			f.assertRefusedWithNoSideEffect(t, f.runOnce(t, "001_init"), version)
		})
	}
}

// An unknown stem, a gap, and a ledger written past the supported range must each
// be refused. The point is that detection does not depend on the name being on
// any list: only shipped versions and verified aliases are allowed.
func TestUnsupportedLedgersAreRefused(t *testing.T) {
	t.Parallel()
	for _, tc := range []struct {
		name    string
		seed    []string
		wantErr string
	}{
		{
			name:    "unknown stem at a shipped number",
			seed:    []string{"657_attachment_upload_session", "661_something_this_build_never_shipped"},
			wantErr: "661_something_this_build_never_shipped",
		},
		{
			name:    "unknown stem past the supported range",
			seed:    []string{"657_attachment_upload_session", "701_a_future_migration"},
			wantErr: "701_a_future_migration",
		},
		{
			name:    "gap-free foreign block",
			seed:    []string{"661_chat_task_supplement", "662_chat_task_supplement_message"},
			wantErr: "661_chat_task_supplement",
		},
		{
			name:    "ledger from another product entirely",
			seed:    []string{"001_create_users", "002_create_posts"},
			wantErr: "001_create_users",
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			f := newLedgerFixture(t, "unsupported_")
			f.seed(t, tc.seed...)
			f.seeded = f.ledger(t)
			f.seededRelations = f.relationCount(t)
			f.assertRefusedWithNoSideEffect(t, f.runOnce(t, "001_init"), tc.wantErr)
		})
	}
}

// A ledger this distribution legitimately produces must migrate. That covers a
// fresh database, the released `.2` set, a partial (interrupted) run, historical
// duplicate numeric prefixes, and a recorded conditional skip.
func TestSupportedLedgersAreAccepted(t *testing.T) {
	t.Parallel()
	for _, tc := range []struct {
		name string
		seed []string
	}{
		{name: "empty database", seed: nil},
		{
			name: "released .2 upload set",
			seed: []string{
				"657_attachment_upload_session",
				"658_attachment_upload_session_staging_key",
				"659_attachment_upload_session_due",
				"660_attachment_upload_session_workspace",
			},
		},
		{
			name: "interrupted run: an ordered prefix of shipped versions",
			seed: []string{"001_init", "002_agent_config", "003_task_context"},
		},
		{
			name: "historical duplicate numeric prefixes stay acceptable",
			seed: []string{"020_issue_number", "020_task_session", "026_comment_reactions", "026_task_messages"},
		},
		{
			name: "a recorded conditional skip is still a shipped version",
			// Upstream conditions skip these on most databases but still record
			// them; see upMigrationConditions.
			seed: []string{"139_issue_description_trgm_index", "140_comment_content_trgm_index", "469_issue_status_lifecycle_categories"},
		},
		{
			name: "verified historical alias",
			seed: []string{"665_runtime_rate_limit"},
		},
		{
			name: "verified historical alias beside its renumbered successor",
			seed: []string{"665_runtime_rate_limit", "677_runtime_rate_limit"},
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			f := newLedgerFixture(t, "supported_")
			f.seed(t, tc.seed...)
			// An empty file list exercises the preflight alone without running
			// DDL against objects the seeded ledger claims exist.
			err := runMigrations(f.ctx, f.pool, runOptions{
				Direction:             "up",
				SchemaMigrationsTable: f.table,
				AdvisoryLockKey:       int64(rand.Uint64()&0x7fffffffffffffff) | 1,
			})
			if err != nil {
				t.Fatalf("supported ledger was refused: %v", err)
			}
		})
	}
}

// A missing ledger is a fresh database: the preflight must not error, and the
// run must create the table and migrate.
func TestMissingLedgerMigrates(t *testing.T) {
	t.Parallel()
	admin := openTestPool(t)
	ctx, cancel := context.WithTimeout(t.Context(), 60*time.Second)
	defer cancel()
	schema := createScratchSchema(t, ctx, admin, "missing_ledger_")
	pool := openTestPoolWithSearchPath(t, schema)

	// The preflight must treat an absent ledger as a fresh database and let the
	// run proceed. Asserting the table gets created is enough; running real DDL
	// here would race other parallel tests on cluster-wide extension creation.
	options := runOptions{
		Direction:             "up",
		SchemaMigrationsTable: schema + ".schema_migrations",
		AdvisoryLockKey:       int64(rand.Uint64()&0x7fffffffffffffff) | 1,
	}
	if err := runMigrations(ctx, pool, options); err != nil {
		t.Fatalf("fresh database was refused: %v", err)
	}
	var tableExists bool
	if err := pool.QueryRow(ctx, "SELECT to_regclass($1) IS NOT NULL", schema+".schema_migrations").Scan(&tableExists); err != nil || !tableExists {
		t.Fatalf("ledger table created=%t, err=%v", tableExists, err)
	}
}

// An interrupted run leaves an ordered prefix of shipped versions recorded and
// the rest pending. Resuming must accept that ledger and apply the remainder —
// the exact case a guard keyed on "is the ledger complete?" would break.
func TestInterruptedRunResumes(t *testing.T) {
	t.Parallel()
	admin := openTestPool(t)
	ctx, cancel := context.WithTimeout(t.Context(), 120*time.Second)
	defer cancel()
	schema := createScratchSchema(t, ctx, admin, "interrupted_resume_")
	pool := openTestPoolWithSearchPath(t, schema)

	prefix := realMigrationFiles(t, []string{"001_init", "002_agent_config", "003_task_context"}, "up")
	options := runOptions{
		Direction:             "up",
		Files:                 prefix,
		SchemaMigrationsTable: schema + ".schema_migrations",
		AdvisoryLockKey:       int64(rand.Uint64()&0x7fffffffffffffff) | 1,
		Hooks:                 hooksForDirection("up"),
		Conditions:            conditionsForDirection("up"),
	}
	if err := runMigrations(ctx, pool, options); err != nil {
		t.Fatalf("initial run: %v", err)
	}

	// Rewind to the moment just before 003 committed: undo its DDL and drop its
	// ledger row. That is what a run killed between "apply SQL" and "record the
	// version" looks like, and what the runner has to recover from.
	down, err := os.ReadFile(filepath.Join("..", "..", "migrations", "003_task_context.down.sql"))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := pool.Exec(ctx, string(down)); err != nil {
		t.Fatalf("rewind 003: %v", err)
	}
	if _, err := pool.Exec(ctx, "DELETE FROM schema_migrations WHERE version = '003_task_context'"); err != nil {
		t.Fatal(err)
	}
	var recorded bool
	if err := pool.QueryRow(ctx, "SELECT EXISTS(SELECT 1 FROM schema_migrations WHERE version = '003_task_context')").Scan(&recorded); err != nil || recorded {
		t.Fatalf("003_task_context recorded before resume=%t, err=%v", recorded, err)
	}

	// The ledger is now a strict prefix of shipped versions.
	options.Files = realMigrationFiles(t, []string{"003_task_context"}, "up")
	if err := runMigrations(ctx, pool, options); err != nil {
		t.Fatalf("resume after interruption was refused: %v", err)
	}
	if err := pool.QueryRow(ctx, "SELECT EXISTS(SELECT 1 FROM schema_migrations WHERE version = '003_task_context')").Scan(&recorded); err != nil || !recorded {
		t.Fatalf("003_task_context recorded after resume=%t, err=%v", recorded, err)
	}
}

// The explanatory upstream map and the alias table are part of the contract: the
// map must describe real number collisions, and every alias must name a version
// this build actually ships at a different number.
func TestLineageTablesMatchTheShippedTree(t *testing.T) {
	t.Parallel()

	if got, want := len(upstreamLineageVersions), 40; got != want {
		t.Fatalf("upstreamLineageVersions has %d entries, want %d (upstream 657-696)", got, want)
	}
	for upstream, fork := range upstreamLineageVersions {
		upstreamNumber, err := leadingMigrationNumber(upstream)
		if err != nil {
			t.Errorf("upstream version %q has no numeric prefix: %v", upstream, err)
			continue
		}
		forkNumber, err := leadingMigrationNumber(fork)
		if err != nil {
			t.Errorf("fork version %q has no numeric prefix: %v", fork, err)
			continue
		}
		if forkNumber != upstreamNumber {
			t.Errorf("%s and %s must share a number to be a collision, got %d and %d",
				upstream, fork, upstreamNumber, forkNumber)
		}
		realMigrationFiles(t, []string{fork}, "up")
		// The upstream change itself must live on in this build, shifted by four.
		_, suffix, _ := strings.Cut(upstream, "_")
		realMigrationFiles(t, []string{fmt.Sprintf("%d_%s", upstreamNumber+4, suffix)}, "up")
	}

	for alias, entry := range historicalLedgerAliases {
		if entry.reason == "" {
			t.Errorf("alias %s has no recorded reason", alias)
		}
		// An alias must NOT be a file this build ships: otherwise it is not an
		// alias but a current version, and listing it would hide a rename bug.
		files, err := shippedMigrationFiles(t)
		if err != nil {
			t.Fatal(err)
		}
		for _, file := range files {
			if strings.HasSuffix(file, "/"+alias+".up.sql") {
				t.Errorf("alias %s is also a shipped migration; it does not need an alias", alias)
			}
		}
		// The renumbered successor must exist, so the entry stays meaningful and
		// cannot be used to admit an arbitrary string.
		realMigrationFiles(t, []string{entry.successor}, "up")
		// The reason must point at the regression test that proves the rename.
		if !strings.Contains(entry.reason, "Test") {
			t.Errorf("alias %s reason does not name its regression test: %q", alias, entry.reason)
		}
	}
}

// shippedMigrationFiles returns every up-migration path this build ships.
func shippedMigrationFiles(t *testing.T) ([]string, error) {
	t.Helper()
	return migrations.Files("up")
}

// leadingMigrationNumber parses the numeric prefix of a migration version such
// as "661_chat_task_supplement".
func leadingMigrationNumber(version string) (int, error) {
	prefix, _, ok := strings.Cut(version, "_")
	if !ok {
		return 0, fmt.Errorf("no underscore separator")
	}
	var n int
	if _, err := fmt.Sscanf(prefix, "%d", &n); err != nil {
		return 0, err
	}
	return n, nil
}
