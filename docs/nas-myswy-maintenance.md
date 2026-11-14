# NAS maintenance runbook: switching this deployment to v0.9.0-myswy.2

`scripts/nas-maintenance.sh` is the only entry point that changes production
state during the `.2` switch. This runbook is what the NAS operator follows:
which command to run, what "success" is allowed to mean, and where the
boundaries of the tool are.

The executor is designed to be driven by a supervisor process on the NAS — never
by an agent session and never through the Multica API, because Multica itself is
unavailable for the whole maintenance window. Its log and journal are on local
disk so a separate shell can watch progress.

## What this tool does and does not do

| | |
| --- | --- |
| Freezes every writer before backing up | Stops both timers **and** the services they may already have started, the daemon, and the backend/frontend containers; each is confirmed by reading its real state |
| Snapshots before touching anything | `prepare` records the compose file, image identity (the image the container runs plus its repo digests), CLI binary, upgrade script (hash, mode, owner) and all unit states, then publishes them with one rename; a second `prepare` only re-verifies that snapshot read-only and refuses if anything has drifted |
| Migrates with the exact image | `docker run --entrypoint /app/migrate <pinned .2 backend> up` — no server, no worker |
| Verifies what actually runs | Health commit, both container digests, ledger/table/index shape, CLI version and hash, unit entry point |
| Rolls back images, config, CLI and script | `rollback-r1` restores each one from the snapshot and verifies it, and keeps the current database |
| Restores the database | **Never.** `rollback-r2` is refused by design (exit 80) and prints a read-only plan |

Exit codes: `0` ok, `2` usage/config, `10` locked, `20` prepare, `30` freeze or
backup, `40` migrate, `50` candidate, `60` CLI/script, `70` rollback or thaw
incomplete, `80` refused.

## Pinned release

| Item | Value |
| --- | --- |
| backend digest | `sha256:01e09bc9d800260b89834c6a0a00433a456daa5f8ec06211a1515da103817702` |
| web digest | `sha256:011f47fd9a1adf688382f36d7b9446fd580d50b0b7321377492e189da46e4b26` |
| revision | `8098fd32808c57d8e3b6bd8f7408e6e47b81e7ab` |
| CLI archive SHA-256 | `6b1414ba07b9b5e4b6e01f2411917e35957812b52449801522c3d3d0a6195e54` |
| approved upgrade script SHA-256 | `a777090243e1bcf237856486d9759ff596dbf95c1751c928a41ef19388ed58d7` |
| pre-change baseline | backend digest `864a9710…8374`, web digest `ece41d5b…31fa`, revision `b1ea927…`, ledger `616_member_pinned`, 131 tables, 740 indexes |
| target schema | ledger `660_attachment_upload_session_workspace`, 684 ledger rows, 148 tables, 799 indexes all valid and ready |

The executor holds these as constants. `prepare` refuses to continue when the
running containers, the ledger or the schema shape do not match the baseline,
because the rollback evidence was gathered on exactly that state.

**Identity is the image, not the reference text.** The real deployment's compose
file names `ghcr.io/multica-ai/multica-backend:latest` while the container runs
the validated build. `prepare` therefore identifies the running build by the
image ID `.Image` reports plus the repo digests that image carries, and accepts a
tag only when it resolves to the validated digest. The rollback reference
recorded for R1 is the full `repo@sha256:...` string the image itself reports —
never the compose reference with its repository rewritten, because a rewritten
prefix would name a reference nobody has proven resolvable. `prepare` re-resolves
that reference locally and requires it to be the same image that is running, so a
bad reference fails before the writers stop rather than at pull time.

The upgrade script is installed **verbatim** from the reviewed input with the
recorded hash; its internals are not reimplemented or "improved" here.

## Prepare once, before the window

Everything that can be verified without stopping anything happens here:
archive and script hashes, the CLI candidate's own `--version`, the approved
compose input (it may differ from the live file only in the two image lines),
the `.2` images already being on the box, the rollback baseline, and the
snapshot itself. `prepare` uses no network and runs no container.

```bash
install -m 755 nas-maintenance.sh /home/myswy/scripts/nas-maintenance.sh
install -m 600 maintenance.conf /home/myswy/.config/multica-maintenance.conf

/home/myswy/scripts/nas-maintenance.sh prepare \
  --config /home/myswy/.config/multica-maintenance.conf
```

Every write command requires `--config`, and requires it to be complete. There
is no fallback to a built-in production path: a forgotten parameter is a
refusal (exit 2), not a write to the wrong directory. An unknown or relative
path is refused too.

`prepare` also refuses while a timer job is in flight (`multica-upgrade.service`
or `multica-attachment-gc.service` still running): freezing a half-applied
update would leave a state the snapshot cannot describe. That refusal happens
before anything is written, so clearing the obstruction and re-running is enough.

Re-running `prepare` re-verifies the assets against the hashes the journal
recorded and **keeps** the original snapshot: it does not rebuild it. That is a
read-only comparison of both the snapshot files and the live ones, so if the live
updater, CLI or compose file has changed since the first run the command exits
`20` and leaves the recorded originals untouched. A snapshot file that no longer
matches its recorded hash is reported the same way rather than silently
repaired. Once the journal has moved past `prepared`, `prepare` refuses outright.

The publish is a single transaction over **both** the assets and the journal.
Every file and every journal key is written under `assets.new/` and
`journal.new` first; only then are they renamed into place, assets first and the
journal last. A failure at any earlier point — a required input missing, an asset
that does not verify, a baseline mismatch, a timer job in flight — removes the
staging copies and publishes nothing, so the state on disk is either the complete
previous snapshot or no snapshot at all. A failure while publishing rolls the
assets back to the previous copy, so a published journal never describes files
that are not there, and vice versa: the journal's hashes and the files on disk
always belong to the same snapshot.

A first `prepare` that fails is therefore **retryable with no manual cleanup**.
That matters because the alternative the previous revision shipped — half a
journal with no `config_sha256` — refused every later run and left the operator
deleting files by hand.

Config keys (`KEY=VALUE`, one per line, `#` comments):

```
COMPOSE_DIR=/home/myswy/dockers/multica
COMPOSE_FILE=/home/myswy/dockers/multica/docker-compose.yml
COMPOSE_FILE_NEW=/home/myswy/dockers/multica/docker-compose.myswy2.yml
PROJECT=multica
DOCKER_NETWORK=multica-net
PG_CONTAINER=pgvector-pgvector
PG_USER=multica
PG_DATABASE=multica
BACKEND_CONTAINER=multica-backend-1
FRONTEND_CONTAINER=multica-frontend-1
DAEMON_UNIT=multica-daemon
UPGRADE_TIMER=multica-upgrade.timer
GC_TIMER=multica-attachment-gc.timer
BACKEND_URL=http://127.0.0.1:8080/health
CLI_BIN=/usr/local/bin/multica
UPGRADE_SCRIPT=/home/myswy/scripts/upgrade-multica.sh
CLI_ARCHIVE=/home/myswy/incoming/multica-cli-0.9.0-myswy.2-linux-amd64.tar.gz
APPROVED_UPGRADE_SCRIPT=/home/myswy/incoming/upgrade-multica.sh
STATE_DIR=/home/myswy/.local/state/multica-maintenance
LOG=/home/myswy/scripts/multica-maintenance.log
BACKUP_DIR=/Volume1/@backup
CLI_ARCHIVE_SHA256=6b1414ba07b9b5e4b6e01f2411917e35957812b52449801522c3d3d0a6195e54
APPROVED_UPGRADE_SHA256=a777090243e1bcf237856486d9759ff596dbf95c1751c928a41ef19388ed58d7
```

### Compose resolution

Every `docker compose` invocation pins the deployment directory:

```
docker compose -f <file> --project-directory "$COMPOSE_DIR" -p "$PROJECT" <args>
```

This is required, not cosmetic. The real compose file uses `env_file: .env`,
`${POSTGRES_PASSWORD}` interpolation and a relative bind mount, and Compose
resolves all three against the **project directory**, not against the directory
holding the `-f` file. The rollback file lives under the state directory, which
has no `.env`; without the flag it fails to load with `env file .env not found`
and interpolates the password to an empty string — after the writers are already
stopped.

`scripts/nas-maintenance-compose.test.sh` proves this against the real Compose
CLI (no daemon, no network, placeholder values only): it loads a synthetic
deployment, shows that the snapshot fails from its own directory, shows that it
loads and resolves to the same model with the directory pinned, and fails if the
flag is removed from the wrapper.

Timeouts (`STOP_TIMEOUT`, `BACKUP_TIMEOUT`, `TOC_TIMEOUT`, `MIGRATE_TIMEOUT`,
`UP_TIMEOUT`, `HEALTH_TIMEOUT`, `QUERY_TIMEOUT`, `PROBE_TIMEOUT`,
`HEALTH_POLL_INTERVAL`) default to the values in the script header, but an
explicitly configured one must be a **positive integer**: a blank, zero or
non-numeric value is refused (exit `2`). `timeout(1)` is required; without it no
external call can be bounded, so the tool refuses to run rather than degrade to
an unbounded call. Every external command — including `<cli> --version` — goes
through that ceiling. See the remaining gap in "Limits" below about calls that
are still unbounded.

## The window

Run the bounded sequence under a supervisor, from a shell that is independent of
Multica:

```bash
setsid nohup /home/myswy/scripts/nas-maintenance.sh run --intent=switch \
  --config /home/myswy/.config/multica-maintenance.conf \
  >>/home/myswy/scripts/multica-maintenance.console.log 2>&1 &
```

`run` refuses any intent other than `switch`. It takes one mutually exclusive
lock — a second action exits `10` rather than queueing — and executes seven
steps in one process:

1. **freeze** — stop `multica-upgrade.timer` and `multica-attachment-gc.timer`,
   then the services those timers may already have started, then
   `multica-daemon`, then `docker compose stop backend frontend`. Every stop is
   confirmed by re-reading the unit state and `docker inspect`. A failing
   command, a still-`active` unit, or a `deactivating`/`reloading`/`unknown`
   transition is a failure (exit `30`). The backend container is the API: once it
   and the daemon are down, API writes are blocked without any proxy or firewall
   change.
2. **backup** — after re-confirming the writers are still down, `pg_dump -Fc`,
   then `pg_restore -l` with an explicit **exit-code** check plus a TOC minimum.
   A line count alone would hide a parser failure. The dump's SHA-256, size and
   TOC count are journalled; a partial file is removed.
3. **migrate** — the pinned image's `/app/migrate up` only. A non-zero exit
   preserves the site and stops (exit `40`) with the real ledger, row, table and
   index counts. A partial ledger, a wrong row count, a wrong table count or an
   invalid index also stops; there is no automatic continuation and no claim
   that an intermediate schema is recoverable.
4. **switch** — write the approved compose input (hash-checked against the
   snapshot), `docker compose up -d backend frontend`, then require an answer
   from `/health` that carries the exact revision **and** both containers
   running the exact digests. A 200 with no commit, a wrong commit, or a wrong
   digest fails (exit `50`).
5. **cli** — verify the unit still executes the maintained script *before*
   replacing anything, install the staged CLI atomically, verify its hash **and**
   its `--version`, then install the approved upgrade script with the recorded
   mode/owner and verify the hash again (exit `60`).
6. **verify** — re-read health, ledger, rows, tables, indexes, both digests, the
   CLI and the frozen-while-verifying condition; every mismatch fails.
7. **thaw** — restore the daemon and timer states recorded at `prepare`. A unit
   that was `active` and does not come back is exit `70`, never a silent pass.

A failure records the step in the journal and prints the real state. Re-running
`run --intent=switch` resumes at that step; it does not repeat completed steps,
and it never re-takes the backup or replaces the initial snapshot.

The stage is a position, not evidence, so every resume re-proves the facts the
remaining steps depend on:

- past the freeze and before the application is started, all five writers must
  still be down — the API or a oneshot timer service can come back between runs;
- past the backup, the recorded dump must exist and still match its SHA-256;
- a **failed migration is a latch**: `migrate_failed` is recorded, and a re-run
  refuses with exit `80` instead of treating the same command as permission to
  continue over a possibly half-migrated database. Inspecting the real schema and
  choosing the next step is the operator's decision, not the tool's;
- the staged CLI and approved upgrade script must still hash as recorded.

The journal is validated per stage before anything runs: required keys, legal
unit-state values, a `config_sha256` binding, and no duplicate keys. A truncated
or hand-edited journal is refused (exit `80`) rather than resumed with an empty
snapshot.

Watch progress from another shell at any time:

```bash
/home/myswy/scripts/nas-maintenance.sh status \
  --config /home/myswy/.config/multica-maintenance.conf
```

`status` takes no lock, so it works while `run` holds it. It prints the stage,
the journal, the log tail, and the live unit/container/image/CLI/database
state. It also works with no config (production defaults) and never writes.

## Rollback

### R1 — images, compose, CLI and upgrade script; database kept

```bash
/home/myswy/scripts/nas-maintenance.sh rollback-r1 \
  --config /home/myswy/.config/multica-maintenance.conf
```

This is one linked operation, because a partial R1 is worse than either end
state:

1. Stop the writers again (the upgrade timer must not swap the CLI back
   mid-restore).
2. Restore the snapshotted compose file and verify its hash, then start the
   containers from a **digest-pinned copy** of it, and require `/health` to
   report the **old** revision, both containers to run the **old** digests, and
   the frontend to actually answer. Restarting the new configuration and calling
   it a rollback is exactly the failure this replaces; starting from a file that
   names `latest` would let the registry decide which build comes back.
3. Restore the CLI from the snapshot; verify hash and version.
4. Restore the upgrade script from the snapshot with its recorded mode; verify
   hash. This is what stops the upgrade timer from pulling `.2` back onto a
   rolled-back box.
5. Restore the daemon/timer states recorded at prepare.

Each item is verified against its recorded hash, and every failure exits `70`
with the evidence printed. A snapshot that no longer matches the journal (a
tampered or partial copy) is a failure, not a best-effort restore. Rollback
refuses entirely when no prepare snapshot exists (exit `80`).

**The database is not rolled back.** The old backend reads the 660 schema; that
combination was verified before the `.2` release was cut.

### R2 — restoring the database is not part of this tool

```bash
/home/myswy/scripts/nas-maintenance.sh rollback-r2
```

This always exits `80` and prints a read-only plan. It has no destructive path:
no `pg_restore --clean`, no `DROP`, no `migrate down`, no ledger edit.

The reason is a boundary, not a missing feature. Once the new application has
served traffic, "no new data" cannot be proved by counting rows in one or two
tables — issue edits, comments, tasks and workspace changes all write. Restoring
the pre-change dump over the live database would silently discard whatever was
written after the freeze boundary, and the isolated rehearsal that restored into
a **new empty volume** does not demonstrate that an in-place restore is
equivalent.

Recovering the old database therefore means: keep the current database and
volume untouched, restore the recorded dump into a **new** database or volume on
the same PG 16.15 / vector 0.8.5 instance, verify it (ledger `616`, 131 tables,
740 valid indexes, health on a throwaway old-image instance), and only then
switch the connection. Creating that database, restoring into it, and switching
`DATABASE_URL` need their own reviewed operation card with their own stop
conditions — they are not automated here.

## Scope status: this is not a releasable executor yet

Two work items were separated out of one oversized card after two acceptance
rounds. This revision covers only the first:

- **A (this change)**: real image identity and rollback references, Compose
  resolution, and the `prepare` transaction.
- **B (not done)**: the resume/migration state machine — late-stage resume
  revalidation, a migration latch that covers shape failures and interruption,
  and per-stage journal field requirements. Tracked separately; until it lands,
  the executor must not be installed or run against production, and an
  acceptance of A means only that this code range is complete.

## What must still be tested on the NAS

This executor was developed and verified offline only. The following are
explicitly **not** covered and belong to the NAS window:

1. A real `run --intent=switch` end to end against live systemd, docker and
   PostgreSQL 16.15 / vector 0.8.5.
2. A real `rollback-r1` drill on the resulting state, including that the
   restored unit states match what `prepare` recorded, and that the derived
   digest-pinned rollback compose file starts the expected builds.
3. The browser upload matrix (0/50/100 MiB) through the **production** reverse
   proxy — the isolated HTTPS edge used earlier does not prove the production
   path.
4. The one-shot no-op run of the installed upgrade script
   (`systemctl start multica-upgrade.service`) confirming it reports "already
   .2" and exits 0.
5. Real timing: the isolated rehearsal measured R1 at 2.26 s and an empty-volume
   restore at 76.3 s; production compose rebuild and reverse-proxy readiness
   will be slower. Treat those numbers as a lower bound, not a promise.
6. The frontend readiness probe against the real reverse proxy: the URL, its
   expected status, and whether a 200 from the proxy actually reflects a serving
   Next.js app. The offline suite proves the gate reacts to the status code, not
   that the configured URL is the right one for this deployment.
7. The real image-identity check on a host whose compose file names
   `ghcr.io/multica-ai/multica-{backend,web}:latest`. The rule is implemented and
   tested against stubs, but confirming that the NAS's live containers carry the
   validated repo digests is a read-only check that must run on the box.
8. The real deployment's own compose file through `compose_run`. The real-Compose
   suite proves the mechanism on a synthetic file; the production file's actual
   `env_file`/interpolation/mounts must be confirmed on the box before the
   window.

## Limits that are known and deliberate

- **Not every external call is time-bounded.** Everything that goes through
  `bounded` is; `docker`/`systemctl`/`psql` readiness checks and the mounted
  filesystem operations are not individually wall-clocked. A hung `flock`,
  `install`, or `mv` on a stalled NFS mount would still block. The maintenance
  window is supervised for that reason.
- **`prepare` cannot prove the future.** It proves the assets and the baseline
  at the moment it runs; a change made after it is caught by the drift checks in
  the `prepared` re-verification and the resume preconditions, not prevented.
- **The migration latch needs a human.** After a failed migration the tool
  refuses to continue and refuses to roll back an unrecognized schema shape. That
  is intentional: neither build is verified against a half-migrated database, so
  the next step is a decision, not a command.

The offline suite (`bash scripts/nas-maintenance.test.sh`) drives the executor
against command stubs for `systemctl`, `docker` and `curl`. It pins the freeze
order, the digest/revision identity rules, journal validation, the resume
preconditions, the migration latch, frontend readiness, R1's schema gate and
every R1 restore item. It proves the executor's decisions, not the behaviour of
real systemd, PostgreSQL or the registry.
