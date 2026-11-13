#!/usr/bin/env bash
# Refuse to publish a distribution release over assets that already exist.
#
# Why this exists: GoReleaser's `replace_existing_artifacts: false` protects the
# GitHub release's CLI archives, but it protects nothing in GHCR. The image jobs
# in release-myswy.yml ran unconditionally and wrote the tag with
# `docker buildx imagetools create`, so a rerun of a tag whose CLI had already
# been published could still replace the image a deployment was pinned to — the
# exact thing a digest pin is supposed to make impossible.
#
# One rule, checked before ANY write: if the release or either image tag already
# exists, publish nothing. A partial release is recovered by cutting the next
# build number (myswy.N+1), never by overwriting.
#
# The distinction that matters: "the thing does not exist" and "I could not find
# out" must not look the same. A 403, a 5xx, or a network failure is NOT
# evidence that a tag is free; treating it as free is how an unverified
# overwrite happens. Only an explicit 404 is treated as absent.
#
# Usage:
#   bash scripts/myswy-release-guard.sh --tag v0.9.0-myswy.1
#
# Environment:
#   GITHUB_REPOSITORY   owner/name that will receive the release (default: this fork)
#   GITHUB_TOKEN        token for the release API
#   REGISTRY_CHECK_CMD  override for tests: a command that, given an image
#                       reference, exits 0 when it exists, 1 when it does not,
#                       and any other status on an inconclusive answer.
set -uo pipefail

REPOSITORY="${GITHUB_REPOSITORY:-zzttzzmyswy/multica}"
# The only repository this distribution may publish from.
DISTRIBUTION_REPOSITORY="zzttzzmyswy/multica"
API_BASE="${GITHUB_API_URL:-https://api.github.com}"
REGISTRY="ghcr.io"

TAG=""

fail() { printf '✗ %s\n' "$*" >&2; exit 1; }
info() { printf '==> %s\n' "$*"; }
ok()   { printf '✓ %s\n' "$*"; }

usage() {
  echo "usage: $0 --tag vX.Y.Z-myswy.N" >&2
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --tag) TAG="${2:-}"; shift 2 ;;
    --repository) REPOSITORY="${2:-}"; shift 2 ;;
    -h | --help) usage ;;
    *) usage ;;
  esac
done

[ -n "$TAG" ] || usage

# Only this repository and this version shape may publish. A synced upstream tag
# (`v0.9.0`) must never trigger a distribution release: it would publish images
# whose artifacts the updater refuses, under a name that looks official.
case "$TAG" in
  v[0-9]*.[0-9]*.[0-9]*-myswy.[0-9]*) ;;
  *) fail "refusing to publish '$TAG': release tags must look like vX.Y.Z-myswy.N" ;;
esac
# The owner is pinned, not just the repository name: ghcr.io/multica-ai/... is a
# real namespace, and a typo there would publish this distribution's images into
# the upstream project's registry.
if [ "$REPOSITORY" != "$DISTRIBUTION_REPOSITORY" ]; then
  fail "refusing to publish from '$REPOSITORY': this distribution publishes only from '${DISTRIBUTION_REPOSITORY}'"
fi

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
    403 | 401)
      fail "release lookup for ${TAG} was refused (HTTP ${code}); a permission problem is not evidence that the tag is free"
      ;;
    *)
      fail "release lookup for ${TAG} returned HTTP ${code}; refusing to publish on an inconclusive answer"
      ;;
  esac
}

# Returns 0 when the image tag exists, 1 when it definitively does not, and dies
# on anything inconclusive. `docker buildx imagetools inspect` distinguishes
# "manifest unknown" from an auth or transport failure in its stderr.
image_exists() {
  local ref=$1 output status

  if [ -n "${REGISTRY_CHECK_CMD:-}" ]; then
    set +e
    output="$($REGISTRY_CHECK_CMD "$ref" 2>&1)"
    status=$?
    set -e
    case "$status" in
      0) return 0 ;;
      1) return 1 ;;
      *) fail "registry check for ${ref} was inconclusive (exit ${status}): ${output}" ;;
    esac
  fi

  set +e
  output="$(docker buildx imagetools inspect "$ref" 2>&1)"
  status=$?
  set -e
  if [ "$status" -eq 0 ]; then
    return 0
  fi
  # Docker reports a missing manifest distinctly from an auth or network
  # failure. Only the former means "free to publish".
  case "$output" in
    *"manifest unknown"* | *"not found"* | *"no such manifest"*) return 1 ;;
  esac
  fail "could not determine whether ${ref} exists; refusing to publish blind:
  ${output}"
}

main() {
  if [ -z "${GITHUB_TOKEN:-}" ] && [ -z "${REGISTRY_CHECK_CMD:-}" ]; then
    fail "GITHUB_TOKEN is required to check whether the release already exists"
  fi

  info "Checking whether ${REPOSITORY}@${TAG} was already published"
  if release_exists; then
    fail "release ${TAG} already exists in ${REPOSITORY}.
  Published bytes are what an installed CLI verified against its checksum, so
  they are never replaced. Cut the next build number (myswy.N+1) and tag again."
  fi
  ok "no release ${TAG} exists"

  local image ref
  for image in multica-backend multica-web; do
    ref="${REGISTRY}/${REPOSITORY%%/*}/${image}:${TAG}"
    info "Checking whether ${ref} already exists"
    if image_exists "$ref"; then
      fail "image ${ref} already exists.
  A deployment may be pinned to its digest; replacing the tag would leave that
  pin pointing at different bytes. Cut the next build number (myswy.N+1)."
    fi
    ok "no image ${ref} exists"
  done

  ok "nothing has been published for ${TAG}; publishing may proceed"
}

main
