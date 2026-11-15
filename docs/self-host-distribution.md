# Self-host distribution (zzttzzmyswy/multica)

A maintained fork of [multica-ai/multica](https://github.com/multica-ai/multica)
that adds direct-to-object-storage attachment upload. It exists because the
reverse proxy in front of the backend caps request bodies below the backend's own
100 MiB attachment limit, so large attachments cannot be uploaded through it.

This document is the **contract** an operator or a maintainer needs: what the
distribution publishes, where it is consumed, and what must hold when syncing
upstream. The upload feature's own behaviour is documented in
`SELF_HOSTING_ADVANCED.md` and `apps/docs/content/docs/environment-variables.mdx`
(next to the code that implements it); this file does not repeat it.

## Boundary: two patch sets, never mixed

Keep the two sets in separate commits, and in separate branches when syncing.

| Patch set | Content | Ships in |
| --- | --- | --- |
| **Upload feature** | presign → PUT → complete endpoints, upload-session table and reconciler, storage-side conditional copy, CLI and browser clients, the tests and smoke scripts that cover them | both the fork **and** the upstream candidate |
| **Distribution** | release workflow and GoReleaser config, pinned update source, installer, image namespace and digest override, Helm defaults, this document | fork only |

The upstream candidate must never contain a distribution file, and a distribution
file must never contain a fork-only reference. `git diff` between the two
branches states which is which; the upload feature is the only content they
share.

## Version scheme and published assets

Tags are `v<upstream>.<patch>-myswy.<N>` — for example `v0.9.0-myswy.2`, where
`0.9.0` is the upstream version the build is based on and `myswy.N` counts this
distribution's builds on that base.

A tag of exactly that shape triggers `.github/workflows/release-myswy.yml`, which
publishes:

- `ghcr.io/zzttzzmyswy/multica-backend:vX.Y.Z-myswy.N` and
  `ghcr.io/zzttzzmyswy/multica-web:vX.Y.Z-myswy.N` (multi-arch manifest lists),
- a GitHub **prerelease** carrying `multica-cli-<version>-<os>-<arch>.tar.gz`
  (plus the legacy `multica_<os>_<arch>.tar.gz` name) and `checksums.txt`.

Nothing else is published: no `latest` tag, no `sha-*` image tag, no Homebrew
tap, no Desktop or mobile installers, no Helm chart. Upstream's own
`release.yml` guards every job with `github.repository_owner == 'multica-ai'`, so
exactly one workflow publishes for a given tag.

Because every release is a prerelease, `GET /releases/latest` returns 404 for this
repository. That is deliberate: `multica update` reads the release **list** and
picks the newest distribution tag that has an archive for the current platform,
and the daemon's unattended auto-update poller stays off for a suffixed version.

### Published names are immutable

A published artifact is never replaced. Two layers enforce this, and both are
needed because GitHub keeps a skipped job's stored success on "Re-run failed
jobs":

- `scripts/myswy-release-guard.sh` refuses a version if any artifact already
  exists, in three scopes — `all` (pre-flight, before spending build minutes),
  `release` (the GoReleaser job), and `image --image <name>` (inside each
  pushing step, so a partial rerun publishes only what is still missing).
- The guard treats a lookup as "free to publish" only on a positive answer:
  `404` **with** `MANIFEST_UNKNOWN`/`NAME_UNKNOWN` means absent; `200` means
  present; `401`, `403`, `5xx`, a transport error, or a bare `404` with no OCI
  error code all refuse. An anonymous lookup cannot make that distinction, which
  is why credentials are mandatory rather than a fallback.

To change a partially published release, cut the next build number. Never move an
existing tag and never overwrite an asset.

## Consuming a release

```bash
# Newest published build
curl -fsSL https://raw.githubusercontent.com/zzttzzmyswy/multica/main/scripts/install-myswy.sh | bash

# One exact version (also the rollback path)
curl -fsSL https://raw.githubusercontent.com/zzttzzmyswy/multica/main/scripts/install-myswy.sh \
  | bash -s -- --version v0.9.0-myswy.2

# Report installed vs available, change nothing
bash scripts/install-myswy.sh --check
```

The installer needs `curl`, `tar` and **`python3`** (the releases JSON nests
objects and its asset order is not fixed, so it is parsed, not grepped). It
refuses anything it cannot verify — a missing `checksums.txt`, a missing entry
for the archive, or a digest mismatch all abort before the binary is replaced —
and it only ever considers `-myswy.` tags, so an upstream tag present in this
repository is never installed.

Later updates go through the CLI:

```bash
multica update --version v0.9.0-myswy.2   # recommended: pin exactly
multica update                            # newest published build
```

`server/internal/cli/update.go` hardcodes `ReleaseRepository`; neither form ever
consults `multica-ai/multica` or runs `brew upgrade multica-ai/tap/multica`. A
Homebrew-installed binary is told to reinstall from the release archives, since
there is no tap of this distribution's own. `MULTICA_RELEASE_API_BASE_URL` and
`MULTICA_RELEASE_DOWNLOAD_BASE_URL` rewrite only the host of a mirror, so both
the archive and its `checksums.txt` come from the same place.

## Deploying the server

`.env` selects the images by tag; the checked-in default names a published build:

```bash
MULTICA_IMAGE_TAG=v0.9.0-myswy.2
MULTICA_BACKEND_IMAGE=ghcr.io/zzttzzmyswy/multica-backend
MULTICA_WEB_IMAGE=ghcr.io/zzttzzmyswy/multica-web
```

Set that to whatever a successful release run actually published — a default
naming a build with no image fails at pull time.

A digest is the only immutable pin. Put two **complete** references in the
override and start through it:

```bash
export MULTICA_BACKEND_DIGEST=ghcr.io/zzttzzmyswy/multica-backend@sha256:<64 hex>
export MULTICA_WEB_DIGEST=ghcr.io/zzttzzmyswy/multica-web@sha256:<64 hex>
make selfhost-digest
```

The separate override file exists because Compose interpolation cannot test
whether a value already carries an `@digest` or a `:tag`, so the base file's
`${..._IMAGE}:${..._TAG}` would append a tag to a digest. The override sets whole
references and fails the render if either is unset rather than silently falling
back to a tag. `scripts/selfhost-config.test.sh` renders both paths and
`scripts/helm-config.test.sh` does the same for the chart, which pins
`appVersion` to a real release because this distribution publishes no `latest`.

Database migrations run automatically: the backend image's entrypoint executes
`./migrate up` before starting the server.

### Operator checks before an upgrade

A deployment crosses every migration between its `schema_migrations` version and
the target's head, not just the ones this feature adds. Check the starting point
rather than assuming it:

```bash
docker compose -f docker-compose.selfhost.yml exec postgres \
  psql -U multica -d multica -c 'select max(version) from schema_migrations'
```

Concurrent index builds need free space on the filesystem that holds
PostgreSQL's data directory — measured there, not on `/`:

```bash
docker info --format '{{.DockerRootDir}}'
df -h "$(docker info --format '{{.DockerRootDir}}')"
```

An interrupted concurrent build leaves an INVALID index; the runner's per-version
cleanup hook means a re-run repairs it, not a manual rebuild. Take a backup that
has been restored into a scratch database before upgrading, and prefer restoring
that backup over migrating backwards: `migrate down` over this feature's
migrations drops the upload-session table and the record of any in-flight upload.

**No rollout or rollback path in this document is a tested guarantee for any
specific deployment.** Whether the previous binary tolerates a newer schema is an
assumption to be checked against a restored copy of the real database.

## Syncing upstream

```bash
git fetch upstream --tags
git checkout -b sync-upstream-<date> <upstream-release-tag>
git cherry-pick <upload-feature commits>     # from the upstream candidate branch
```

Sync from a **formal upstream release tag**, not from upstream `main`: the
distribution's version number names the upstream version it is based on, and
`main` moves between releases. Then:

1. **Migrations.** Renumber the upload migrations to follow upstream's highest.
   Update `concurrentIndexCleanups` in `server/cmd/migrate/main.go` in the same
   commit — `TestEveryConcurrentUpBuildHasCleanup` fails otherwise. The versions
   already deployed on any live fork database are frozen: they were applied under
   those numbers, and a renumbering would re-run or skip them.
2. **Storage guarantee.** A conflict resolution must keep the conditional copy in
   `server/internal/storage/s3_upload.go`. The guarantee that a client cannot
   overwrite a published object comes from that `If-Match` condition, not from
   application logic.
3. **Verification.** Re-run the commands in `docs/upload-patch-contract.md`.

### Files that intentionally do not track upstream

These carry distribution behaviour and should survive a sync:

- `server/internal/cli/update.go` — `ReleaseRepository`, `BrewFormulaName`
- `scripts/install-myswy.sh`, `scripts/myswy-*`
- `scripts/selfhost-config.test.sh`, `scripts/helm-config.test.sh`
- `.goreleaser.myswy.yml`, `.github/workflows/release-myswy.yml`
- `.env.example`, `docker-compose.selfhost.yml`,
  `docker-compose.selfhost.digest.yml`, `deploy/helm/multica/{values,Chart}.yaml`
- `docs/self-host-distribution.md`, `docs/upload-patch-contract.md`
