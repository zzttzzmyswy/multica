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

**Migrating a live fork database to a future sync is not solved here.** The 657–660
rows exist; a future upstream line will allocate the same numbers to different
changes. Which migration runs on which database, and whether the upload table's
numbers can move at all, has to be designed against the deployed schema and
rehearsed on a restored copy before any sync ships. Do not treat a clean
cherry-pick as evidence that a deployed database can be upgraded.

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
