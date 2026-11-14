#!/usr/bin/env bash
# Multica CLI installer for the self-host distribution (zzttzzmyswy/multica).
#
# This is the install/upgrade entry point for THIS fork's builds. It exists
# separately from scripts/install.sh because that script installs the upstream
# project's CLI from multica-ai/multica and provisions the upstream server —
# running it here would replace a distribution build with an upstream one that
# lacks the direct-upload feature this fork exists for.
#
#   Install or upgrade to the newest published build:
#     curl -fsSL https://raw.githubusercontent.com/zzttzzmyswy/multica/main/scripts/install-myswy.sh | bash
#
#   Install or roll back to one exact version:
#     curl -fsSL .../scripts/install-myswy.sh | bash -s -- --version v0.9.0-myswy.1
#
#   Show what is installed and what is available, without changing anything:
#     bash scripts/install-myswy.sh --check
#
# Version semantics (deliberate, see docs/self-host-distribution.md):
#   * Releases are tagged vX.Y.Z-myswy.N. Every distribution tag is a GitHub
#     PRERELEASE, so the releases API's /releases/latest returns nothing and
#     `--version` is the supported way to install or roll back.
#   * Without --version, this script lists the published distribution tags and
#     installs the highest one. It never falls back to an upstream release.
#
# Requirements: curl, tar, and python3 for JSON parsing. python3 is not
# optional and is checked before anything is downloaded. A hand-rolled text
# parser cannot be used here: the releases payload nests objects (uploader,
# author, reactions) and the order of `assets` entries is not fixed, so both
# "split on }" and "grep for the asset name" misparse real responses.
#
# Security: every downloaded archive is verified against the release's
# checksums.txt before the binary is moved into place. A missing manifest or a
# digest mismatch aborts the install.
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
# One repository, one namespace. Nothing in this script can be pointed at
# another project: an install must never silently become an upstream one.
REPO_OWNER="zzttzzmyswy"
REPO_NAME="multica"
REPO_WEB_URL="https://github.com/${REPO_OWNER}/${REPO_NAME}"
REPO_API_URL="https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}"

# Distribution tags carry this suffix. Used to filter the release list so a
# tag pushed to this repository for another purpose is never installed.
DISTRIBUTION_SUFFIX="-myswy."

TARGET_VERSION=""
CHECK_ONLY=0

if [ -t 1 ] || [ -t 2 ]; then
  BOLD='\033[1m'
  GREEN='\033[0;32m'
  YELLOW='\033[0;33m'
  RED='\033[0;31m'
  CYAN='\033[0;36m'
  RESET='\033[0m'
else
  BOLD='' GREEN='' YELLOW='' RED='' CYAN='' RESET=''
fi

info() { printf "${BOLD}${CYAN}==> %s${RESET}\n" "$*"; }
ok()   { printf "${BOLD}${GREEN}✓ %s${RESET}\n" "$*"; }
warn() { printf "${BOLD}${YELLOW}⚠ %s${RESET}\n" "$*" >&2; }
fail() { printf "${BOLD}${RED}✗ %s${RESET}\n" "$*" >&2; exit 1; }

usage() {
  cat <<'USAGE'
Usage: install-myswy.sh [--version <tag>] [--check]

  (default)          Install, or upgrade to, the newest published build
  --version <tag>    Install or roll back to one exact release tag
                     (for example v0.9.0-myswy.1)
  --check            Report the installed and available versions; change nothing

Environment variables:
  MULTICA_BIN_DIR    Directory the binary is installed into
                     (default: /usr/local/bin, then $HOME/.local/bin)
  MULTICA_ARCHIVE_URL_BASE
                     Serve archives from a mirror laid out as
                     <base>/<tag>/<asset-name>. Checksums still come from the
                     same <base>, so an archive can never be verified against
                     a manifest from somewhere else.
USAGE
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
command_exists() { command -v "$1" >/dev/null 2>&1; }

detect_platform() {
  case "$(uname -s)" in
    Darwin) OS="darwin" ;;
    Linux) OS="linux" ;;
    *) fail "Unsupported operating system: $(uname -s). This installer supports macOS and Linux.
  Windows: install the .zip archive from ${REPO_WEB_URL}/releases by hand." ;;
  esac

  case "$(uname -m)" in
    x86_64 | amd64) ARCH="amd64" ;;
    aarch64 | arm64) ARCH="arm64" ;;
    *) fail "Unsupported architecture: $(uname -m)" ;;
  esac
}

# GitHub API GET that turns a non-200 into an explicit failure. A silent empty
# answer here is what makes an installer print "up to date" while installing
# nothing, or worse, install an unverified archive.
api_get() {
  local url=$1
  if ! command_exists curl; then
    fail "curl is required but was not found on PATH."
  fi
  curl -fsSL "$url"
}

# JSON helper. python3 is a hard requirement, checked up front rather than
# discovered halfway through a download. A text/awk parser is not an option:
# the releases payload nests objects and the order of `assets` is not fixed, so
# any "split the document and match nearby strings" approach misparses real
# responses (it passes only while the wanted asset happens to be first).
JSON_PY='
import json, re, sys

mode = sys.argv[1]

try:
    data = json.load(sys.stdin)
except Exception as exc:
    sys.stderr.write("release API returned invalid JSON: %s\n" % exc)
    sys.exit(2)

# A single release object, or the list endpoint. Normalize to a list.
releases = data if isinstance(data, list) else [data]

# The one tag shape this distribution publishes, and the same shape the CLI
# accepts (server/internal/cli/update.go: parseDistributionVersion). Four
# non-empty runs of digits and nothing else: no trailing "-extra", no extra
# component, no sign, no empty build. A looser check lets a malformed tag win the
# comparison below and then be installed, which is how v99.0.0-myswy.1-extra
# used to beat every real release.
def tag_pattern(suffix):
    return re.compile(r"^v(\d+)\.(\d+)\.(\d+)%s(\d+)$" % re.escape(suffix))

def tag_version(tag, pattern):
    """(major, minor, patch, build) as ints, or None for a tag that is not a
    release of this distribution.

    Python integers do not overflow, so a build number too large for the CLI
    still parses and orders correctly here; it is the asset lookup and the
    download that reject it, not the shape check.
    """
    if not isinstance(tag, str):
        return None
    match = pattern.match(tag)
    if not match:
        return None
    return tuple(int(group) for group in match.groups())

if mode == "highest":
    suffix = sys.argv[2]        # e.g. -myswy.
    platform = sys.argv[3]      # e.g. linux-amd64
    pattern = tag_pattern(suffix)
    best_tag = None
    best_key = None
    for release in releases:
        if not isinstance(release, dict):
            continue
        # Each exclusion is per-entry: one draft, malformed, or platform-less
        # release must not stop a later valid one from being chosen.
        if release.get("draft"):
            continue
        tag = release.get("tag_name")
        version = tag_version(tag, pattern)
        if version is None:
            continue
        # The archive must carry this release's own version, exactly as the CLI
        # requires (hasVersionedReleaseAssetFor). A versionless legacy name
        # cannot be tied to the tag it hangs off, so it does not count.
        wanted = "multica-cli-%s-%s.tar.gz" % (tag[1:], platform)
        if not any((asset.get("name") or "") == wanted for asset in release.get("assets") or []):
            continue
        if best_key is None or version > best_key:
            best_tag, best_key = tag, version
    if best_tag is None:
        sys.exit(1)
    print(best_tag)
elif mode == "assets":
    # Asset names of the single release on stdin, one per line.
    for asset in data.get("assets") or []:
        name = asset.get("name")
        if name:
            print(name)
else:
    sys.stderr.write("unknown mode %r\n" % mode)
    sys.exit(2)
'

require_json_parser() {
  command_exists python3 && return 0
  fail "python3 is required to read the release metadata but was not found on PATH.
  Install python3 and re-run; the installer will not guess at JSON without it."
}

# Every distribution release tag that has an archive for this platform, newest
# first. Reads the releases list rather than /releases/latest because every
# distribution tag is a prerelease, which the `latest` endpoint excludes.
list_distribution_tags() {
  local json
  json="$(api_get "${REPO_API_URL}/releases?per_page=100")" ||
    fail "Could not list releases from ${REPO_WEB_URL}. Check your network connection."

  printf '%s' "$json" | python3 -c "$JSON_PY" highest "$DISTRIBUTION_SUFFIX" "${OS}-${ARCH}"
}

resolve_target_version() {
  if [ -n "$TARGET_VERSION" ]; then
    case "$TARGET_VERSION" in
      v*) printf '%s' "$TARGET_VERSION" ;;
      *) printf 'v%s' "$TARGET_VERSION" ;;
    esac
    return 0
  fi

  local tags newest status
  # Capture the exit status explicitly: `fail` must report "no published build",
  # while a JSON parse error must report a parse error. Collapsing both into an
  # empty string would tell an operator their release is missing when the real
  # problem is an unreadable API response.
  set +e
  tags="$(list_distribution_tags)"
  status=$?
  set -e
  if [ "$status" -ne 0 ] && [ "$status" -ne 1 ]; then
    fail "Could not read the release list from ${REPO_WEB_URL} (parser exit ${status})."
  fi
  if [ -z "$tags" ]; then
    fail "No published build for ${OS}/${ARCH} was found in ${REPO_WEB_URL}.
  If this is unexpected, check ${REPO_WEB_URL}/releases — an archive named
  multica-cli-<version>-${OS}-${ARCH}.tar.gz must exist."
  fi
  newest="$(printf '%s\n' "$tags" | head -n 1)"
  printf '%s' "$newest"
}

# Downloads one release asset to a path, honouring the mirror override.
download_asset() {
  local tag=$1 asset=$2 dest=$3 url
  if [ -n "${MULTICA_ARCHIVE_URL_BASE:-}" ]; then
    url="${MULTICA_ARCHIVE_URL_BASE%/}/${tag}/${asset}"
  else
    url="${REPO_WEB_URL}/releases/download/${tag}/${asset}"
  fi

  info "Downloading ${asset} ..."
  if ! curl -fsSL "$url" -o "$dest"; then
    rm -f "$dest"
    fail "Failed to download ${url}"
  fi
}

# Verifies an archive against the release's checksums.txt. Fails closed: no
# manifest, no entry for this asset, or a digest mismatch all abort, because
# an unverified binary swap is a supply-chain hole rather than a slow install.
verify_checksum() {
  local archive=$1 manifest=$2 asset=$3 expected actual

  expected="$(awk -v name="$asset" '$2 == name { print tolower($1); exit }' "$manifest")"
  [ -n "$expected" ] || fail "No checksum for ${asset} in the release manifest; refusing to install an unverified binary."

  if command_exists sha256sum; then
    actual="$(sha256sum "$archive" | awk '{ print tolower($1) }')"
  elif command_exists shasum; then
    actual="$(shasum -a 256 "$archive" | awk '{ print tolower($1) }')"
  else
    fail "Neither sha256sum nor shasum is available, so the download cannot be verified."
  fi

  [ "$expected" = "$actual" ] ||
    fail "Checksum mismatch for ${asset}:
    expected ${expected}
    got      ${actual}
  Refusing to install. Re-download, and if it persists report it against ${REPO_WEB_URL}/releases."
}

installed_version() {
  local bin
  bin="$(command -v multica 2>/dev/null || true)"
  [ -n "$bin" ] || return 1
  # `multica version` prints "multica <version> (commit: ..., built: ...)".
  multica version 2>/dev/null | awk 'NR==1 { print $2 }'
}

install_binary() {
  local src=$1 bin_dir
  bin_dir="${MULTICA_BIN_DIR:-/usr/local/bin}"

  if [ -w "$bin_dir" ] || { [ ! -e "$bin_dir" ] && mkdir -p "$bin_dir" 2>/dev/null; }; then
    mv "$src" "$bin_dir/multica"
  elif command_exists sudo; then
    sudo mv "$src" "$bin_dir/multica"
  else
    bin_dir="$HOME/.local/bin"
    mkdir -p "$bin_dir"
    mv "$src" "$bin_dir/multica"
    chmod +x "$bin_dir/multica"
    case ":$PATH:" in
      *":$bin_dir:"*) ;;
      *)
        warn "${bin_dir} is not on your PATH. Add it to your shell profile:
  export PATH=\"${bin_dir}:\$PATH\""
        ;;
    esac
  fi
  chmod +x "$bin_dir/multica"
  printf '%s' "$bin_dir/multica"
}

main() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --version)
        [ $# -ge 2 ] || fail "--version requires a tag argument"
        TARGET_VERSION="$2"
        shift 2
        ;;
      --check) CHECK_ONLY=1; shift ;;
      --help | -h) usage; exit 0 ;;
      *) fail "Unknown option: $1 (try --help)" ;;
    esac
  done

  detect_platform
  require_json_parser

  local current target
  current="$(installed_version || true)"

  if [ "$CHECK_ONLY" = 1 ]; then
    target="$(resolve_target_version)"
    printf 'repository: %s\n' "$REPO_WEB_URL"
    printf 'platform:   %s/%s\n' "$OS" "$ARCH"
    printf 'installed:  %s\n' "${current:-<none>}"
    printf 'available:  %s\n' "$target"
    return 0
  fi

  target="$(resolve_target_version)"

  if [ -n "$current" ] && [ "v${current#v}" = "$target" ]; then
    ok "Multica CLI is already at ${target}"
    return 0
  fi

  info "Installing ${target} from ${REPO_WEB_URL}"
  if [ -n "$current" ]; then
    info "Replacing installed version ${current}"
  fi

  local asset version tmp_dir bin_path
  version="${target#v}"
  asset="multica-cli-${version}-${OS}-${ARCH}.tar.gz"
  tmp_dir="$(mktemp -d)"
  # shellcheck disable=SC2064  # expand tmp_dir now: the trap must name this dir
  trap "rm -rf '${tmp_dir}'" EXIT

  download_asset "$target" "$asset" "$tmp_dir/$asset"
  download_asset "$target" "checksums.txt" "$tmp_dir/checksums.txt"
  verify_checksum "$tmp_dir/$asset" "$tmp_dir/checksums.txt" "$asset"

  tar -xzf "$tmp_dir/$asset" -C "$tmp_dir" multica ||
    fail "The archive ${asset} does not contain a multica binary."

  bin_path="$(install_binary "$tmp_dir/multica")"
  ok "Installed ${target} to ${bin_path}"

  # Prove the replacement took effect rather than trusting the move.
  local after
  after="$(installed_version || true)"
  if [ "v${after#v}" != "$target" ]; then
    warn "Installed binary reports version '${after:-<unknown>}', expected ${target}.
  Another multica earlier on PATH may be shadowing ${bin_path}."
  fi

  printf '\n'
  printf 'Next: point the CLI at your server and start the daemon\n'
  printf '  multica setup self-host\n'
  printf '\n'
  printf 'Update later with the same command, or pin a version:\n'
  printf '  multica update --version %s\n' "$target"
}

main "$@"
