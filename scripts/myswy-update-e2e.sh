#!/usr/bin/env bash
# End-to-end check of `multica update` against a local release server.
#
# Runs the real CLI binary against a fake GitHub Releases API on loopback, so
# the update path is exercised over real HTTP (request paths, redirect-free
# downloads, checksum verification, atomic binary replacement) without
# touching GitHub and without replacing the multica on this host's PATH.
#
# Usage: bash scripts/myswy-update-e2e.sh
set -uo pipefail

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
SERVER_PY="$ROOT_DIR/scripts/myswy-release-server.py"

PASS=0
FAIL=0
FAILURES=()

ok()   { PASS=$((PASS + 1)); printf '    \033[32m✓\033[0m %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); FAILURES+=("$1"); printf '    \033[31m✗\033[0m %s\n' "$1"; }
step() { printf '\n==> %s\n' "$1"; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/myswy-update-e2e.XXXXXX")" || exit 1
SERVER_PID=""
cleanup() {
  if [ -n "$SERVER_PID" ]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Fixtures: two release binaries, their archives, and a checksums manifest.
# ---------------------------------------------------------------------------
ROOT="$WORK/releases-root"
mkdir -p "$ROOT/assets" "$WORK/build"

build_release_binary() {
  local version=$1 dir="$WORK/build/$1"
  mkdir -p "$dir"
  ( cd "$ROOT_DIR/server" && go build \
      -ldflags "-X main.version=v${version} -X main.commit=abc1234 -X main.buildCommit=abc1234567890123456789012345678901234567890 -X main.date=2026-11-14T00:00:00Z" \
      -o "$dir/multica" ./cmd/multica ) || return 1
}

make_release_assets() {
  local version=$1 tag="v$1" dir="$ROOT/assets/v$1"
  mkdir -p "$dir"
  tar -czf "$dir/multica-cli-${version}-linux-amd64.tar.gz" -C "$WORK/build/$1" multica
}

step "Build two release binaries from this tree"
if build_release_binary "0.9.0-myswy.1" && build_release_binary "0.9.0-myswy.2"; then
  ok "built both release binaries"
else
  bad "could not build the release binaries"
  printf '%s\n' "${FAILURES[@]}"; exit 1
fi
make_release_assets "0.9.0-myswy.1"
make_release_assets "0.9.0-myswy.2"

# Build the manifest and the releases fixture together: the server substitutes
# PORT with the port it actually bound.
#
# The fixture models GitHub's real semantics, which is the point:
#   * every release is `prerelease: true`, exactly as the distribution publishes;
#   * therefore `/releases/latest` 404s, exactly as GitHub answers when the only
#     releases are prereleases;
#   * the list endpoint returns them, newest first, with `published_at` ordering.
# A fixture that served a prerelease from `latest` would let a CLI that depends
# on that endpoint pass while being unable to work against the real API.
( cd "$ROOT/assets" && sha256sum v*/*.tar.gz ) | sed 's#v[^/]*/##' >"$WORK/sums.txt"
{
  printf '{\n "latest": null,\n "tags": {\n'
  first=1
  index=0
  for tag in v0.9.0-myswy.1 v0.9.0-myswy.2; do
    version="${tag#v}"
    asset="multica-cli-${version}-linux-amd64.tar.gz"
    cp "$WORK/sums.txt" "$ROOT/assets/$tag/checksums.txt"
    [ "$first" = 1 ] || printf ',\n'
    first=0
    index=$((index + 1))
    printf '  "%s": {"tag_name": "%s", "prerelease": true, "draft": false, "published_at": "2026-11-14T00:0%d:00Z", "assets": [' "$tag" "$tag" "$index"
    printf '{"name": "%s", "browser_download_url": "http://127.0.0.1:PORT/releases/download/%s/%s"},' "$asset" "$tag" "$asset"
    printf '{"name": "checksums.txt", "browser_download_url": "http://127.0.0.1:PORT/releases/download/%s/checksums.txt"}' "$tag"
    printf ']}'
  done
  printf '\n }\n}\n'
} >"$ROOT/releases.json"

step "Start the local release server"
python3 "$SERVER_PY" "$ROOT" "$WORK/port" &
SERVER_PID=$!
for _ in $(seq 1 100); do
  [ -s "$WORK/port" ] && break
  sleep 0.1
done
[ -s "$WORK/port" ] || { echo "release server did not start" >&2; exit 1; }
PORT="$(cat "$WORK/port")"
ok "server listening on 127.0.0.1:$PORT"

# Every update run points the CLI at this server and works on a private copy of
# the binary, so the host's installed multica is never touched.
export MULTICA_RELEASE_API_BASE_URL="http://127.0.0.1:$PORT"
export MULTICA_RELEASE_DOWNLOAD_BASE_URL="http://127.0.0.1:$PORT/releases/download"

requests() { curl -fsS "http://127.0.0.1:$PORT/_requests" | grep -v '^/_requests$' | sort -u; }
reset_requests() { curl -fsS "http://127.0.0.1:$PORT/_requests" >/dev/null; }

fresh_target() {
  local dir="$WORK/target-$1"
  rm -rf "$dir"; mkdir -p "$dir"
  cp "$WORK/build/0.9.0-myswy.1/multica" "$dir/multica"
  chmod +x "$dir/multica"
  printf '%s' "$dir/multica"
}

# sha256 of a file, or the literal "missing". Used to prove a failed update left
# the binary byte-for-byte alone: a version string can be unchanged while the
# file was overwritten, so the digest is the assertion.
sha_of() {
  if [ -e "$1" ]; then sha256sum "$1" | awk '{ print $1 }'; else printf 'missing'; fi
}

# Captures `multica version` output once, then matches the captured text.
#
# The obvious `"$bin" version | grep -q PATTERN` is unsafe under `set -o
# pipefail`: grep exits 0 the moment it sees a match and closes the pipe, the
# binary then dies of SIGPIPE (141), and pipefail makes the whole pipeline 141
# even though the match succeeded. That produced a "binary was replaced" false
# failure in this very script. Capturing first removes the early-close race
# instead of retrying around it.
version_matches() {
  local bin=$1 pattern=$2 out
  out="$("$bin" version 2>&1)" || return 1
  printf '%s\n' "$out" | grep -q -- "$pattern"
}

# The version line of a binary, for failure messages only.
version_line() {
  local bin=$1
  "$bin" version 2>&1 | head -n 1
}

step "A pinned update installs exactly the requested tag"
target_bin="$(fresh_target pinned)"
before="$(requests)"
out="$("$target_bin" update --version v0.9.0-myswy.2 2>&1)"; rc=$?
if [ "$rc" = 0 ]; then ok "pinned update exited 0"; else bad "pinned update failed: $out"; fi
if version_matches "$target_bin" "0.9.0-myswy.2"; then
  ok "binary now reports v0.9.0-myswy.2"
else
  bad "binary did not change to the pinned version: $(version_line "$target_bin")"
fi
new_requests="$(comm -13 <(printf '%s\n' "$before") <(requests))"
if printf '%s\n' "$new_requests" | grep -q "/repos/zzttzzmyswy/multica/releases/tags/v0.9.0-myswy.2"; then
  ok "resolved the pinned tag through zzttzzmyswy/multica"
else
  bad "pinned update did not resolve the tag from the distribution repository: $new_requests"
fi
if printf '%s\n' "$new_requests" | grep -q "/releases/latest"; then
  bad "a pinned update consulted /releases/latest"
else
  ok "a pinned update never consults /releases/latest"
fi
if printf '%s\n' "$new_requests" | grep -q "/releases/download/v0.9.0-myswy.2/checksums.txt"; then
  ok "fetched the checksum manifest from the same tag"
else
  bad "did not fetch checksums.txt from the pinned tag: $new_requests"
fi
# Only the paths this fake server received are visible here, so the assertion
# is about the SHAPE of each path: metadata lookups must name the distribution
# repository, and artifact downloads must sit under the configured base. A path
# naming any other owner would mean the CLI built a URL for somewhere else.
stray=""
while read -r path; do
  [ -n "$path" ] || continue
  case "$path" in
    /repos/zzttzzmyswy/multica/releases/*) ;;
    /releases/download/*) ;;
    *) stray="$stray $path" ;;
  esac
done <<<"$new_requests"
if [ -z "$stray" ]; then
  ok "every request was a distribution-repository lookup or a configured-base download"
else
  bad "requests outside the distribution source:$stray"
fi

step "A pinned rollback installs the older tag"
target_bin="$(fresh_target rollback)"
out="$("$target_bin" update --version v0.9.0-myswy.1 2>&1)"; rc=$?
if [ "$rc" = 0 ] && version_matches "$target_bin" "0.9.0-myswy.1"; then
  ok "rolled back to v0.9.0-myswy.1"
else
  bad "rollback failed: $out"
fi

step "An unpinned update installs the newest release"
target_bin="$(fresh_target latest)"
before="$(requests)"
out="$("$target_bin" update 2>&1)"; rc=$?
if [ "$rc" = 0 ] && version_matches "$target_bin" "myswy.2"; then
  ok "unpinned update installed v0.9.0-myswy.2"
else
  bad "unpinned update did not install the newest release: $out"
fi
new_requests="$(comm -13 <(printf '%s\n' "$before") <(requests))"
# The critical assertion: an unpinned update must use the LIST endpoint, because
# `/releases/latest` cannot see prereleases and this fixture makes it 404 like
# the real API does. Asking `latest` and giving up is the exact defect that was
# reported.
if printf '%s\n' "$new_requests" | grep -qE "/repos/zzttzzmyswy/multica/releases/?$"; then
  ok "unpinned update read the release LIST from zzttzzmyswy/multica"
else
  bad "unpinned update did not use the distribution release list: $new_requests"
fi
if printf '%s\n' "$new_requests" | grep -q "/releases/latest"; then
  bad "unpinned update depended on /releases/latest, which 404s for prerelease-only repositories"
else
  ok "unpinned update never relies on /releases/latest"
fi

step "An unpinned update with no usable build fails with the pinned form"
# Same server, but this repository's only release has no linux/amd64 archive, so
# there is genuinely nothing to install. The error must teach the pinned
# command rather than surfacing a bare status code.
target_bin="$(fresh_target nopublished)"
mv "$ROOT/releases.json" "$ROOT/releases.json.bak"
python3 - "$ROOT" <<'PY'
import json, sys
root = sys.argv[1]
# A darwin-only release: nothing this platform can install.
data = {"latest": None, "tags": {"v0.9.0-myswy.9": {
    "tag_name": "v0.9.0-myswy.9", "prerelease": True, "draft": False,
    "published_at": "2026-11-14T00:00:00Z",
    "assets": [{"name": "multica-cli-0.9.0-myswy.9-darwin-arm64.tar.gz"}]}}}
json.dump(data, open(root + "/releases.json", "w"))
PY
out="$("$target_bin" update 2>&1)"; rc=$?
mv "$ROOT/releases.json.bak" "$ROOT/releases.json"
if [ "$rc" != 0 ]; then
  ok "an unpinned update with no installable build fails"
else
  bad "an unpinned update succeeded with no installable build"
fi
if printf '%s' "$out" | grep -q -- "--version"; then
  ok "the failure shows the pinned --version form"
else
  bad "the failure does not teach the pinned form: $out"
fi

step "A checksum mismatch refuses to replace the binary"
target_bin="$(fresh_target badsum)"
# Corrupt the .2 manifest: the archive will not match.
printf '%s  %s\n' \
  "0000000000000000000000000000000000000000000000000000000000000000" \
  "multica-cli-0.9.0-myswy.2-linux-amd64.tar.gz" \
  >"$ROOT/assets/v0.9.0-myswy.2/checksums.txt"
before_sha="$(sha_of "$target_bin")"
out="$("$target_bin" update --version v0.9.0-myswy.2 2>&1)"; rc=$?
if [ "$rc" != 0 ]; then ok "update failed on a checksum mismatch"; else bad "update succeeded despite a checksum mismatch"; fi
# SHA-256, not a version string: the binary is the thing that must not change.
after_sha="$(sha_of "$target_bin")"
if [ "$before_sha" = "$after_sha" ]; then
  ok "the installed binary is byte-for-byte unchanged (sha256 $before_sha)"
else
  bad "the binary changed despite the failed verification: $before_sha -> $after_sha"
fi
# Restore the good manifest for any later case.
cp "$WORK/sums.txt" "$ROOT/assets/v0.9.0-myswy.2/checksums.txt"

step "An unknown tag fails instead of installing the latest"
target_bin="$(fresh_target unknown)"
before_sha="$(sha_of "$target_bin")"
out="$("$target_bin" update --version v9.9.9-myswy.99 2>&1)"; rc=$?
if [ "$rc" != 0 ]; then ok "update failed for an unknown tag"; else bad "update succeeded for an unknown tag"; fi
after_sha="$(sha_of "$target_bin")"
if [ "$before_sha" = "$after_sha" ]; then
  ok "the binary is byte-for-byte unchanged (sha256 $before_sha)"
else
  bad "an unknown tag replaced the binary: $before_sha -> $after_sha"
fi
if printf '%s' "$out" | grep -q "zzttzzmyswy/multica"; then
  ok "the failure names the release repository it consulted"
else
  bad "the failure does not say where it looked: $out"
fi

step "A malformed tag that outranks the valid one is never selected"
# The reported defect: v99.0.0-myswy.1-extra contains the distribution suffix and
# sorts higher than every real release, so a suffix-only check selected it and
# then requested /releases/tags/v99.0.0-myswy.1-extra. The valid release must
# still be chosen, and the malformed tag must never appear in a request path.
target_bin="$(fresh_target malformed)"
mv "$ROOT/releases.json" "$ROOT/releases.json.bak"
python3 - "$ROOT" "$PORT" <<'PY'
import json, sys
root, port = sys.argv[1], sys.argv[2]
tag = "v0.9.0-myswy.2"
asset = "multica-cli-%s-linux-amd64.tar.gz" % tag[1:]
def base_url(t, a):
    return "http://127.0.0.1:%s/releases/download/%s/%s" % (port, t, a)
releases = [
    # Malformed entries that all sort above the valid one.
    {"tag_name": "v99.0.0-myswy.1-extra", "prerelease": True, "draft": False,
     "published_at": "2026-11-14T00:09:00Z",
     "assets": [{"name": "multica-cli-99.0.0-myswy.1-extra-linux-amd64.tar.gz",
                 "browser_download_url": base_url("v99.0.0-myswy.1-extra", "multica-cli-99.0.0-myswy.1-extra-linux-amd64.tar.gz")}]},
    {"tag_name": "v98.0.0-myswy.1.2", "prerelease": True, "draft": False,
     "published_at": "2026-11-14T00:08:00Z",
     "assets": [{"name": "multica-cli-98.0.0-myswy.1.2-linux-amd64.tar.gz",
                 "browser_download_url": base_url("v98.0.0-myswy.1.2", "multica-cli-98.0.0-myswy.1.2-linux-amd64.tar.gz")}]},
    {"tag_name": "v97.0.0-myswy.", "prerelease": True, "draft": False,
     "published_at": "2026-11-14T00:07:00Z",
     "assets": [{"name": "multica-cli-97.0.0-myswy.-linux-amd64.tar.gz",
                 "browser_download_url": base_url("v97.0.0-myswy.", "multica-cli-97.0.0-myswy.-linux-amd64.tar.gz")}]},
    {"tag_name": "v96.0.0-myswy.x", "prerelease": True, "draft": False,
     "published_at": "2026-11-14T00:06:00Z",
     "assets": [{"name": "multica-cli-96.0.0-myswy.x-linux-amd64.tar.gz",
                 "browser_download_url": base_url("v96.0.0-myswy.x", "multica-cli-96.0.0-myswy.x-linux-amd64.tar.gz")}]},
    # Draft, otherwise well-formed.
    {"tag_name": "v95.0.0-myswy.1", "prerelease": True, "draft": True,
     "published_at": "2026-11-14T00:05:00Z",
     "assets": [{"name": "multica-cli-95.0.0-myswy.1-linux-amd64.tar.gz",
                 "browser_download_url": base_url("v95.0.0-myswy.1", "multica-cli-95.0.0-myswy.1-linux-amd64.tar.gz")}]},
    # Well-formed, but no archive for this platform.
    {"tag_name": "v94.0.0-myswy.1", "prerelease": True, "draft": False,
     "published_at": "2026-11-14T00:04:00Z",
     "assets": [{"name": "multica-cli-94.0.0-myswy.1-darwin-arm64.tar.gz",
                 "browser_download_url": base_url("v94.0.0-myswy.1", "multica-cli-94.0.0-myswy.1-darwin-arm64.tar.gz")}]},
    # Well-formed, but its only archive names a different version.
    {"tag_name": "v93.0.0-myswy.1", "prerelease": True, "draft": False,
     "published_at": "2026-11-14T00:03:00Z",
     "assets": [{"name": "multica-cli-%s" % asset,
                 "browser_download_url": base_url("v93.0.0-myswy.1", asset)}]},
    # The one real release.
    {"tag_name": tag, "prerelease": True, "draft": False,
     "published_at": "2026-11-14T00:02:00Z",
     "assets": [{"name": asset, "browser_download_url": base_url(tag, asset)},
                {"name": "checksums.txt",
                 "browser_download_url": base_url(tag, "checksums.txt")}]},
]
json.dump({"latest": None, "tags": {r["tag_name"]: r for r in releases}},
          open(root + "/releases.json", "w"))
PY
before="$(requests)"
out="$("$target_bin" update 2>&1)"; rc=$?
mv "$ROOT/releases.json.bak" "$ROOT/releases.json"
if [ "$rc" = 0 ]; then
  ok "unpinned update exited 0"
else
  bad "unpinned update failed against a list with malformed neighbours: $out"
fi
if version_matches "$target_bin" "0.9.0-myswy.2"; then
  ok "selected the only well-formed release instead of a malformed one ranked higher"
else
  bad "did not install v0.9.0-myswy.2: $(version_line "$target_bin")"
fi
malformed_hits="$(comm -13 <(printf '%s\n' "$before") <(requests) | grep -E 'myswy\.1-extra|myswy\.1\.2|myswy\.-|myswy\.x|99\.0\.0|98\.0\.0|97\.0\.0|96\.0\.0|95\.0\.0|94\.0\.0|93\.0\.0' || true)"
if [ -z "$malformed_hits" ]; then
  ok "no request ever named a malformed, draft, platform-less, or version-mismatched release"
else
  bad "the update touched an entry it should have skipped: $malformed_hits"
fi

printf '\n'
if [ "$FAIL" -eq 0 ]; then
  printf '\033[32m%s checks passed\033[0m\n' "$PASS"
  exit 0
fi
printf '\033[31m%s passed, %s failed\033[0m\n' "$PASS" "$FAIL"
for f in "${FAILURES[@]}"; do printf '  - %s\n' "$f"; done
exit 1
