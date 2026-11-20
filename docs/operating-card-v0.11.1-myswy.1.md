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
a daemon from `v0.11.1` talking to a `v0.9.0-myswy.2` server would meet a build
without the 661–700 objects, while an old daemon talking to the new server meets
a complete schema and only loses feature endpoints it does not call yet.

What was actually exercised for this card, and what was not:

| Claim | Evidence |
| --- | --- |
| `.2` daemon registers against the candidate server | measured — real `v0.9.0-myswy.2` binary, two runtimes `online` |
| `.2` daemon heartbeats | measured — `agent_runtime.last_seen_at` advancing |
| `.2` daemon claims a queued task | measured — task moved `queued` → `dispatched` → `running` |
| `.2` daemon reports a terminal result | measured — task ended `failed` with the agent's own error, i.e. the report path worked |
| candidate daemon does the same | measured — identical lifecycle and identical error |
| real agent run completes successfully | **not** measured — no agent CLI login exists on the rehearsal host, so every run ends at "Not logged in". The task lifecycle around the run is proven; the run itself is not |
| NAS hardware, real backup, production data | **not** measured — belongs to the NAS managing agent |

### 1. NAS server

1. Record what is actually running: `docker compose config --images`,
   the two image digests, the `schema_migrations` maximum, and free disk. Do not
   assume the compose file still matches [the first deployment](../docs/self-host-distribution.md);
   re-read it.
2. Confirm no agent task is running, then stop write traffic. Take the backup
   **after** writes have stopped, never before: a backup taken while tasks are
   still committing can restore to a point the ledger never reached, and the
   new server would then either replay those writes or refuse the ledger. Record
   the `schema_migrations` max at the moment of the backup and keep it with the
   file.
3. Verify that backup restores, on an isolated copy — not on the production
   volume. The 40 new migrations include several `CREATE INDEX CONCURRENTLY`
   builds on large tables, so a partly-applied run is not reversible in place;
   the restored copy is the rollback.
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

Two different failures, two different answers. Decide which one you are in
before touching anything.

**Decide first — is the migration state known?** Run
`SELECT max(version), count(*) FROM schema_migrations;` and compare it with the
value recorded at backup time.

- max is `700_inbox_item_active_shown_idx` (or the run completed and reported
  success): the migration is known-good. Application rollback is available.
- Anything else — a mid-run failure, a count that does not match, an error from
  the runner: migration state is **unknown**. Do **not** attempt an application
  rollback. Stop, keep the volume and logs, and go to the restored-copy path.

**A. Application rollback (known-good migration only).** Restore the
`v0.9.0-myswy.2` image digests and start them. The 661–700 ledger rows stay; the
old binary ignores versions above its own last migration, which is what makes
this the cheap path. Release this path only when all of the following hold, and
record each one:

- [ ] the running digests are the `v0.11.1-myswy.1` ones this card shipped
      (compare with the release notes, not with `latest`);
- [ ] `schema_migrations` ends at `700_inbox_item_active_shown_idx`;
- [ ] the backup taken at step 2 restores cleanly on an isolated copy, so B is
      still available if A fails;
- [ ] no task was running when the switch happened, so no task is stranded on a
      half-written run.

**B. Database rollback (unknown migration state, or A failed).** Use the
restored copy, never the production volume:

1. Restore the verified backup into a **new database on a new volume**.
2. Start the `v0.9.0-myswy.2` stack against that new database and verify
   `/health` plus one read and one write.
3. Switch the application's connection to the new database only after step 2
   passes.
4. Leave the old volume untouched. It is the evidence for what went wrong and
   the only remaining copy of any write that happened after the backup.

Never run `migrate down` across 661–700 in place, never drop the database to
"start clean", and never edit `schema_migrations` by hand to get past a refusal.
A hand-edited ledger is exactly the mixed-lineage state the runner refuses.

**Daemon rollback.** Restore the previous binary and its service configuration,
then re-check registration, heartbeat, and one task. Do not restore a daemon
binary without also restoring its profile: the daemon id is what the server
attributes runtimes to.

### Pre-switch checks for the NAS host

- [ ] the old CLI updater/timer is disabled or retargeted — the current pin is
      `v0.9.0-myswy.2`, and a timer that reinstalls it will silently undo the
      upgrade (see step 2 of the daemon section);
- [ ] only one update control source is active for that binary;
- [ ] free disk covers the new images plus a full database backup;
- [ ] the compose file, project name and service names in use match what this
      card assumes, re-read rather than remembered.

## Compatibility

| Combination | Status |
| --- | --- |
| `v0.11.1` daemon + `v0.11.1` server | the target |
| `v0.9.0-myswy.2` daemon + `v0.11.1` server | **exercised**: registered, heartbeated, claimed a queued task and reported its terminal result against the candidate server. A real agent run was not completed (no CLI login on the rehearsal host), so treat "old daemon runs real work against the new server" as unproven until one task is watched on the first machine you roll |
| `v0.11.1` daemon + `v0.9.0-myswy.2` server | not a target and not exercised; docs/wakeup/rate-limit endpoints are absent there, so upgrade the server first |

Also exercised against the candidate server, as a bounded record rather than a
soak: 25 identities × 6 rounds of concurrent registration (150/150 `200`,
exactly 25 distinct runtimes — no duplicates), 25 reconnects (25/25 `200`),
25 runtimes × 5 heartbeat rounds (125/125 `200`), and 10/10 invalid credentials
refused with `401`. The invitation rate limiter was driven past its actor limit:
10 × `201` then `429`, and `201` again once the limit was raised — trigger and
recovery both observed. These numbers describe one 20-core host with a warm
process, not a capacity claim.

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
