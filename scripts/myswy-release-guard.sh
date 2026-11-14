#!/usr/bin/env bash
# Refuse to publish a distribution release over assets that already exist.
#
# Why this exists: GoReleaser's `replace_existing_artifacts: false` protects the
# GitHub release's CLI archives, but it protects nothing in GHCR. The image jobs
# in release-myswy.yml wrote the tag with `docker buildx imagetools create`, so a
# rerun could repoint an already published tag to a different image. Digest pins
# remain immutable, but deployments resolving that tag would get different bytes.
#
# One rule: if the artifact a job is about to write already exists, that job
# publishes nothing. Failed jobs may fill missing artifacts from the same run;
# changing published artifacts requires the next build number (myswy.N+1).
#
# Two scopes, because the two checks answer different questions:
#
#   --scope all      The pre-flight gate: if the release OR either image tag
#                    exists, the whole release is refused. Correct before the
#                    first write of a run, and wrong inside a writer — during one
#                    run the artifacts finish at different times, so "some other
#                    artifact already exists" is the normal case, not a conflict.
#   --scope release  This job writes the GitHub release; check only that tag.
#   --scope image    This job writes one image tag; check only that tag.
#
# The scoped forms exist so every job that writes a tag can re-check, inside
# itself, immediately before its write. A `needs: guard` edge does not survive a
# rerun: GitHub reuses the stored result of jobs that were not re-run, so the
# pre-flight gate's verdict from the first attempt is not re-evaluated when a
# single writer is re-run.
#
# The distinction that matters: "the thing does not exist" and "I could not find
# out" must not look the same. A 401/403, a 5xx, a network failure, or a missing
# tool is NOT evidence that a tag is free; treating it as free is how an
# unverified overwrite happens. Only a positive "not there" answer counts, and it
# has to come from a real registry response that names the reason.
#
# Usage:
#   bash scripts/myswy-release-guard.sh --tag v0.9.0-myswy.1
#   bash scripts/myswy-release-guard.sh --tag v0.9.0-myswy.1 --scope release
#   bash scripts/myswy-release-guard.sh --tag v0.9.0-myswy.1 --scope image --image multica-backend
#
# Environment:
#   GITHUB_REPOSITORY   owner/name that will receive the release (default: this fork)
#   GITHUB_TOKEN        token for the release API
#   GHCR_USERNAME       registry user; required by --scope all and --scope image
#   GHCR_TOKEN          registry token; required by --scope all and --scope image
#   REGISTRY            registry host in image references (default: ghcr.io)
#   REGISTRY_API_BASE   override the /v2 API host (tests only; default https://$REGISTRY)
#   REGISTRY_TOKEN_URL  override the token endpoint (tests only; default https://$REGISTRY/token)
set -uo pipefail

REPOSITORY="${GITHUB_REPOSITORY:-zzttzzmyswy/multica}"
# The only repository this distribution may publish from.
DISTRIBUTION_REPOSITORY="zzttzzmyswy/multica"
# The only tag shape this distribution may publish. Anchored and exact: a
# trailing suffix (`v0.9.0-myswy.1-extra`) is not this build number, and letting
# it through publishes under a name no updater looks for.
TAG_PATTERN='^v[0-9]+\.[0-9]+\.[0-9]+-myswy\.[0-9]+$'
DISTRIBUTION_IMAGES=(multica-backend multica-web)

API_BASE="${GITHUB_API_URL:-https://api.github.com}"
REGISTRY="${REGISTRY:-ghcr.io}"
REGISTRY_API_BASE="${REGISTRY_API_BASE:-https://${REGISTRY}}"
REGISTRY_TOKEN_URL="${REGISTRY_TOKEN_URL:-https://${REGISTRY}/token}"
# Manifest media types a multi-arch index can be served as. Sent on every
# manifest read so a present tag is never answered with a 404 the registry would
# only have returned for an unacceptable Accept header.
MANIFEST_ACCEPT='application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json'

TAG=""
SCOPE="all"
IMAGE=""
STATE=""

fail() { printf '✗ %s\n' "$*" >&2; exit 1; }
info() { printf '==> %s\n' "$*"; }
ok()   { printf '✓ %s\n' "$*"; }

usage() {
  echo "usage: $0 --tag vX.Y.Z-myswy.N [--scope all|release|image [--image NAME]] [--repository owner/name]" >&2
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --tag) TAG="${2:-}"; shift 2 ;;
    --repository) REPOSITORY="${2:-}"; shift 2 ;;
    --scope) SCOPE="${2:-}"; shift 2 ;;
    --image) IMAGE="${2:-}"; shift 2 ;;
    -h | --help) usage ;;
    *) usage ;;
  esac
done

[ -n "$TAG" ] || usage

# ---------------------------------------------------------------------------
# Inputs

# Tools first: everything below depends on them, and a missing one has to be
# reported as a missing tool rather than as a mysterious failure further down.
command -v curl >/dev/null 2>&1 || fail "curl is required to check the release and registry; refusing to publish blind"
command -v jq >/dev/null 2>&1 || fail "jq is required to parse the registry token response; refusing to publish blind"

# Only this repository and this exact version shape may publish. A synced
# upstream tag (`v0.9.0`) must never trigger a distribution release: it would
# publish images whose artifacts the updater refuses, under a name that looks
# official.
if [[ ! "$TAG" =~ $TAG_PATTERN ]]; then
  fail "refusing to publish '$TAG': release tags must match ${TAG_PATTERN} exactly"
fi
# The owner is pinned, not just the repository name: ghcr.io/multica-ai/... is a
# real namespace, and a typo there would publish this distribution's images into
# the upstream project's registry.
if [ "$REPOSITORY" != "$DISTRIBUTION_REPOSITORY" ]; then
  fail "refusing to publish from '$REPOSITORY': this distribution publishes only from '${DISTRIBUTION_REPOSITORY}'"
fi

case "$SCOPE" in
  all | release) ;;
  image) [ -n "$IMAGE" ] || usage ;;
  *) usage ;;
esac
if [ "$SCOPE" = image ]; then
  case " ${DISTRIBUTION_IMAGES[*]} " in
    *" $IMAGE "*) ;;
    *) fail "refusing to check unknown image '$IMAGE': this distribution publishes ${DISTRIBUTION_IMAGES[*]}" ;;
  esac
fi

if [ "$SCOPE" != image ] && [ -z "${GITHUB_TOKEN:-}" ]; then
  fail "GITHUB_TOKEN is required to check whether the release already exists"
fi
if [ "$SCOPE" != release ]; then
  # An unauthenticated GHCR lookup is not a weaker check, it is a wrong one: for
  # a package that does not exist yet the anonymous token endpoint answers 403
  # DENIED, which reads as "cannot tell" at best and as "absent" in the version
  # of this script that treated any failure as absence. Demanding credentials
  # here is what makes the first publish checkable at all.
  if [ -z "${GHCR_USERNAME:-}" ] || [ -z "${GHCR_TOKEN:-}" ]; then
    fail "GHCR_USERNAME and GHCR_TOKEN are required to check whether an image tag exists;
  an unauthenticated registry lookup cannot distinguish 'not published yet' from 'not allowed to look'"
  fi
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/myswy-release-guard.XXXXXX")" || exit 1
trap 'rm -rf "$WORK"' EXIT
BODY="$WORK/body"

# ---------------------------------------------------------------------------
# GitHub release

# Returns 0 when the release exists, 1 when it definitively does not, and dies on
# anything inconclusive.
release_exists() {
  local code
  code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 \
    -H "Authorization: Bearer ${GITHUB_TOKEN:-}" \
    -H 'Accept: application/vnd.github+json' \
    -H 'X-GitHub-Api-Version: 2022-11-28' \
    "${API_BASE}/repos/${REPOSITORY}/releases/tags/${TAG}" 2>/dev/null)" || {
    fail "could not reach ${API_BASE} to check whether ${TAG} exists; refusing to publish blind"
  }

  case "$code" in
    200) return 0 ;;
    404) return 1 ;;
    401 | 403)
      fail "release lookup for ${TAG} was refused (HTTP ${code}); a permission problem is not evidence that the tag is free"
      ;;
    *)
      fail "release lookup for ${TAG} returned HTTP ${code}; refusing to publish on an inconclusive answer"
      ;;
  esac
}

check_release() {
  info "Checking whether ${REPOSITORY}@${TAG} was already published"
  if release_exists; then
    fail "release ${TAG} already exists in ${REPOSITORY}.
  Published bytes are what an installed CLI verified against its checksum, so
  they are never replaced. Cut the next build number (myswy.N+1) and tag again."
  fi
  ok "no release ${TAG} exists"
}

# ---------------------------------------------------------------------------
# GHCR

# Fetches a pull token for one repository into $TOKEN. Basic auth is explicit:
# the token endpoint is the only place GHCR accepts credentials, and it answers
# 403 DENIED for a package that does not exist when the request is anonymous.
#
# Sets a global rather than printing the token, so that a failure here exits the
# script. A `fail` inside `$(...)` would only end the substitution, and the
# caller would carry on with an empty token.
registry_token() {
  local repository=$1 code
  TOKEN=""
  code="$(curl -sS -o "$BODY" -w '%{http_code}' --max-time 20 \
    -u "${GHCR_USERNAME}:${GHCR_TOKEN}" \
    "${REGISTRY_TOKEN_URL}?service=${REGISTRY}&scope=repository:${repository}:pull" 2>/dev/null)" || {
    fail "could not reach ${REGISTRY_TOKEN_URL} for ${repository}; refusing to publish blind"
  }
  case "$code" in
    200) ;;
    401 | 403)
      fail "registry authentication for ${repository} was refused (HTTP ${code}).
  A credential problem is not evidence that the tag is free; check GHCR_USERNAME,
  GHCR_TOKEN and that the token carries packages:read."
      ;;
    *)
      fail "registry token request for ${repository} returned HTTP ${code}; refusing to publish on an inconclusive answer"
      ;;
  esac
  TOKEN="$(jq -er '.token // empty' "$BODY" 2>/dev/null)" || true
  [ -n "$TOKEN" ] || fail "registry token response for ${repository} carried no token; refusing to publish blind"
}

# GET a registry endpoint; sets $HTTP_CODE and $BODY, dies on a transport error.
# The status is captured first and assigned outside the substitution, so that a
# `fail` in the assignment-recovery branch cannot be swallowed by a subshell.
registry_get() {
  local token=$1 url=$2 code
  code="$(curl -sS -o "$BODY" -w '%{http_code}' --max-time 20 \
    -H "Authorization: Bearer ${token}" \
    -H "Accept: ${MANIFEST_ACCEPT}" \
    "$url" 2>/dev/null)" || {
    fail "could not reach ${url}; refusing to publish blind"
  }
  HTTP_CODE="$code"
}

# Sets $STATE to one of:
#   present          the tag exists
#   tag-absent       the package exists and does not carry this tag
#   package-absent   no package exists for this image at all
# Any other answer dies. The two absence states are kept apart because they mean
# different things to an operator on a first publish ("nothing published yet")
# versus a partial release ("this image went out, that one did not").
registry_state() {
  local image=$1 tag=$2 owner=${REPOSITORY%%/*}
  registry_token "${owner}/${image}"
  local token=$TOKEN

  registry_get "$token" "${REGISTRY_API_BASE}/v2/${owner}/${image}/tags/list?n=1"
  case "$HTTP_CODE" in
    200) ;;
    404)
      if grep -q 'NAME_UNKNOWN' "$BODY"; then
        STATE="package-absent"
        return 0
      fi
      fail "the registry answered 404 for ${owner}/${image} without naming the reason; a bare 'not found' is not evidence that the tag is free:
  $(head -c 400 "$BODY")"
      ;;
    401 | 403)
      fail "reading the tag list of ${owner}/${image} was refused (HTTP ${HTTP_CODE}); that is not evidence the tag is free"
      ;;
    *)
      fail "the registry answered HTTP ${HTTP_CODE} for the tag list of ${owner}/${image}; refusing to publish on an inconclusive answer"
      ;;
  esac

  registry_get "$token" "${REGISTRY_API_BASE}/v2/${owner}/${image}/manifests/${tag}"
  case "$HTTP_CODE" in
    200) STATE="present" ;;
    404)
      if grep -q 'MANIFEST_UNKNOWN' "$BODY"; then
        STATE="tag-absent"
        return 0
      fi
      fail "the registry answered 404 for ${owner}/${image}:${tag} without reporting MANIFEST_UNKNOWN; refusing to read a bare 'not found' as absence:
  $(head -c 400 "$BODY")"
      ;;
    401 | 403)
      fail "reading ${owner}/${image}:${tag} was refused (HTTP ${HTTP_CODE}); that is not evidence the tag is free"
      ;;
    *)
      fail "the registry answered HTTP ${HTTP_CODE} for ${owner}/${image}:${tag}; refusing to publish on an inconclusive answer"
      ;;
  esac
}

check_image() {
  local image=$1 ref="${REGISTRY}/${REPOSITORY%%/*}/${1}:${TAG}"
  info "Checking whether ${ref} already exists"
  registry_state "$image" "$TAG"
  case "$STATE" in
    present)
      fail "image ${ref} already exists.
  Re-pushing would change the tag's target; existing digest pins stay unchanged.
  Cut the next build number (myswy.N+1) to publish different bytes."
      ;;
    package-absent) ok "no ${image} package has been published yet" ;;
    tag-absent) ok "the ${image} package exists but carries no ${TAG} tag" ;;
    *) fail "internal error: unknown registry state '${STATE}'" ;;
  esac
}

# ---------------------------------------------------------------------------

case "$SCOPE" in
  release) check_release ;;
  image) check_image "$IMAGE" ;;
  all)
    check_release
    for image in "${DISTRIBUTION_IMAGES[@]}"; do
      check_image "$image"
    done
    ;;
esac

ok "nothing has been published for ${TAG} in scope '${SCOPE}'; publishing may proceed"
