# Upload patch contract

The rules for carrying the direct-upload feature on top of upstream. Read this
before syncing upstream or restyling the feature; it is deliberately short.

## Two branches, two bases

| Branch | Base | Contains | Purpose |
| --- | --- | --- | --- |
| `mys-2811-upload-upstream-clean` | the recorded upstream `main` | the upload feature and its tests/docs only | upstream review and cherry-picking |
| fork `main` | the fork's own history | the upload feature **plus** the distribution patch set | what is released and deployed |

The upstream candidate carries no distribution file: no `myswy` release
workflow, no installer, no pinned image namespace, no NAS operations material, no
one-off review scripts. The fork keeps them. Nothing about a deployment, a
published tag or a live database belongs in the candidate.

## Migration numbering

The upload feature owns one table and three concurrent indexes, one statement per
file. The fork has applied them as `657`–`660` and those numbers are frozen:
they are recorded in `schema_migrations` on every deployed database, so
renumbering them would re-run or skip an applied migration.

The upstream candidate numbers them after whichever upstream migration is
highest at candidate time, and `server/cmd/migrate/main.go` must list each
concurrent index under its **new** version — `TestEveryConcurrentUpBuildHasCleanup`
fails the build otherwise. Every index is also registered for the interrupted-build
cleanup path, so a failed command is retried by re-running, not by hand.

Current mapping. The bodies are identical; only the prefix differs.

| Object | Fork (deployed, frozen) | Upstream candidate |
| --- | --- | --- |
| `attachment_upload_session` table | `657` | `660` |
| `uq_attachment_upload_session_staging_key` | `658` | `661` |
| `idx_attachment_upload_session_due` | `659` | `662` |
| `idx_attachment_upload_session_workspace` | `660` | `663` |

The candidate starts at `660` because upstream claimed `657`–`659`
(`657_inbox_item_snoozed_until`, `658_project_archive`,
`659_issue_view_preference_projects_page`) while this feature was in review. A
candidate built on a later upstream base must move again, to that base's highest
plus one, and update the cleanup map with it.

`attachment_upload_session` has no foreign keys (repository rule); workspace
teardown hands its rows to the reconciler instead of deleting them, because the
row is the only record naming an object the client's write may still materialize.

## Migrating a deployed fork database (solved in `v0.11.1-myswy.1`)

The 657–660 rows exist on every deployed database, and upstream later allocated
the same numbers to different changes. The resolution keeps the fork's numbers
frozen and shifts the **whole** upstream block up by four:

| Lineage | 657–660 | 661–700 |
| --- | --- | --- |
| fork (deployed, `v0.9.0-myswy.2`) | upload feature (frozen) | — |
| fork (`v0.11.1-myswy.1` and later) | upload feature (frozen) | upstream's 657–696, renumbered +4 |

Upstream 657–696 become 661–700 in this distribution. Their SQL bodies are
unchanged; only the prefix moves, plus the `migration NNN` cross-references in
the four files that name a sibling. `server/cmd/migrate/main.go` lists the
concurrent-index cleanup hooks under the **new** numbers, and
`TestEveryConcurrentUpBuildHasCleanup` fails the build if an entry is missed.

Because the lineages hold different filenames under 657–700, a ledger is only a
valid starting point if **every** row in it belongs to this distribution.
`runMigrations` checks that **before the first statement**, as an allowlist:
each recorded version must be a file this build ships, or one of the verified
`historicalLedgerAliases` (a name an earlier build of this distribution shipped
before renumbering it, each paired with its regression test).

An allowlist rather than a denylist is deliberate. The first version of this
guard listed the 40 upstream filenames and refused only those; a ledger holding
a legitimate `.2` prefix **plus one leftover stem from the historical upstream
candidate** (`661_attachment_upload_session_staging_key`, the candidate's name
for the staging-key index) passed it, and the run appended 40 migrations on top
— ledger 685 → 725, tables 148 → 159. The regression
`TestMixedLedgerIsRefused` reproduces exactly that ledger and
`TestUnsupportedLedgersAreRefused` covers unknown stems, a stem past the
supported range and a ledger from another product.

Three lineages are named explicitly so the refusal says which one it found:
`upstreamLineageVersions` (upstream 657–696),
`historicalCandidateUploadVersions` (the candidate's upload numbering 660–663),
and anything else is reported as an unrecognised version.

What this supports, and what it does not:

- **Supported:** a database this distribution migrated (upstream `v0.9.0` plus
  the fork's 657–660), upgraded by running `migrate up` at `v0.11.1-myswy.1` or
  later. The upload rows, their indexes (same OIDs) and the 657–660 ledger rows
Rehearse on a restored copy before a real switch; the operations card for the
version being deployed owns the backup, compatibility and rollback conditions.

**What the rehearsal in this repository is, and is not.** The `.2` database used
to prove the upgrade path was built by running the released `v0.9.0-myswy.2`
migration tree against an empty isolated database and then inserting a few
identifiable rows. That is a *synthetic fixture reconstructed from the release
tree*, not a copy of any deployed database: it proves the migration ordering,
the ledger handling and that the upload objects survive, and it says nothing
about the data volume, row counts or data shapes on the NAS. Accepting an actual
production backup, and restoring it to a scratch volume, is the NAS managing
agent's step in the next phase — this repository does not have that data and
must not imply it was checked.

## Behaviour that must survive a conflict resolution

Each of these has a test that fails if the guarantee is dropped. Resolve toward
the guarantee, not toward whichever side of the conflict is shorter.

| Guarantee | Where it lives |
| --- | --- |
| Bytes never traverse the API | presign → client PUT → complete, in `server/internal/handler/attachment_upload.go` and `server/internal/cli/upload.go` |
| A valid staging credential cannot change a published object | the `If-Match` conditional copy in `server/internal/storage/s3_upload.go` |
| Published metadata describes the published bytes | the version-bound probe read, same file |
| No credential binds zero length | `presign-upload` declining `size_bytes: 0` with a capability code |
| One upload publishes one attachment, however often it is retried | the completing transaction's session lock in `server/internal/handler/attachment_upload.go` |
| Permission loss between presign and publish is refused | `revalidateAttachmentUploadTarget`, and `requireAttachmentAccessForRequest` for replays |
| Staging and abandoned objects are reclaimed | `server/internal/service/attachment_upload_reconciler.go` |
| An old server and a new client interoperate | the `404`/`501` capability fallback in `server/internal/cli/upload.go` and `packages/core/api/client.ts` |

## Verification

```bash
cd server && go test ./cmd/migrate ./internal/migrations ./internal/storage \
  ./internal/cli ./cmd/multica -count=1
make test                                    # race + real isolated DB
pnpm --filter @multica/core test
pnpm --filter @multica/core typecheck
pnpm --filter @multica/core lint
bash scripts/direct-upload-smoke.test.sh     # the smoke script's own safety rules
bash scripts/direct-upload-browser-smoke.test.sh
bash scripts/direct-upload-smoke.sh          # real isolated S3 + PG, 0/50/100 MiB
bash scripts/direct-upload-browser-smoke.sh  # real isolated S3 + PG + Chromium
```

The two `-smoke.sh` runs provision and delete their own database, S3 server, proxy
and Chromium; they never touch a configured deployment. The browser run uploads
one image larger than the proxy's body limit, not the CLI's size matrix — say so
rather than implying it covers 50 and 100 MiB.

Changes to a shared connection, session or rate-limit mechanism additionally need
the multi-agent concurrent-registration smoke. A change confined to upload
sessions instead needs the concurrent-complete and cleanup-race regression; that
coverage already exists in `attachment_upload_test.go` and
`attachment_upload_reconciler_test.go` and must not be deleted.

## Frontend checks run on CI's Node version

The `frontend-test` job pins Node 22. Run these on 22 as well, not on whatever
`node` is on the developer machine: Node 25+ ships a global `localStorage` that
`packages/vitest-setup/web-storage.ts` replaces with an in-memory shim, and
`Object.keys(shim)` returns the shim's *methods*, so
`clearAllWorkspaceStorage` cannot enumerate stored keys and
`platform/doc-session-cleanup.test.ts` fails. That is a Node-version artifact,
not a regression — it reproduces on the unmodified upstream tag.

```bash
pnpm --filter @multica/core test        # Node 22
pnpm --filter @multica/core typecheck
pnpm --filter @multica/core lint
```

## Where the history went

The NAS maintenance executor that carried the `616→660` production switch during
`v0.9.0-myswy.2` is not part of the feature and no longer sits on the development
path. It remains readable at the immutable commit
`a2d90039b2841b00f75b857019d0f4ca63ea43f0`:

```bash
git show a2d90039b:scripts/nas-maintenance.sh
git show a2d90039b:scripts/nas-maintenance.test.sh
git show a2d90039b:docs/nas-myswy-maintenance.md
```

It was written for exactly one switch — the `616→660` cut over to
`v0.9.0-myswy.2` — and **must not be reused for any other version**. A later
version needs its own operating card, with its own compatibility, backup and
rollback conditions, written against that version's migrations.
