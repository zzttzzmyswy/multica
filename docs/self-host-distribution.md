# Self-host distribution (zzttzzmyswy/multica)

This repository is a maintained fork of [multica-ai/multica](https://github.com/multica-ai/multica).
It exists because the upstream project deprioritized
[direct-to-object-storage attachment upload](https://github.com/multica-ai/multica/pull/10514),
which this deployment depends on: the public reverse proxy in front of the
backend refuses request bodies above ~8 MB, so a self-hosted install can only
accept large attachments by uploading them straight to object storage.

Everything here is additive to upstream. The fork tracks upstream `main`, keeps
the upstream commit history, and carries the attachment work as ordinary
commits on top.

## What is different from upstream

| Area | Upstream | This distribution |
| --- | --- | --- |
| Attachment upload | Full body through the backend only | Presigned direct upload (backend + CLI + browser), with fallback to the old path |
| Release repository | `multica-ai/multica` | `zzttzzmyswy/multica` — hardcoded, not configurable |
| Release tags | `vX.Y.Z` | `vX.Y.Z-myswy.N` |
| `latest` tag (CLI / images) | Published | **Not published**; deployments pin an exact tag and digest |
| Homebrew | `multica-ai/tap/multica` | No tap. The brew route fails with instructions instead of installing upstream |
| Desktop / mobile installers | Published per release | Not published |
| Helm chart | Pushed to `ghcr.io/multica-ai/charts` | Not published; the in-repo chart consumes the fork's image names |

## Version scheme

Tags look like `v0.9.0-myswy.1`:

- `0.9.0` is the upstream version this build is based on.
- `myswy.N` is this distribution's build number for that upstream version.
  Bump `N` for a fix that changes nothing upstream of it; bump the base version
  when moving onto a newer upstream `main`.

Every distribution tag is a **GitHub prerelease** (it has a suffix), which has
two deliberate consequences:

1. `GET /releases/latest` does not return it. `multica update` therefore
   resolves the target by listing releases and picking the highest
   distribution tag; nothing falls back to upstream.
2. `IsReleaseVersion` reports false for a suffixed version, so the daemon's
   unattended auto-update poller stays off. An unexpected unattended swap is
   worse for a self-hosted deployment than a manual update.

**Update is explicit and pinned.** `multica update --version v0.9.0-myswy.N`
installs exactly that release. `multica update` alone installs the newest
published distribution build. Both verify the archive's SHA-256 against that
release's `checksums.txt` before replacing the binary.

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
- push a Helm chart.

A tag is immutable: `.goreleaser.myswy.yml` sets
`replace_existing_artifacts: false`, so re-running a release for an existing tag
fails rather than swapping the published bytes. If a release is broken partway
through, cut the next build number (`myswy.N+1`).

Upstream's `.github/workflows/release.yml` still exists and still runs its
`verify` job here, but every publishing job in it is guarded by
`github.repository_owner == 'multica-ai'` and skips in this repository. Exactly
one workflow writes CLI assets for a given tag.

## Installing and updating the CLI

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
never installed.

Later updates go through the CLI:

```bash
multica update                          # newest distribution build
multica update --version v0.9.0-myswy.2 # pin exactly
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

`.env` selects the images:

```bash
MULTICA_IMAGE_TAG=v0.9.0-myswy.1
MULTICA_BACKEND_IMAGE=ghcr.io/zzttzzmyswy/multica-backend
MULTICA_WEB_IMAGE=ghcr.io/zzttzzmyswy/multica-web
```

For a deployment that must not drift, pin digests instead of the tag:

```bash
MULTICA_BACKEND_IMAGE=ghcr.io/zzttzzmyswy/multica-backend@sha256:<digest>
MULTICA_WEB_IMAGE=ghcr.io/zzttzzmyswy/multica-web@sha256:<digest>
```

Database migrations apply automatically: the backend image's entrypoint runs
`./migrate up` before starting the server. The direct-upload feature adds
migrations `657`–`660`, which create the upload-session table and its three
concurrent indexes.

## Rolling back

Two independent things can need a rollback, and they are not symmetric.

**Images.** Point `MULTICA_BACKEND_IMAGE` / `MULTICA_WEB_IMAGE` back at the
previous version's digest and restart. This is safe as long as the previous
schema is still compatible — the migrations only add a table and indexes, so an
older backend ignores them.

**Database.** Rolling the schema back means running `./migrate down` to the
previous version, which drops the upload-session table and therefore the record
of any in-flight uploads. Do this only after confirming nothing is uploading,
and take a backup first. In practice the image rollback above is enough: the new
migrations are additive, so an older image runs fine against the newer schema.

**CLI.** `multica update --version <previous tag>` installs the older binary.

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
- `.goreleaser.myswy.yml`, `.github/workflows/release-myswy.yml`
- `.env.example`, `docker-compose.selfhost.yml`, `deploy/helm/multica/values.yaml`
  (image names)
