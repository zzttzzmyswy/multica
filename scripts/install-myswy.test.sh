#!/usr/bin/env bash
# Behavioural tests for scripts/install-myswy.sh.
#
# The installer decides which project's binary ends up on the operator's PATH.
# A bug here replaces a distribution build with an upstream one, or installs an
# unverified archive — neither is recoverable by re-running the script. Each
# case below pins one of those decisions against stub `curl` responses, so no
# network access and no real GitHub release are involved.
#
# Usage: bash scripts/install-myswy.test.sh
set -uo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
ROOT_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"
INSTALLER="$SCRIPT_DIR/install-myswy.sh"

PASS=0
FAIL=0
FAILURES=()

ok()   { PASS=$((PASS + 1)); printf '    \033[32m✓\033[0m %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); FAILURES+=("$1"); printf '    \033[31m✗\033[0m %s\n' "$1"; }
step() { printf '\n==> %s\n' "$1"; }

[ -f "$INSTALLER" ] || { echo "missing $INSTALLER" >&2; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/install-myswy-test.XXXXXX")" || exit 1
trap 'rm -rf "$TMP"' EXIT

# ---------------------------------------------------------------------------
# Sandbox: a fake `multica` payload, a release archive built from it, and a
# `curl` stub that serves whatever the case registers.
# ---------------------------------------------------------------------------

# Builds an archive for one tag plus a checksums.txt, into $TMP/payload.
# Echoes the sha256 of the archive.
build_release_assets() {
  local version=$1 asset_dir="$TMP/payload/$1"
  mkdir -p "$asset_dir"

  local bin_dir="$TMP/bin-src"
  mkdir -p "$bin_dir"
  cat >"$bin_dir/multica" <<STUB
#!/usr/bin/env bash
if [ "\${1:-}" = version ]; then
  echo "multica $version (commit: deadbee, built: 2026-01-01T00:00:00Z)"
  exit 0
fi
exit 0
STUB
  chmod +x "$bin_dir/multica"

  local asset="multica-cli-${version}-linux-amd64.tar.gz"
  tar -czf "$asset_dir/$asset" -C "$bin_dir" multica
  local sum
  sum="$(sha256sum "$asset_dir/$asset" | awk '{ print $1 }')"
  printf '%s  %s\n' "$sum" "$asset" >"$asset_dir/checksums.txt"
  printf '%s' "$sum"
}

# Writes a `curl` stub. The stub answers:
#   * the releases list  -> $TMP/releases.json
#   * .../releases/download/<tag>/<asset> -> $TMP/payload/<tag>/<asset>
#   * anything else      -> 404
# Every requested URL is appended to $TMP/curl.log.
write_curl_stub() {
  local stub_dir="$1"
  mkdir -p "$stub_dir"
  cat >"$stub_dir/curl" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail

url=""
out=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done

[ -n "$url" ] && printf '%s\n' "$url" >>"${CURL_LOG:?}"

case "$url" in
  *"/releases?per_page=100"*)
    [ -f "${RELEASES_JSON:?}" ] || exit 22
    cat "$RELEASES_JSON"
    exit 0
    ;;
  *"/releases/download/"*)
    tail_part="${url#*/releases/download/}"
    tag="${tail_part%%/*}"
    asset="${tail_part#*/}"
    # Payload directories are keyed by the plain version; the URL carries the
    # v-prefixed tag.
    src="${PAYLOAD_DIR}/${tag#v}/${asset}"
    if [ ! -f "$src" ]; then
      exit 22
    fi
    if [ -n "$out" ]; then
      cp "$src" "$out"
    else
      cat "$src"
    fi
    exit 0
    ;;
esac
exit 22
STUB
  chmod +x "$stub_dir/curl"
}

# A releases list with the given tags, each advertising the standard linux
# archive names.
write_releases_json() {
  local dest=$1
  shift
  {
    printf '['
    local first=1 tag version
    for tag in "$@"; do
      version="${tag#v}"
      [ "$first" = 1 ] || printf ','
      first=0
      printf '{"tag_name":"%s","prerelease":true,"assets":[' "$tag"
      printf '{"name":"multica-cli-%s-linux-amd64.tar.gz"},' "$version"
      printf '{"name":"multica-cli-%s-linux-arm64.tar.gz"},' "$version"
      printf '{"name":"checksums.txt"}]}'
    done
    printf ']'
  } >"$dest"
}

# Runs the installer with stubs on PATH and an empty HOME, so the real user's
# multica is never consulted or replaced. The install dir is on PATH too, so
# the post-install version read-back finds the binary that was just placed
# there — the same way an operator's shell would.
run_installer() {
  local label=$1
  shift
  env -i \
    PATH="$TMP/stub-bin:$TMP/install-bin:/usr/bin:/bin" \
    HOME="$TMP/home" \
    MULTICA_BIN_DIR="$TMP/install-bin" \
    CURL_LOG="$TMP/curl.log" \
    RELEASES_JSON="$TMP/releases.json" \
    PAYLOAD_DIR="$TMP/payload" \
    bash "$INSTALLER" "$@" >"$TMP/$label.out" 2>"$TMP/$label.err"
}

reset_sandbox() {
  rm -rf "$TMP/work" "$TMP/install-bin" "$TMP/home" "$TMP/payload"
  mkdir -p "$TMP/work" "$TMP/install-bin" "$TMP/home"
  : >"$TMP/curl.log"
  rm -f "$TMP/releases.json"
}

# ---------------------------------------------------------------------------
# Cases
# ---------------------------------------------------------------------------

step "A fresh install picks the newest distribution build and verifies it"
reset_sandbox
write_curl_stub "$TMP/stub-bin"
build_release_assets "0.9.0-myswy.1" >/dev/null
build_release_assets "0.9.0-myswy.2" >/dev/null
write_releases_json "$TMP/releases.json" "v0.9.0-myswy.1" "v0.9.0-myswy.2"

if run_installer fresh; then
  ok "installer exited 0"
else
  bad "installer exited non-zero"; cat "$TMP/fresh.out" "$TMP/fresh.err" >&2
fi
if [ -x "$TMP/install-bin/multica" ]; then
  ok "binary installed into MULTICA_BIN_DIR"
else
  bad "no binary at $TMP/install-bin/multica"
fi
if "$TMP/install-bin/multica" version 2>/dev/null | grep -q "0.9.0-myswy.2"; then
  ok "installed the highest build number (.2, not the lexically larger .1 swap)"
else
  bad "installed version is not 0.9.0-myswy.2: $("$TMP/install-bin/multica" version 2>/dev/null || echo missing)"
fi
if grep -q "checksums.txt" "$TMP/curl.log"; then
  ok "downloaded the checksum manifest before installing"
else
  bad "checksums.txt was never fetched; the archive was installed unverified"
fi

step "Distribution build numbers order numerically, not lexically"
reset_sandbox
write_curl_stub "$TMP/stub-bin"
for n in 9 10; do build_release_assets "0.9.0-myswy.$n" >/dev/null; done
write_releases_json "$TMP/releases.json" "v0.9.0-myswy.9" "v0.9.0-myswy.10"

run_installer ordering || true
if "$TMP/install-bin/multica" version 2>/dev/null | grep -q "0.9.0-myswy.10"; then
  ok "myswy.10 is newer than myswy.9"
else
  bad "ordered myswy.9 above myswy.10 (lexical sort leaked through): $("$TMP/install-bin/multica" version 2>/dev/null || echo missing)"
fi

step "A newer base version wins regardless of the build number"
reset_sandbox
write_curl_stub "$TMP/stub-bin"
build_release_assets "0.9.0-myswy.7" >/dev/null
build_release_assets "0.10.0-myswy.1" >/dev/null
write_releases_json "$TMP/releases.json" "v0.9.0-myswy.7" "v0.10.0-myswy.1"

run_installer basecmp || true
if "$TMP/install-bin/multica" version 2>/dev/null | grep -q "0.10.0-myswy.1"; then
  ok "0.10.0-myswy.1 beats 0.9.0-myswy.7"
else
  bad "did not prefer the newer base version: $("$TMP/install-bin/multica" version 2>/dev/null || echo missing)"
fi

step "Upstream releases in the same repository are never installed"
reset_sandbox
write_curl_stub "$TMP/stub-bin"
# A bare upstream-shaped tag (the fork also carries upstream's tags) must be
# ignored even when it sorts highest.
build_release_assets "0.9.0-myswy.1" >/dev/null
build_release_assets "9.9.9" >/dev/null
write_releases_json "$TMP/releases.json" "v9.9.9" "v0.9.0-myswy.1"

run_installer skipupstream || true
if "$TMP/install-bin/multica" version 2>/dev/null | grep -q "0.9.0-myswy.1"; then
  ok "skipped the non-distribution tag v9.9.9"
else
  bad "installed a non-distribution tag: $("$TMP/install-bin/multica" version 2>/dev/null || echo missing)"
fi

step "A checksum mismatch aborts before anything is installed"
reset_sandbox
write_curl_stub "$TMP/stub-bin"
build_release_assets "0.9.0-myswy.1" >/dev/null
# Corrupt the manifest so the archive cannot verify.
printf '%s  %s\n' \
  "0000000000000000000000000000000000000000000000000000000000000000" \
  "multica-cli-0.9.0-myswy.1-linux-amd64.tar.gz" \
  >"$TMP/payload/0.9.0-myswy.1/checksums.txt"
write_releases_json "$TMP/releases.json" "v0.9.0-myswy.1"

if run_installer badsum; then
  bad "installer reported success despite a checksum mismatch"
else
  ok "installer failed on a checksum mismatch"
fi
if [ -e "$TMP/install-bin/multica" ]; then
  bad "a binary was installed despite the failed verification"
else
  ok "no binary was installed"
fi

step "A missing checksum manifest aborts rather than installing unverified"
reset_sandbox
write_curl_stub "$TMP/stub-bin"
build_release_assets "0.9.0-myswy.1" >/dev/null
rm -f "$TMP/payload/0.9.0-myswy.1/checksums.txt"
write_releases_json "$TMP/releases.json" "v0.9.0-myswy.1"

if run_installer nomanifest; then
  bad "installer succeeded with no checksum manifest"
else
  ok "installer failed with no checksum manifest"
fi
if [ -e "$TMP/install-bin/multica" ]; then
  bad "installed a binary without verifying it"
else
  ok "installed nothing"
fi

step "An explicit --version installs exactly that tag (rollback path)"
reset_sandbox
write_curl_stub "$TMP/stub-bin"
build_release_assets "0.9.0-myswy.1" >/dev/null
build_release_assets "0.9.0-myswy.2" >/dev/null
write_releases_json "$TMP/releases.json" "v0.9.0-myswy.1" "v0.9.0-myswy.2"

run_installer pinned --version v0.9.0-myswy.1 || true
if "$TMP/install-bin/multica" version 2>/dev/null | grep -q "0.9.0-myswy.1"; then
  ok "installed the pinned tag even though a newer one exists"
else
  bad "did not honour --version: $("$TMP/install-bin/multica" version 2>/dev/null || echo missing)"
fi

step "--version accepts a tag without the leading v"
reset_sandbox
write_curl_stub "$TMP/stub-bin"
build_release_assets "0.9.0-myswy.1" >/dev/null
write_releases_json "$TMP/releases.json" "v0.9.0-myswy.1"

run_installer novprefix --version 0.9.0-myswy.1 || true
if "$TMP/install-bin/multica" version 2>/dev/null | grep -q "0.9.0-myswy.1"; then
  ok "normalized 0.9.0-myswy.1 to the v-prefixed tag"
else
  bad "did not normalize the tag: $("$TMP/install-bin/multica" version 2>/dev/null || echo missing)"
fi

step "Re-installing the same version is a no-op that still verifies nothing was needed"
reset_sandbox
write_curl_stub "$TMP/stub-bin"
build_release_assets "0.9.0-myswy.1" >/dev/null
write_releases_json "$TMP/releases.json" "v0.9.0-myswy.1"
cp "$TMP/bin-src/multica" "$TMP/install-bin/multica"
chmod +x "$TMP/install-bin/multica"

run_installer noop --version v0.9.0-myswy.1 || true
if grep -q "already at v0.9.0-myswy.1" "$TMP/noop.out" "$TMP/noop.err" 2>/dev/null; then
  ok "reported the install as already current"
else
  bad "did not short-circuit an already-current install"
fi

step "--check reports versions without touching the install directory"
reset_sandbox
write_curl_stub "$TMP/stub-bin"
build_release_assets "0.9.0-myswy.1" >/dev/null
build_release_assets "0.9.0-myswy.3" >/dev/null
write_releases_json "$TMP/releases.json" "v0.9.0-myswy.1" "v0.9.0-myswy.3"
# An explicitly older installed binary, so "installed" and "available" differ
# and the report has to distinguish them.
cat >"$TMP/install-bin/multica" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = version ]; then
  echo "multica 0.9.0-myswy.1 (commit: deadbee, built: 2026-01-01T00:00:00Z)"
  exit 0
fi
exit 0
STUB
chmod +x "$TMP/install-bin/multica"
installed_before="$(sha256sum "$TMP/install-bin/multica" | awk '{ print $1 }')"

run_installer check --check || true
if grep -q "v0.9.0-myswy.3" "$TMP/check.out"; then
  ok "--check printed the available version"
else
  bad "--check did not report the available version: $(cat "$TMP/check.out" 2>/dev/null)"
fi
if grep -q "0.9.0-myswy.1" "$TMP/check.out"; then
  ok "--check printed the installed version"
else
  bad "--check did not report the installed version: $(cat "$TMP/check.out" 2>/dev/null)"
fi
if grep -q "/releases/download/" "$TMP/curl.log"; then
  bad "--check downloaded an archive"
else
  ok "--check downloaded nothing"
fi
if [ "$(sha256sum "$TMP/install-bin/multica" | awk '{ print $1 }')" = "$installed_before" ]; then
  ok "--check left the installed binary untouched"
else
  bad "--check replaced the installed binary"
fi

step "Every request stays inside the distribution repository, or a declared mirror"
reset_sandbox
write_curl_stub "$TMP/stub-bin"
build_release_assets "0.9.0-myswy.1" >/dev/null
write_releases_json "$TMP/releases.json" "v0.9.0-myswy.1"

run_installer scope || true
bad_scope=""
while read -r url; do
  [ -n "$url" ] || continue
  case "$url" in
    https://api.github.com/repos/zzttzzmyswy/multica/*) ;;
    https://github.com/zzttzzmyswy/multica/*) ;;
    *) bad_scope="$url" ;;
  esac
done <"$TMP/curl.log"
if [ -z "$bad_scope" ]; then
  ok "all requests targeted zzttzzmyswy/multica"
else
  bad "requested a URL outside the distribution repository: $bad_scope"
fi

step "No published build fails loudly instead of installing something else"
reset_sandbox
write_curl_stub "$TMP/stub-bin"
write_releases_json "$TMP/releases.json"

if run_installer empty; then
  bad "installer succeeded with no distribution release published"
else
  ok "installer failed with no published build"
fi
if grep -qi "no published build" "$TMP/empty.err"; then
  ok "the failure names the missing build"
else
  bad "the failure message does not explain the situation: $(cat "$TMP/empty.err" 2>/dev/null)"
fi

step "A mirror override is honoured for both the archive and its manifest"
reset_sandbox
write_curl_stub "$TMP/stub-bin"
build_release_assets "0.9.0-myswy.1" >/dev/null
write_releases_json "$TMP/releases.json" "v0.9.0-myswy.1"

env -i \
  PATH="$TMP/stub-bin:/usr/bin:/bin" \
  HOME="$TMP/home" \
  MULTICA_BIN_DIR="$TMP/install-bin" \
  MULTICA_ARCHIVE_URL_BASE="https://github.com/zzttzzmyswy/multica/releases/download" \
  CURL_LOG="$TMP/curl.log" \
  RELEASES_JSON="$TMP/releases.json" \
  PAYLOAD_DIR="$TMP/payload" \
  bash "$INSTALLER" --version v0.9.0-myswy.1 >"$TMP/mirror.out" 2>"$TMP/mirror.err"
mirror_rc=$?
if [ "$mirror_rc" = 0 ]; then
  ok "mirror override installed successfully"
else
  bad "mirror override install failed"; cat "$TMP/mirror.err" >&2
fi
archive_hits="$(grep -c "/releases/download/v0.9.0-myswy.1/" "$TMP/curl.log" || true)"
if [ "${archive_hits:-0}" -ge 2 ]; then
  ok "both the archive and checksums.txt came from the mirror layout"
else
  bad "expected the archive and manifest under the mirror base, saw $archive_hits request(s)"
fi

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
printf '\n'
if [ "$FAIL" -eq 0 ]; then
  printf '\033[32m%s checks passed\033[0m\n' "$PASS"
  exit 0
fi

printf '\033[31m%s passed, %s failed\033[0m\n' "$PASS" "$FAIL"
for f in "${FAILURES[@]}"; do printf '  - %s\n' "$f"; done
exit 1
