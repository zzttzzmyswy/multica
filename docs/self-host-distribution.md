# Self-host distribution (zzttzzmyswy/multica)

This repository is a maintained fork of [multica-ai/multica](https://github.com/multica-ai/multica).
It exists because the upstream project deprioritized
[direct-to-object-storage attachment upload](https://github.com/multica-ai/multica/pull/10514),
which this deployment depends on.

Why it is needed, measured on the actual deployment (2026-11-14, NAS read-only
inventory): the public reverse proxy in front of the backend accepts request
bodies up to **50 MiB** (`client_max_body_size 50m`; 52,428,800 bytes reached the
backend, 52,428,801 was rejected with 413). The backend also hardcodes a 100 MiB
attachment cap, so attachments between 50 MiB and 100 MiB cannot be uploaded at
all through the proxy. Two further costs are independent of that ceiling: a
multipart upload through a slow link measured far below the link's raw rate, and
the old path buffers the whole file in the backend and in the CLI.

> Historical note: an earlier report in this project described the proxy limit as
> 8–10 MiB. The current measurement above is 50 MiB. The older figure could not be
> reproduced and is not used as a justification anywhere in this document; the
> feature is needed for the 50–100 MiB gap, the slow-link behavior, and the
> memory cost.

Everything here is additive to upstream. The fork tracks upstream `main`, keeps
the upstream commit history, and carries the attachment work as ordinary
commits on top.

## What is different from upstream

| Area | Upstream | This distribution |
| --- | --- | --- |
| Attachment upload | Full body through the backend only | Presigned direct upload (backend + CLI + browser), with fallback to the old path |
| Release repository | `multica-ai/multica` | `zzttzzmyswy/multica` — hardcoded, not configurable |
| Release tags | `vX.Y.Z` | `vX.Y.Z-myswy.N` |
| `latest` tag (CLI / images) | Published | **Not published**; deployments pin an exact tag, ideally by digest |
| Homebrew | `multica-ai/tap/multica` | No tap. The brew route fails with instructions instead of installing upstream |
| Desktop / mobile installers | Published per release | Not published |
| Helm chart | Pushed to `ghcr.io/multica-ai/charts` | Not published; the in-repo chart consumes the fork's image names |

## Version scheme

Tags look like `v0.9.0-myswy.1`:

- `0.9.0` is the upstream version this build is based on.
- `myswy.N` is this distribution's build number for that upstream version.
  Bump `N` for a fix that changes nothing upstream of it; bump the base version
  when moving onto a newer upstream `main`.

Every distribution tag is published as a **GitHub prerelease** and is explicitly
excluded from GitHub's "latest release" pointer. Both are set explicitly in
`.goreleaser.myswy.yml` (`prerelease: true`, `make_latest: "false"`) rather than
inferred from the tag shape, because GoReleaser's defaults are
`prerelease: false` and `make_latest: true` and a `-myswy.N` suffix alone does not
change them. Two consequences:

1. `GET /releases/latest` returns 404 for this repository. `multica update`
   therefore reads the **release list** and selects the newest distribution tag
   that has an archive for the current platform; nothing falls back to upstream.
2. `IsReleaseVersion` reports false for a suffixed version, so the daemon's
   unattended auto-update poller stays off. An unexpected unattended swap is
   worse for a self-hosted deployment than a manual update.

**Update is explicit.** `multica update --version v0.9.0-myswy.N` installs
exactly that release and is the recommended form. `multica update` alone installs
the newest published distribution build. Both verify the archive's SHA-256
against that release's `checksums.txt` before replacing the binary.

## Publishing a release

Publishing is done by the repository owner; this section documents the contract
the code depends on.

1. Merge to `main` through a pull request. Never tag an unmerged branch.
2. Choose the version and create the tag:
   ```bash
   git tag v0.9.0-myswy.1
   git push origin v0.9.0-myswy.1
   ```
3. `.github/workflows/release-myswy.yml` runs on the tag push and publishes:
   - `ghcr.io/zzttzzmyswy/multica-backend:v0.9.0-myswy.1`
   - `ghcr.io/zzttzzmyswy/multica-web:v0.9.0-myswy.1`
   - GitHub release `v0.9.0-myswy.1` with CLI archives
     (`multica-cli-<version>-<os>-<arch>.tar.gz` plus the legacy
     `multica_<os>_<arch>.tar.gz`) and `checksums.txt`
4. Record the image **digests** from the image-merge job output. Deployment
   pins digests, not tags.

The workflow will not:
- publish a `latest` tag for either image,
- write any Homebrew tap,
- build Desktop or mobile installers,
- push a Helm chart,
- mark the release as GitHub's "latest" (it is published as a prerelease).

**Nothing is overwritten.** Before any publish job starts, the `guard` job runs
`scripts/myswy-release-guard.sh`, which checks whether the release or either
image tag already exists and refuses the whole run if so. A failed or
unauthorized lookup (403, 5xx, network) is *not* treated as "the tag is free":
only an explicit 404 counts as absent, because an unverified overwrite is the
failure this guards against.

This gate exists because `replace_existing_artifacts: false` only protects the
GitHub release's archives — it protects nothing in GHCR, and without the guard
the image jobs wrote their tag unconditionally, so a rerun could replace the
digest a deployment was pinned to. If a release is broken partway through, cut
the next build number (`myswy.N+1`); do not re-run the tag.

Upstream's `.github/workflows/release.yml` still exists here, but every job in it
(including its gate) is guarded by `github.repository_owner == 'multica-ai'` and
skips in this repository, so exactly one workflow publishes for a given tag.

## Installing and updating the CLI

Requirements: `curl`, `tar`, and **`python3`**. The installer parses the GitHub
releases JSON with python3 and refuses to start without it — a hand-rolled text
parser cannot be used here, because the response nests objects (`uploader`,
`author`, `reactions`) and the order of `assets` is not fixed.

```bash
# Newest published distribution build
curl -fsSL https://raw.githubusercontent.com/zzttzzmyswy/multica/main/scripts/install-myswy.sh | bash

# One exact version (also the rollback path)
curl -fsSL https://raw.githubusercontent.com/zzttzzmyswy/multica/main/scripts/install-myswy.sh \
  | bash -s -- --version v0.9.0-myswy.1

# Report installed vs available without changing anything
bash scripts/install-myswy.sh --check
```

The installer refuses to install anything it cannot verify: a missing
`checksums.txt`, a missing entry for the archive, or a digest mismatch all abort
before the binary is moved into place. It only ever considers tags carrying the
`-myswy.` suffix, so an upstream tag that happens to exist in this repository is
never installed. When selecting the newest build it skips releases that have no
archive for the current platform, and it is unaffected by the order of a
release's assets.

Later updates go through the CLI:

```bash
multica update --version v0.9.0-myswy.2 # recommended: pin exactly
multica update                          # newest published distribution build
```

`multica update` never consults `multica-ai/multica` and never runs
`brew upgrade multica-ai/tap/multica`. A build installed through Homebrew is
told to reinstall from the release archives, because there is no tap of this
distribution's own to upgrade through.

### Mirrors

Two environment variables redirect the *host* while keeping the repository in
the path:

```bash
export MULTICA_RELEASE_API_BASE_URL=https://mirror.example/api
export MULTICA_RELEASE_DOWNLOAD_BASE_URL=https://mirror.example/releases/download
```

Both the archive and `checksums.txt` are fetched through the same base, so a
mirrored install still verifies against the manifest for the same release.

## Deploying the server

`.env` selects the images by tag:

```bash
MULTICA_IMAGE_TAG=v0.9.0-myswy.1
MULTICA_BACKEND_IMAGE=ghcr.io/zzttzzmyswy/multica-backend
MULTICA_WEB_IMAGE=ghcr.io/zzttzzmyswy/multica-web
```

A digest is the only immutable pin — a tag can be re-pushed. Put the two
**complete** references in the digest override and start through it:

```bash
export MULTICA_BACKEND_DIGEST=ghcr.io/zzttzzmyswy/multica-backend@sha256:<64 hex>
export MULTICA_WEB_DIGEST=ghcr.io/zzttzzmyswy/multica-web@sha256:<64 hex>

docker compose -f docker-compose.selfhost.yml \
               -f docker-compose.selfhost.digest.yml up -d
# or
make selfhost-digest
```

The separate override file exists because Compose interpolation cannot test
whether a value already carries a `@digest` or a `:tag`, so the base file's
`${..._IMAGE}:${..._TAG}` appended a tag to a digest
(`...@sha256:<digest>:v0.9.0-myswy.1`) — an invalid reference format that made
digest pinning impossible to express. The override sets the whole reference
instead, and fails the render if either digest is unset rather than falling back
to a tag silently. `scripts/selfhost-config.test.sh` renders both paths and
checks the reference shape.

Obtain a digest from the release run's image-merge job, or:

```bash
docker buildx imagetools inspect \
  ghcr.io/zzttzzmyswy/multica-backend:v0.9.0-myswy.1 --format '{{json .Manifest}}'
```

Database migrations apply automatically: the backend image's entrypoint runs
`./migrate up` before starting the server.

## Upgrading an existing deployment: not a drop-in

The current production deployment is **v0.8.1 with `schema_migrations` at 616**
(NAS read-only inventory, 2026-11-14). This distribution's feature branch ends at
**660**. That gap is the whole upgrade, not just the four migrations this feature
adds:

- **44 forward migrations (−617 … 660),** of which **28 create an index with
  `CREATE INDEX CONCURRENTLY`.** Each concurrent build runs outside a
  transaction and leaves an INVALID index if interrupted; the runner has a
  per-version cleanup hook for that, but it means an interrupted upgrade needs a
  re-run rather than a manual repair.
- Migrations `657`–`660` are the only ones this feature introduces (one table,
  three concurrent indexes). They are additive, but they are not the risk; the
  other 40 are.
- The NAS host had ~1 GB free on `/` at inventory time. A concurrent index build
  on a 2 GB database needs headroom, and a failed build is worse than a slow one.

**Before any upgrade:**

1. Take a verified database backup (the inventory found backups had stopped
   7 days earlier) and confirm it restores into a scratch database.
2. Rehearse the whole upgrade on an isolated copy: restore the backup, run
   `migrate up` to 660, start the new backend, and exercise the feature.
3. Decide the client story: daemons running an upstream CLI will keep
   auto-updating to upstream unless their updater is repointed (see below).

## Rolling back

Two independent things can need a rollback, and they are **not symmetric**. The
one-line summary: reverting the image is cheap, reverting the schema is not, and
neither has been exercised end-to-end yet.

**Images.** Point the deployment back at the previous digests and restart. This
is *not* verified to be sufficient. It is plausible only because migrations are
additive, and "the old binary tolerates the newer schema" is an assumption that
must be tested against a restored copy of the real database, not assumed from the
migration files.

**Database.** `./migrate down` to an earlier version drops whatever those
migrations created. For `657`–`660` that drops the upload-session table and
therefore the record of any in-flight upload; for the 40 earlier migrations it is
a much larger and less reviewed change. Do not treat `migrate down` as a
rollback plan until it has been rehearsed on a restored copy:

- take a backup first,
- confirm nothing is uploading,
- rehearse the down-migration *and* the subsequent up-migration on the copy,
- and prefer restoring the pre-upgrade backup over migrating backwards.

**CLI.** `multica update --version <previous tag>` installs the older binary. Note
that on a host whose CLI is upgraded by a script pinned to the upstream release
API, an external timer can replace it again — repoint or disable that timer.

**Status: all three rollout/rollback paths are unverified on the real deployment.**
Nothing in this document should be read as a tested rollback guarantee.

## Updating from upstream

```bash
git fetch upstream
git checkout -b sync-upstream-<date> upstream/main
git cherry-pick <the attachment commits>   # or merge, then resolve
```

The attachment work touches: `server/internal/{storage,handler,service,cli}`,
`server/cmd/{server,multica}`, `server/migrations/657-660`, `server/pkg/db/*`,
`packages/core/api/*`, `scripts/direct-upload-*`, and `e2e/`.

After a sync, re-run the checks listed in the pull request that delivered it.
Conflict resolutions must keep the storage-side conditional copy in
`server/internal/storage/s3_upload.go`: the guarantee that a client cannot
overwrite a published object comes from that condition, not from application
logic.

Distribution-specific files that intentionally do **not** track upstream and
should survive a sync:
- `server/internal/cli/update.go` — `ReleaseRepository` and `BrewFormulaName`
- `scripts/install-myswy.sh`, `scripts/myswy-*.{sh,py}`
- `scripts/selfhost-config.test.sh`, `scripts/helm-config.test.sh` (they assert the
  digest/tag rendering above)
- `.goreleaser.myswy.yml`, `.github/workflows/release-myswy.yml`
- `.env.example`, `docker-compose.selfhost.yml`,
  `docker-compose.selfhost.digest.yml`, `deploy/helm/multica/{values,Chart}.yaml`
  (image names and the pinned `appVersion`)
