# Operating card: v0.11.1-myswy.1

The switch from `v0.9.0-myswy.2` to `v0.11.1-myswy.1`, and what each machine has
to do in which order. This card covers the schema change only; digests,
checksums and release assets are filled in by whoever signs the release, because
they do not exist until the images are pushed.

Read this together with [upload-patch-contract.md](upload-patch-contract.md),
whose "Migrating a deployed fork database" section explains *why* the migration
numbers look the way they do.

## What changes

| Area | Change |
| --- | --- |
| Schema | upstream `657`–`696` enter this distribution as `661`–`700` (40 new migrations) |
| Schema | the fork's `657`–`660` (upload sessions) stay frozen in place |
| Schema | a database migrated by the upstream line is now refused outright |
| Server | upstream `v0.11.1` features: docs, chat wakeups, project folders, runtime rate limits, WeChat channels, entitlement overage |
| Daemon | upstream daemon and CLI changes between `v0.9.0` and `v0.11.1` |
| Protocol | see "Compatibility" below; nothing in this card forces a protocol break |

Filling in the release: `X.Y.Z`-level values (`BACKEND_DIGEST`, `WEB_DIGEST`,
platform checksums) come from the release run. Do not guess them, and do not
substitute `latest`.

## Order of operations

Server first, then daemons, one daemon at a time. The reason is the migration:
a daemon from `v0.11.1` talking to a `v0.9.0-myswy.2` server sees no docs, chat
wakeup or rate-limit endpoints, and those features degrade rather than break —
but the reverse (old daemon, new server) is the combination that has been
exercised, so server-first keeps every intermediate state on the tested path.

### 1. NAS server

1. Record what is actually running: `docker compose config --images`,
   the two image digests, the `schema_migrations` maximum, and free disk. Do not
   assume the compose file still matches [the first deployment](../docs/self-host-distribution.md);
   re-read it.
2. Back up the database and verify the backup restores, on an isolated copy.
   The 40 new migrations include several `CREATE INDEX CONCURRENTLY` builds on
   large tables; they are not reversible in place once partway through, so the
   backup is the rollback.
3. Confirm no agent task is running, then stop write traffic.
4. Pin `MULTICA_BACKEND_DIGEST` and `MULTICA_WEB_DIGEST` to the release digests
   and start with `make selfhost-digest`. The entrypoint runs `migrate up`.
5. Verify: both containers report the release revision, `/health` is green, a
   login and one issue read/write work, and `schema_migrations` now ends at
   `700_inbox_item_active_shown_idx`.
6. Check the upload paths end to end — 0 B (must fall back to multipart), 50 MiB
   and 100 MiB through the CLI, and one browser upload above the proxy body
   limit — and compare download hashes.

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
6. Confirm the update control source still points at this distribution. The NAS
   CLI updater pinned `v0.9.0-myswy.2`; that pin has to move with this release
   or be handed over, otherwise the old timer reinstalls the old version.

### 3. Rollback

- **Application only:** if the old app is compatible with the migrated schema,
  restore the `v0.9.0-myswy.2` images and digests. The 661–700 ledger rows stay.
  This is the cheap path and the expected one.
- **Database:** only with a restored backup on a new volume. Do not run
  `migrate down` across 661–700 in place, and never clear the database to
  "start clean".
- **Daemon:** restore the previous binary and its service configuration, then
  re-check registration and heartbeat.

## Compatibility

| Combination | Expected |
| --- | --- |
| `v0.11.1` daemon + `v0.11.1` server | supported, the tested target |
| `v0.9.0-myswy.2` daemon + `v0.11.1` server | expected to work; upstream preserves daemon compatibility within a minor line, and the CLI falls back when an endpoint is absent. Verify one real task before rolling the rest |
| `v0.11.1` daemon + `v0.9.0-myswy.2` server | not a target; docs/wakeup/rate-limit features degrade, so upgrade the server first |

## Gates before a deployment card is issued

- [ ] `v0.11.1` merge verified: upstream tag is an ancestor of the release commit.
- [ ] `.2` → candidate and empty → candidate both migrate clean, and a second
      `migrate up` reports no pending work.
- [ ] the 40 renamed migrations are body-identical to upstream apart from
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
