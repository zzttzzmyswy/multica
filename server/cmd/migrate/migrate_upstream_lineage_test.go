package main

import (
	"context"
	"fmt"
	"math/rand/v2"
	"strconv"
	"strings"
	"testing"
	"time"
)

// This distribution released its upload feature as migrations 657-660 and moved
// the whole upstream block up by four (657-696 -> 661-700). A database that
// upstream migrated records DIFFERENT filenames under 657-700: the two lineages
// share numbers but not objects.
//
// Before the preflight guard existed, pointing this build at such a database
// failed only when it reached 665_chat_task_supplement ("relation already
// exists") — after it had already created the upload table and written eight
// ledger rows naming objects the schema did not have. The database was then
// half-upgraded in a way no rerun could repair.
//
// These tests pin the two halves of the contract: a foreign ledger is refused
// before the first statement, and a ledger this distribution wrote is not.
func TestRunMigrationsRefusesUpstreamLineageBeforeAnySideEffect(t *testing.T) {
	t.Parallel()
	admin := openTestPool(t)
	ctx, cancel := context.WithTimeout(t.Context(), 60*time.Second)
	defer cancel()
	schema := createScratchSchema(t, ctx, admin, "upstream_lineage_")
	pool := openTestPoolWithSearchPath(t, schema)

	// The upstream ledger rows for the shared numbers, plus one ordinary shared
	// version, so the guard is shown to key off the lineage strings alone.
	foreign := []string{
		"657_inbox_item_snoozed_until",
		"658_project_archive",
		"659_issue_view_preference_projects_page",
		"660_inbox_item_snoozed_at",
		"665_weixin_state",
		"673_runtime_rate_limit",
	}
	if _, err := pool.Exec(ctx, `CREATE TABLE schema_migrations (
		version TEXT PRIMARY KEY, applied_at TIMESTAMPTZ NOT NULL DEFAULT now()
	)`); err != nil {
		t.Fatal(err)
	}
	for _, version := range foreign {
		if _, err := pool.Exec(ctx, "INSERT INTO schema_migrations (version) VALUES ($1)", version); err != nil {
			t.Fatalf("seed foreign ledger row %s: %v", version, err)
		}
	}

	// An empty database would migrate every file; the guard must stop the run
	// before the first one. 001_init is the first file on disk, so a refusal
	// that leaves it unapplied proves the guard precedes the loop.
	options := runOptions{
		Direction:             "up",
		Files:                 realMigrationFiles(t, []string{"001_init"}, "up"),
		SchemaMigrationsTable: schema + ".schema_migrations",
		AdvisoryLockKey:       int64(rand.Uint64()&0x7fffffffffffffff) | 1,
		Hooks:                 hooksForDirection("up"),
		Conditions:            conditionsForDirection("up"),
	}

	err := runMigrations(ctx, pool, options)
	if err == nil {
		t.Fatal("run succeeded on an upstream-lineage ledger; it must refuse")
	}
	for _, version := range foreign {
		if !strings.Contains(err.Error(), version) {
			t.Errorf("refusal does not name foreign version %s: %v", version, err)
		}
	}
	if !strings.Contains(err.Error(), "upstream migration line") {
		t.Errorf("refusal does not explain the lineage collision: %v", err)
	}

	// No file may have been applied. 001_init creates the first tables, so its
	// presence in the ledger — or in the catalog — proves the runner reached SQL.
	var recorded bool
	if err := pool.QueryRow(ctx, "SELECT EXISTS(SELECT 1 FROM schema_migrations WHERE version = $1)", "001_init").Scan(&recorded); err != nil {
		t.Fatal(err)
	}
	if recorded {
		t.Error("refusal happened after 001_init was recorded; the guard must run before the first migration")
	}
	var initTableExists bool
	if err := pool.QueryRow(ctx, "SELECT to_regclass($1) IS NOT NULL", schema+".workspace").Scan(&initTableExists); err != nil {
		t.Fatal(err)
	}
	if initTableExists {
		t.Error("refusal happened after migration SQL ran; the guard must precede the loop")
	}

	// The ledger itself is untouched: the foreign rows are still exactly the
	// ones that were seeded, with nothing added.
	var ledgerRows int
	if err := pool.QueryRow(ctx, "SELECT count(*) FROM schema_migrations").Scan(&ledgerRows); err != nil {
		t.Fatal(err)
	}
	if ledgerRows != len(foreign) {
		t.Errorf("ledger rows = %d, want %d (the run must not write)", ledgerRows, len(foreign))
	}
}

// A ledger written by this distribution must migrate normally, so the guard
// cannot be satisfied by refusing everything.
func TestRunMigrationsAcceptsOwnLineage(t *testing.T) {
	t.Parallel()
	admin := openTestPool(t)
	ctx, cancel := context.WithTimeout(t.Context(), 60*time.Second)
	defer cancel()
	schema := createScratchSchema(t, ctx, admin, "own_lineage_")
	pool := openTestPoolWithSearchPath(t, schema)

	if _, err := pool.Exec(ctx, `CREATE TABLE schema_migrations (
		version TEXT PRIMARY KEY, applied_at TIMESTAMPTZ NOT NULL DEFAULT now()
	)`); err != nil {
		t.Fatal(err)
	}
	// This distribution's frozen upload set, which is what a deployed .2
	// database holds. No upstream-lineage string is present.
	own := []string{
		"657_attachment_upload_session",
		"658_attachment_upload_session_staging_key",
		"659_attachment_upload_session_due",
		"660_attachment_upload_session_workspace",
	}
	for _, version := range own {
		if _, err := pool.Exec(ctx, "INSERT INTO schema_migrations (version) VALUES ($1)", version); err != nil {
			t.Fatalf("seed own ledger row %s: %v", version, err)
		}
	}

	// Only the guard is under test here: an empty file list reaches the ledger
	// check and returns without touching SQL.
	options := runOptions{
		Direction:             "up",
		SchemaMigrationsTable: schema + ".schema_migrations",
		AdvisoryLockKey:       int64(rand.Uint64()&0x7fffffffffffffff) | 1,
	}
	if err := runMigrations(ctx, pool, options); err != nil {
		t.Fatalf("own-lineage ledger was refused: %v", err)
	}

	refused, err := refusedUpstreamLineage(ctx, pool, schema+".schema_migrations")
	if err != nil {
		t.Fatal(err)
	}
	if len(refused) != 0 {
		t.Errorf("own ledger reported as foreign: %v", refused)
	}
}

// An absent ledger is not evidence of a foreign lineage: a fresh database must
// proceed to create the table and migrate.
func TestRefusedUpstreamLineageAllowsMissingLedger(t *testing.T) {
	t.Parallel()
	admin := openTestPool(t)
	ctx, cancel := context.WithTimeout(t.Context(), 60*time.Second)
	defer cancel()
	schema := createScratchSchema(t, ctx, admin, "missing_ledger_")
	pool := openTestPoolWithSearchPath(t, schema)

	refused, err := refusedUpstreamLineage(ctx, pool, schema+".schema_migrations")
	if err != nil {
		t.Fatalf("missing ledger must not error: %v", err)
	}
	if len(refused) != 0 {
		t.Errorf("missing ledger reported foreign versions: %v", refused)
	}
}

// The guard's map is the whole contract: every upstream filename in the shifted
// block must be listed, or a partially recorded upstream database slips through.
func TestUpstreamLineageVersionsCoverTheShiftedBlock(t *testing.T) {
	t.Parallel()

	if got, want := len(upstreamLineageVersions), 40; got != want {
		t.Fatalf("upstreamLineageVersions has %d entries, want %d (upstream 657-696)", got, want)
	}

	// The map pairs an upstream filename with the fork filename that occupies
	// the SAME number — that collision is what the guard detects. Each pair must
	// therefore be a real collision: same number, different stem, both files
	// present on disk under their own lineage's numbering.
	seenFork := make(map[string]bool, len(upstreamLineageVersions))
	for upstream, fork := range upstreamLineageVersions {
		if seenFork[fork] {
			t.Errorf("fork version %s mapped from more than one upstream version", fork)
		}
		seenFork[fork] = true

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
		if upstream == fork {
			t.Errorf("%s maps to itself; it is not a collision", upstream)
		}

		// The fork file at that number must exist, so the guard names a file this
		// build actually ships.
		realMigrationFiles(t, []string{fork}, "up")

		// And the upstream change must live on in this build under upstream+4,
		// which is the whole point of shifting the block instead of dropping it.
		_, suffix, _ := strings.Cut(upstream, "_")
		shifted := fmt.Sprintf("%d_%s", upstreamNumber+4, suffix)
		realMigrationFiles(t, []string{shifted}, "up")
	}
}

// leadingMigrationNumber parses the numeric prefix of a migration version such
// as "661_chat_task_supplement".
func leadingMigrationNumber(version string) (int, error) {
	prefix, _, ok := strings.Cut(version, "_")
	if !ok {
		return 0, fmt.Errorf("no underscore separator")
	}
	return strconv.Atoi(prefix)
}
