package main

import (
	"fmt"
	"path/filepath"
	"sort"
	"strings"
	"testing"

	"github.com/multica-ai/multica/server/internal/migrations"
)

// This distribution renumbers every upstream migration block before it ships:
// the upload feature owns 657-660 permanently, so upstream's 657-696 entered as
// 661-700 and the next block — upstream's 697-755 — entered as 701-759. Two
// things go wrong silently when a sync gets that shift wrong, and neither shows
// up in an ordinary test run:
//
//  1. A file kept at its OLD number. `migrate up` sorts by filename, so the
//     migration applies at the wrong position, and a database that already ran
//     the previous release takes a different path from a fresh install.
//  2. A second file at a number this build already owns. Sorting ties break
//     arbitrarily and schema_migrations records one version per file, so the
//     ledger can no longer be replayed.
//
// Neither needs a database to detect. These tests pin the shipped tree against
// both, plus the upstream-lineage map the refusal message depends on.

const (
	// firstShiftedUpstreamNumber is the lowest upstream number this fork
	// renumbers: upstream's own 657 onward collides with the upload feature.
	firstShiftedUpstreamNumber = 657
	// latestUpstreamNumber is the highest upstream number in the block this
	// build ships; upstream 697-755 became fork 701-759.
	latestUpstreamNumber = 755
	// latestUpstreamShift is the offset applied to that block.
	latestUpstreamShift = 4
	// latestForkHead is the highest version this build ships.
	latestForkHead = 759
)

// migrationStems returns every shipped migration stem keyed by numeric prefix,
// failing on a duplicate above 128 — the state that makes the ledger
// unreplayable. Prefixes through 128 carry historical duplicates that shipped
// that way; migrations_lint_test.go draws the same line.
func migrationStems(t *testing.T) map[int]string {
	t.Helper()
	files, err := shippedMigrationFiles(t)
	if err != nil {
		t.Fatal(err)
	}
	stems := make(map[int]string, len(files))
	for _, file := range files {
		stem := migrations.ExtractVersion(file)
		number, err := leadingMigrationNumber(stem)
		if err != nil {
			t.Fatalf("%s: %v", stem, err)
		}
		existing, ok := stems[number]
		if !ok {
			stems[number] = stem
			continue
		}
		if number < 129 {
			continue
		}
		t.Errorf("two migrations share the numeric prefix %d: %s and %s — the runner sorts by filename, so one applies at the wrong position and schema_migrations cannot record both", number, existing, stem)
	}
	return stems
}

// TestEveryRenumberedUpstreamMigrationHasALineageEntry checks the lineage map
// from the shipped tree instead of from the map itself. TestLineageTablesMatch
// TheShippedTree starts at the map, so a shifted migration it forgot passes
// there; here it fails.
//
// Every distinct number from 657 to the head is a renumbered upstream migration
// (657-660 are the upload feature's own, 661-700 the first sync, 701-759 this
// one), so every one of them must be listed: only a listed entry lets the
// preflight explain a foreign ledger instead of refusing it generically.
func TestEveryRenumberedUpstreamMigrationHasALineageEntry(t *testing.T) {
	t.Parallel()

	stems := migrationStems(t)
	// The map is keyed by the UPSTREAM filename, because that is what a foreign
	// ledger contains; the value is this build's version at the same number.
	listed := make(map[string]bool, len(upstreamLineageVersions))
	for upstream, fork := range upstreamLineageVersions {
		listed[fork] = true
		number, err := leadingMigrationNumber(fork)
		if err != nil {
			t.Errorf("upstreamLineageVersions value %q: %v", fork, err)
			continue
		}
		if number > latestForkHead {
			t.Errorf("upstreamLineageVersions maps %q to %q, above this build's head %d", upstream, fork, latestForkHead)
		}
	}

	// The range stops at the last number the upstream line also fills. Above it
	// (756-759 here) this build ships files upstream never published, so a
	// foreign ledger cannot hold that number at all and no explanation exists to
	// give.
	for number := firstShiftedUpstreamNumber; number <= latestUpstreamNumber; number++ {
		stem, ok := stems[number]
		if !ok {
			t.Errorf("no migration ships at %d, but the renumbered range is contiguous through %d", number, latestUpstreamNumber)
			continue
		}
		if !listed[stem] {
			t.Errorf("%s has no upstreamLineageVersions entry; an operator whose schema_migrations came from the upstream line would get a generic refusal instead of the explanation", stem)
		}
	}
	// And the head itself must be reachable, so a truncated block fails here
	// rather than silently shrinking the range above.
	if _, ok := stems[latestForkHead]; !ok {
		t.Errorf("no migration ships at the head %d", latestForkHead)
	}
}

// TestLatestUpstreamBlockSuffixesMatchTheFrozenList is the naming half of the
// renumber check: shifting a block moves the PREFIX only, so the suffix at each
// number must be the upstream change that belongs there. A wrong suffix means
// the wrong upstream file was renamed, or a file was renamed to something that
// is not the change it claims to be — either way the migration a fresh install
// applies is not the one the release review saw.
//
// It compares NAMES, not contents: the bodies come from upstream byte-for-byte
// and TestRenumberedMigrationsKeepUpstreamBodies covers them.
//
// A future sync replaces this list wholesale. Leaving it in place is what makes
// a missed or swapped file fail here instead of in production.
func TestLatestUpstreamBlockSuffixesMatchTheFrozenList(t *testing.T) {
	t.Parallel()

	stems := migrationStems(t)
	want := map[int]string{
		701: "autopilot_run_idempotency_key",
		702: "autopilot_run_idempotency_key_idx",
		703: "member_guest_role",
		704: "member_search_access",
		705: "member_search_access_pkey_index",
		706: "member_search_access_pkey",
		707: "doc_comment",
		708: "doc_comment_pkey_index",
		709: "doc_comment_pkey",
		710: "doc_comment_doc_idx",
		711: "doc_comment_workspace_idx",
		712: "attachment_workspace_size_idx",
		713: "drop_attachment_workspace_index",
		714: "autopilot_quota_limit_notice",
		715: "dashboard_range_view",
		716: "dashboard_range_view_scope_idx",
		717: "doc_collab",
		718: "doc_collab_state_pkey_index",
		719: "doc_collab_state_pkey",
		720: "doc_revision_pkey_index",
		721: "doc_revision_pkey",
		722: "auto_archive_prompt",
		723: "remote_app_connection",
		724: "remote_app_oauth_client_idx",
		725: "remote_app_connection_owner_idx",
		726: "auto_archive_agent_trigger_prompt",
		727: "issue_description_collab",
		728: "issue_description_collab_state_pkey_index",
		729: "issue_description_collab_state_pkey",
		730: "issue_description_revision_pkey_index",
		731: "issue_description_revision_pkey",
		732: "app_account_requests",
		733: "remote_app_connection_workspace_idx",
		734: "drop_remote_app_connection_owner_idx",
		735: "skill_revision",
		736: "comment_idempotency_receipt",
		737: "comment_idempotency_receipt_key",
		738: "comment_idempotency_receipt_created",
		739: "task_usage_hourly_squad_col",
		740: "task_usage_hourly_squad_uq_idx",
		741: "task_usage_hourly_dirty_squad_uq_idx",
		742: "task_usage_hourly_workspace_squad_idx",
		743: "task_usage_hourly_squad_pipeline",
		744: "task_usage_hourly_drop_legacy_key",
		745: "task_usage_hourly_dirty_drop_legacy_key",
		746: "task_usage_hourly_squad_rollback_merge",
		747: "issue_blocker",
		748: "issue_blocker_unique",
		749: "issue_blocker_reverse",
		750: "issue_blocker_rules",
		751: "squad_handoff_mode",
		752: "app_tool_call_quota_period",
		753: "app_tool_call_quota_period_scope_idx",
		754: "app_tool_call_quota_columns",
		755: "app_tool_call_workspace_metered_idx",
		756: "doc_comment_agent_runs",
		757: "agent_task_queue_doc_idx",
		758: "issue_stage_blockers_skip_top_level",
		759: "task_usage_hourly_rollup_hour_key",
	}
	numbers := make([]int, 0, len(want))
	for number := range want {
		numbers = append(numbers, number)
	}
	sort.Ints(numbers)
	for _, number := range numbers {
		expected := fmt.Sprintf("%d_%s", number, want[number])
		if got := stems[number]; got != expected {
			t.Errorf("migration %d is %q, want %q", number, got, expected)
		}
	}
}

// TestFirstSyncBlockAndFrozenUploadNumbersAreUnchanged covers the block the
// previous release shipped. Renumbering is cumulative, and these names are
// already recorded in deployed ledgers: shifting one now would either re-run or
// skip an applied migration on a live database.
func TestFirstSyncBlockAndFrozenUploadNumbersAreUnchanged(t *testing.T) {
	t.Parallel()

	stems := migrationStems(t)
	// The upload feature's block, exactly as the release that shipped it named
	// it. 657-660 are frozen on every deployed database.
	for number, suffix := range map[int]string{
		657: "attachment_upload_session",
		658: "attachment_upload_session_staging_key",
		659: "attachment_upload_session_due",
		660: "attachment_upload_session_workspace",
	} {
		expected := fmt.Sprintf("%d_%s", number, suffix)
		if got := stems[number]; got != expected {
			t.Errorf("frozen upload migration %d is %q, want %q; deployed ledgers recorded the original name", number, got, expected)
		}
	}
	// Upstream 657-696 shipped here as 661-700. Counting them catches a block
	// that lost or gained a file during the sync without failing a name check.
	const firstSyncCount = 696 - 657 + 1
	present := 0
	for number := 661; number <= 700; number++ {
		if _, ok := stems[number]; ok {
			present++
		}
	}
	if present != firstSyncCount {
		t.Errorf("the first synced block has %d migrations at 661-700, want %d", present, firstSyncCount)
	}
}

// TestRenumberedMigrationsHaveMatchingDirections pins the structural invariant
// the runner relies on for the block this sync added: each version ships exactly
// one .up.sql and one .down.sql. A rename that touched only one direction leaves
// `migrate down` unable to undo the version it just applied.
func TestRenumberedMigrationsHaveMatchingDirections(t *testing.T) {
	t.Parallel()

	dir, err := migrations.ResolveDir()
	if err != nil {
		t.Fatal(err)
	}
	for number := latestUpstreamNumber + latestUpstreamShift + 1; number <= latestForkHead; number++ {
		paths, err := filepath.Glob(filepath.Join(dir, fmt.Sprintf("%03d_*.sql", number)))
		if err != nil {
			t.Fatal(err)
		}
		var up, down int
		for _, path := range paths {
			switch {
			case strings.HasSuffix(path, ".up.sql"):
				up++
			case strings.HasSuffix(path, ".down.sql"):
				down++
			}
		}
		if up != 1 || down != 1 {
			t.Errorf("migration %d has %d up and %d down file(s), want exactly one of each: %v", number, up, down, paths)
		}
	}
}
