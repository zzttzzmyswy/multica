# Self-host distribution (zzttzzmyswy/multica)

This repository is a maintained fork of [multica-ai/multica](https://github.com/multica-ai/multica).
It exists because the upstream project deprioritized
[direct-to-object-storage attachment upload](https://github.com/multica-ai/multica/pull/10514),
which this deployment depends on.

Why it is needed: the reverse proxy in front of the backend caps request bodies
well below the backend's own 100 MiB attachment limit, so large attachments
cannot be uploaded through it at all. A multipart upload through a slow link also
measures far below the link's raw rate, and the old path buffers the whole file
in the backend and in the CLI. Direct upload addresses all three.

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
- publish a `latest` tag or a commit-derived `sha-*` tag for either image,
- write any Homebrew tap,
- build Desktop or mobile installers,
- push a Helm chart,
- mark the release as GitHub's "latest" (it is published as a prerelease).

Only the tag shape gets this far. A tag that is not exactly
`v<major>.<minor>.<patch>-myswy.<build>` — a synced upstream `v0.9.0`, or a
look-alike such as `v0.9.0-myswy.1-extra` — fails the `verify` job and publishes
nothing. The workflow and `scripts/myswy-release-guard.sh` both apply that rule,
so a tag rejected by one is rejected by the other.

Order within a run: `verify` (tests, race suite, `govulncheck`) gates everything;
`guard` then refuses the whole run if anything for this version already exists;
the two image builds push **digests only**, which carry no tag and are therefore
harmless to repeat; the merge jobs check their own tag and only then attach it;
the `cli` job checks the release tag and only then runs GoReleaser. Because the
digests are built before the tag check, a first publish from an empty registry is
not blocked by having already built something.

### Published names are immutable

A published artifact is never replaced. Failed jobs from the same run may
publish artifacts that are still missing; they refuse to overwrite an existing
release or image tag. A fresh run refuses a version if any artifact already
exists. To change a partially published release, cut the next build number
(`myswy.N+1`). The protection has two layers, and both are needed.

**Only the version tag is published.** Each image gets exactly one tag, the
frozen `vX.Y.Z-myswy.N`, plus the content digest the build produced. No `latest`
and no commit-derived `sha-*` tag: a second name for the same bytes is a second
name a later build could repoint, and a deployment pins the version tag and its
digest.

**Every writing job checks before it writes.** `scripts/myswy-release-guard.sh`
runs in three roles:

| Role | Invocation | Question it answers |
| --- | --- | --- |
| Pre-flight | `--scope all` (the `guard` job) | Is anything for this version already published? If so, refuse the whole run before spending build minutes. |
| Release writer | `--scope release` (the `cli` job) | Is this release tag already published? |
| Image writer | `--scope image --image <name>` (each merge job, inside the pushing step) | Is *this* image tag already published? |

The scoped forms exist because of how a partial rerun works. GitHub keeps the
stored result of jobs that were not re-run, so after "Re-run failed jobs" a
`needs: guard` edge replays the first attempt's success — it does not re-decide
anything. The check that protects a write therefore has to live inside the job
that writes, and the writer checks only its own artifact: during one healthy run
the artifacts finish at different times, and a writer that refused because a
sibling had already published would break a release that is going fine.
`scripts/myswy-release-workflow.test.mjs` replays exactly that sequence against a
local stub and asserts zero writes to an existing target on the rerun, while
allowing a missing target to be published without changing its siblings.

**Absence has to be proved, not assumed.** The guard asks the release API and
the registry over HTTP with explicit credentials (`GHCR_USERNAME`/`GHCR_TOKEN`
from `GITHUB_TOKEN` in the workflow). It treats a lookup as "free to publish"
only on a positive answer:

| Answer | Verdict |
| --- | --- |
| `404` + `MANIFEST_UNKNOWN` on the manifest, or `404` + `NAME_UNKNOWN` on the tag list | absent — may publish |
| `200` | present — refuse |
| `401` / `403` | refuse: a credential problem is not evidence of absence |
| `5xx`, transport error, missing `curl`/`jq` | refuse |
| `404` with no OCI error code | refuse: something answered "not found" without saying why |

An anonymous lookup cannot make this distinction, which is why credentials are
mandatory rather than a fallback. Observed against `ghcr.io` directly:

```
# package that does not exist yet, no credentials
GET /token?service=ghcr.io&scope=repository:zzttzzmyswy/multica-backend:pull
  -> 403 {"errors":[{"code":"DENIED","message":"requested access to the resource is denied"}]}

# same request with credentials
  -> 200 {"token":"..."}
GET /v2/zzttzzmyswy/multica-backend/tags/list?n=1   -> 404 NAME_UNKNOWN
GET /v2/zzttzzmyswy/multica-backend/manifests/<tag> -> 404 MANIFEST_UNKNOWN

# existing package, tag that does not exist
GET /v2/multica-ai/multica-backend/manifests/does-not-exist -> 404 MANIFEST_UNKNOWN
# existing package, existing tag
GET /v2/multica-ai/multica-backend/manifests/latest        -> 200
```

The registry `/v2` API is what the guard reads, not the GitHub REST package API
(`/users/{owner}/packages/container/{name}`): that endpoint needs `read:packages`,
which `GITHUB_TOKEN` does not carry, and it answers `403` for a package it may
not inspect — a second way to confuse "not allowed" with "not there". It is not
used.

Scope of the credentials: `GITHUB_TOKEN` is what the workflow passes, and the
repository's `packages: write` permission is what makes it usable for both the
token request and the push (it is the same credential `docker/login-action`
already logs in with). A classic PAT with `read:packages` also works for the
check and needs no `packages:write`. Both are read-only uses of the credential.

**Not yet exercised on a real tag push.** The registry behaviour above was
measured against `ghcr.io` with a real credential, and the workflow is tested
against a local stub that reproduces those exact answers. What has *not* run is
this workflow publishing `v0.9.0-myswy.1`: no tag has been pushed, so the
`GITHUB_TOKEN` token grant inside Actions is by contract, not by observation.
The first real release is where that gap closes.

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

A digest is the only immutable pin. This workflow publishes each version tag
once and refuses to re-publish it, so a tag here should never move — but a pin
that is meant to be immune to any future mistake should still be a digest. Put
the two
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

A deployment running an older build has to cross every migration between its
`schema_migrations` version and this branch's head, not just the migrations this
feature adds. Check the starting point rather than assuming it:

```bash
docker compose -f docker-compose.selfhost.yml exec postgres \
  psql -U multica -d multica -c 'select max(version) from schema_migrations'
```

- Many of those migrations create indexes with `CREATE INDEX CONCURRENTLY`.
  Each concurrent build runs outside a transaction and leaves an INVALID index
  if interrupted; the runner has a per-version cleanup hook, but it means an
  interrupted upgrade needs a re-run rather than a manual repair.
- Migrations `657`–`660` are the only ones this feature introduces (one table,
  three concurrent indexes). They are additive. They are not the risk; the
  migrations between an older deployment and them are.
- A concurrent index build needs free space on the filesystem that holds
  PostgreSQL's data directory — measured there, not on `/`, which can be a
  separate and much larger or smaller volume. Check the mount Docker actually
  uses before starting:

  ```bash
  docker info --format '{{.DockerRootDir}}'
  df -h "$(docker info --format '{{.DockerRootDir}}')"
  ```

  If PostgreSQL runs outside Docker, check the data directory's own filesystem
  instead. A failed build is worse than a slow one.

**Before any upgrade:**

1. Take a verified database backup and confirm it restores into a scratch
   database. An untested backup is not a backup.
2. Rehearse the whole upgrade on an isolated copy: restore the backup, run
   `migrate up` to head, start the new backend, and exercise the feature.
3. Decide the client story: daemons whose updater still points at the upstream
   release API will keep auto-updating to upstream builds unless it is repointed
   or disabled (see below).

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
