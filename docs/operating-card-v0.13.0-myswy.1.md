# Operating card: v0.13.0-myswy.1

The switch from `v0.11.1-myswy.1` to `v0.13.0-myswy.1`, and what each machine has
to do in which order. Digests, checksums and release assets are filled in by
whoever signs the release, because they do not exist until the images are pushed.

Read this together with [upload-patch-contract.md](upload-patch-contract.md),
whose "Migrating a deployed fork database" section explains *why* the migration
numbers look the way they do, and with
[operating-card-v0.11.1-myswy.1.md](operating-card-v0.11.1-myswy.1.md), which
covers the previous hop. Nothing in this card changes that hop's conclusions.

## What changes

| Area | Change |
| --- | --- |
| Schema | upstream `697`–`755` enter this distribution as `701`–`759` (59 new migrations) |
| Schema | the fork's `657`–`660` (upload sessions) and the first sync's `661`–`700` stay frozen in place |
| Schema | `attachment` gains a covering `workspace_id INCLUDE (size_bytes)` index and loses the plain one; the storage sum becomes an index-only scan |
| Schema | `task_usage_hourly` is re-keyed: a per-hour rollup replaces recomputing only the squad keys an update touched |
| Server | upstream `v0.13.0` features: guest role, workspace Docs with live co-editing, remote apps, issue blockers, comment idempotency receipts, dashboard range views, app tool-call quotas |
| Server | new `storage_bytes` entitlement gate (off / observe / enforce); **off is the self-hosted default**, so a self-hosted deployment reads nothing and refuses nothing |
| Client | new daemon protocol capabilities; see "Compatibility" below |
| Compose | an optional `collab` service for live doc co-editing, off by default and behind the `collab` profile. This distribution publishes **no** collab image — see "The collab service" |

Filling in the release: `X.Y.Z`-level values (`BACKEND_DIGEST`, `WEB_DIGEST`,
platform checksums) come from the release run. Do not guess them, and do not
substitute `latest` — this distribution publishes no `latest` tag.

## Order of operations

Server first, then daemons, one daemon at a time. The reason is the migration:
a `v0.13.0` daemon talking to a `v0.11.1-myswy.1` server would meet a build
without the 701–759 objects, while an older daemon talking to the new server
meets a complete schema and only loses feature endpoints it does not call yet.

### 1. NAS server

1. Record what is actually running: `docker compose config --images`, the two
   image digests, the `schema_migrations` maximum, and free disk. Do not assume
   the compose file still matches what a previous card described; re-read it.
2. Confirm no agent task is running, then stop write traffic. Take the backup
   **after** writes have stopped, never before: a backup taken while tasks are
   still committing can restore to a point the ledger never reached, and the new
   server would then either replay those writes or refuse the ledger. Record the
   `schema_migrations` max at the moment of the backup and keep it with the file.
3. Verify that backup restores, on an isolated copy — not on the production
   volume. The 59 new migrations include several `CREATE INDEX CONCURRENTLY`
   builds and a `task_usage_hourly` re-key whose up and down directions both
   rewrite data, so a partly-applied run is not reversible in place; the restored
   copy is the rollback.
4. Pin `MULTICA_BACKEND_DIGEST` and `MULTICA_WEB_DIGEST` to the release digests
   and start with `make selfhost-digest`. The entrypoint runs `migrate up`.
5. Verify: both containers report the release revision, `/health` is green, a
   login and one issue read/write work, and `schema_migrations` now ends at
   `759_task_usage_hourly_rollup_hour_key`.
6. Check the upload paths end to end — 0 B (must fall back to multipart), 50 MiB
   and 100 MiB through the CLI, and one browser upload above the proxy body
   limit — and compare download hashes.
7. One extra check for this release specifically: the attachment index swap
   leaves a workspace's byte sum readable through a covering index. Compare
   `SELECT coalesce(sum(size_bytes),0) FROM attachment WHERE workspace_id = $1`
   before and after for one workspace you recorded at step 1. It must be equal,
   and `EXPLAIN` should show `Index Only Scan using idx_attachment_workspace_size`
   when more than one workspace has attachments.

If step 4 refuses with `refusing to migrate a database whose schema_migrations
was written by the upstream migration line`, **stop**. The database is not the
lineage this release upgrades. Restore the backup and escalate; deleting ledger
rows to get past it produces a schema nobody has tested.

### 2. Daemons — 1324, NAS, nasU24

One machine at a time, and start with a machine whose interruption is cheapest.
Each machine:

1. Record the running executable path, process version, service unit and the
   server it talks to. `multica --version` in an interactive shell is not the
   daemon.
2. Wait for running tasks to finish; stop accepting new ones.
3. Install the release asset for the platform, verify its checksum and the
   binary's own version.
4. The supervisor that restarts the daemon must not be the daemon. Use the
   service unit, not an agent inside it.
5. Verify: process path and version, service state, re-registration, heartbeat,
   and one real task claimed and completed.
6. Confirm the update control source still points at this distribution. A CLI
   updater pinned to an older tag has to move with this release or be handed
   over, otherwise the old timer reinstalls the old version.

This release adds daemon-side protocol capabilities (Docs, blockers, comment
idempotency). A daemon that has not been upgraded keeps working; it just cannot
use the new endpoints. That is why the server can go first.

### The collab service (optional, and not part of this distribution's release)

Upstream `v0.13.0` ships live doc co-editing as a separate service. This
distribution does **not** build or publish it:

- `.github/workflows/release-myswy.yml` builds backend and web only, and
  `.goreleaser.myswy.yml` produces the CLI archives. There is no
  `ghcr.io/zzttzzmyswy/multica-collab` image.
- `docker-compose.selfhost.yml` therefore pins the collab service to the
  **upstream** image at the upstream version this build is based on, through its
  own `MULTICA_COLLAB_IMAGE` / `MULTICA_COLLAB_IMAGE_TAG` pair. Reusing
  `MULTICA_IMAGE_TAG` there would render `ghcr.io/multica-ai/multica-collab:v0.13.0-myswy.1`,
  which upstream never published, and the pull would fail.
- The service is behind `COMPOSE_PROFILES=collab` and off by default. Leaving it
  off is the supported self-hosted mode: each doc edit saves through the API.
- `deploy/helm/multica/values.yaml` pins the same upstream tag for the same
  reason.

Treat "collab works" as out of scope for this release's acceptance. If a
deployment turns it on, the image it runs is upstream's, not one this
distribution tested.

### 3. Rollback

Two different failures, two different answers. Decide which one you are in
before touching anything.

**Decide first — is the migrated schema complete?** Neither the maximum version
nor the runner's exit code answers this. A recorded version means the runner
*skipped* it. Verify the schema itself:

1. **The ledger is the expected one.** Compare `SELECT version FROM
   schema_migrations ORDER BY version` against the list recorded at backup time
   plus exactly the versions this release adds. The count is not enough — a count
   can be right while one name is wrong. Expect the 701–759 block appended and
   every earlier row byte-identical.
2. **The DDL this release adds exists.** Several versions exist only for an
   index, so check the objects, not the rows:

   ```
   SELECT relname, relkind FROM pg_class
    WHERE relname IN ('idx_attachment_workspace_size','member_search_access',
                      'doc_comment','doc_collab_state','doc_revision',
                      'remote_app_connection','comment_idempotency_receipt',
                      'issue_blocker','squad_handoff_mode','app_tool_call_quota');
   ```

3. **Every index this release builds is present AND valid.** A concurrent build
   that was interrupted leaves an `indisvalid = false` relation that `IF NOT
   EXISTS` will not rebuild:

   ```
   SELECT c.relname, i.indisvalid FROM pg_index i
     JOIN pg_class c ON c.oid = i.indexrelid
    WHERE NOT i.indisvalid;
   ```

   Any row here means the migration did not finish, whatever `max(version)` says.
4. **`task_usage_hourly` has one row per hour key, not per squad.** This release
   re-keys the rollup; a half-applied run can leave both shapes:

   ```
   SELECT count(*) FROM task_usage_hourly WHERE squad_id IS NOT NULL;
   ```

   Compare with what step 1 recorded. A number that moved in a way the
   reconciliation cannot explain is a stop signal, not a number to round off.
5. **The backup is still the fallback,** and nothing was written after it that
   you are not prepared to lose.
6. **Business data is intact** — one issue read and one write, one upload
   round-trip, and the counts you recorded before the switch.

Only when all six pass is the migration "known". Otherwise treat it as unknown
and take path B.

**A. Application rollback.** Restore the `v0.11.1-myswy.1` image digests and
start them. The 701–759 ledger rows stay; the old binary ignores versions above
its own last migration. Release this path only when all of the following hold,
and record each one:

- [ ] steps 1–6 above all pass;
- [ ] the running digests are the `v0.13.0-myswy.1` ones this card shipped
      (compare with the release notes, not with `latest`);
- [ ] the backup taken at step 2 restores cleanly on an isolated copy, so B is
      still available if A fails;
- [ ] no task was running when the switch happened, so no task is stranded on a
      half-written run;
- [ ] **the old application has been run against the migrated schema in
      isolation and read and wrote normally.**

That last point is not covered by the migration passing. A completed migration
proves the schema matches what the *new* server expects; it says nothing about
the `v0.11.1-myswy.1` binary, which queries the tables it knew about and ignores
the rest. Dropping or reshaping a column it still reads would break it and the
migration would not notice. This release drops `idx_attachment_workspace`, which
the old binary's plain `workspace_id` lookups still plan against — the covering
index serves them, but that is exactly the kind of claim to measure rather than
assume. **This card has not made that measurement on real data**, so as of this
card path A is not released: until an isolated old-application run is recorded,
treat A as unavailable and use B.

**B. Database rollback (unknown migration state, or A failed).** Use the
restored copy, never the production volume:

1. Restore the verified backup into a **new database on a new volume**.
2. Start the `v0.11.1-myswy.1` stack against that new database and verify
   `/health` plus one read and one write.
3. Switch the application's connection to the new database only after step 2
   passes.
4. Leave the old volume untouched. It is the evidence for what went wrong and
   the only remaining copy of any write that happened after the backup.

Never run `migrate down` across 701–759 in place, never drop the database to
"start clean", and never edit `schema_migrations` by hand to get past a refusal.
A hand-edited ledger is exactly the mixed-lineage state the runner refuses.

**Daemon rollback.** Restore the previous binary and its service configuration,
then re-check registration, heartbeat, and one task. Do not restore a daemon
binary without also restoring its profile: the daemon id is what the server
attributes runtimes to.

### Pre-switch checks for the NAS host

- [ ] the old CLI updater/timer is disabled or retargeted — a timer that
      reinstalls an older tag will silently undo the upgrade (see step 2 of the
      daemon section);
- [ ] only one update control source is active for that binary;
- [ ] free disk covers the new images plus a full database backup;
- [ ] the compose file, project name and service names in use match what this
      card assumes, re-read rather than remembered;
- [ ] `COMPOSE_PROFILES` does not include `collab` unless you deliberately want
      the upstream collab image, and if it does, that image is pinned by digest
      too.

## Compatibility

| Combination | Status |
| --- | --- |
| `v0.13.0` daemon + `v0.13.0` server | the target |
| `v0.11.1-myswy.1` daemon + `v0.13.0` server | **exercised** against a locally built candidate on the rehearsal host: registered, heartbeated, claimed a queued task and reported its terminal result. A real agent run was not completed (no agent CLI login on the rehearsal host), so treat "the old daemon runs real work against the new server" as unproven until one task is watched on the first machine you roll |
| `v0.13.0` daemon + `v0.11.1-myswy.1` server | not a target and not exercised; the new daemon's Docs/blockers/idempotency endpoints are absent there, so upgrade the server first |

Two different kinds of observation are recorded in that row, and they must not be
read as one:

**Connection and registration behaviour** (a bounded record, not a soak): see the
measurement appendix in this card's delivery evidence. It covers concurrent
registration with distinct identities, reconnect, heartbeat, duplicate-identity
handling and credential refusal on one isolated host. It is not a capacity claim
and it is not a rate-limit measurement.

**Rate limiting is a separate mechanism.** Do not cite registration counts as
evidence of limit behaviour, or limiter numbers as evidence about daemon traffic.

**Test scope.** The migration rehearsal uses databases built on an isolated
PostgreSQL: one by running the previous release's own migration tree, one empty,
one at the upload block. They are synthetic fixtures, not copies of production.
Nothing in this card was measured on the NAS, on real production data, or through
the real reverse proxy and TLS path; those belong to each machine's managing
agent.

**Not measured, and therefore not claimed:** a real agent run completing
successfully, the `v0.11.1-myswy.1` application reading and writing against the
migrated schema (see path A above), the collab service, and anything at
production data volume.

## Gates before a deployment card is issued

- [ ] `v0.13.0` merge verified: upstream tag is an ancestor of the release commit.
- [ ] `.1` → candidate, `660` → candidate and empty → candidate all migrate
      clean, and a second `migrate up` reports no pending work.
- [ ] the 59 renamed migrations are body-identical to upstream apart from
      cross-reference comments.
- [ ] `go test ./cmd/migrate ./internal/migrations ./internal/storage ./internal/cli ./cmd/multica`,
      `make test`, `go tool govulncheck ./...`, the four `direct-upload-*`
      scripts, `install-myswy`, `myswy-release-guard`, `selfhost-config` and
      `helm-config` all pass.
- [ ] multi-agent concurrent registration against an isolated server.
- [ ] release assets and digests cross-checked against this commit.

## What this card does not do

It does not deploy. Each machine's managing agent runs its own section and
reports its own evidence; this card is the instruction and the acceptance
criteria, not the executor.
