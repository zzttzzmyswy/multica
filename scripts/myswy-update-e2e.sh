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
( cd "$ROOT/assets" && sha256sum v*/*.tar.gz ) | sed 's#v[^/]*/##' >"$WORK/sums.txt"
{
  printf '{\n "latest": "v0.9.0-myswy.2",\n "tags": {\n'
  first=1
  for tag in v0.9.0-myswy.1 v0.9.0-myswy.2; do
    version="${tag#v}"
    asset="multica-cli-${version}-linux-amd64.tar.gz"
    cp "$WORK/sums.txt" "$ROOT/assets/$tag/checksums.txt"
    [ "$first" = 1 ] || printf ',\n'
    first=0
    printf '  "%s": {"tag_name": "%s", "prerelease": true, "assets": [' "$tag" "$tag"
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

step "A pinned update installs exactly the requested tag"
target_bin="$(fresh_target pinned)"
before="$(requests)"
out="$("$target_bin" update --version v0.9.0-myswy.2 2>&1)"; rc=$?
if [ "$rc" = 0 ]; then ok "pinned update exited 0"; else bad "pinned update failed: $out"; fi
if "$target_bin" version | grep -q "0.9.0-myswy.2"; then
  ok "binary now reports v0.9.0-myswy.2"
else
  bad "binary did not change to the pinned version: $("$target_bin" version | head -1)"
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
if [ "$rc" = 0 ] && "$target_bin" version | grep -q "0.9.0-myswy.1"; then
  ok "rolled back to v0.9.0-myswy.1"
else
  bad "rollback failed: $out"
fi

step "An unpinned update installs the newest release"
target_bin="$(fresh_target latest)"
before="$(requests)"
out="$("$target_bin" update 2>&1)"; rc=$?
if [ "$rc" = 0 ] && "$target_bin" version | grep -q "myswy.2"; then
  ok "unpinned update installed v0.9.0-myswy.2"
else
  bad "unpinned update did not install the newest release: $out"
fi
new_requests="$(comm -13 <(printf '%s\n' "$before") <(requests))"
if printf '%s\n' "$new_requests" | grep -q "/repos/zzttzzmyswy/multica/releases/latest"; then
  ok "unpinned update read /releases/latest from zzttzzmyswy/multica"
else
  bad "unpinned update did not use the distribution latest endpoint: $new_requests"
fi

step "A checksum mismatch refuses to replace the binary"
target_bin="$(fresh_target badsum)"
cp "$target_bin" "$WORK/before-badsum"
# Corrupt the .2 manifest: the archive will not match.
printf '%s  %s\n' \
  "0000000000000000000000000000000000000000000000000000000000000000" \
  "multica-cli-0.9.0-myswy.2-linux-amd64.tar.gz" \
  >"$ROOT/assets/v0.9.0-myswy.2/checksums.txt"
out="$("$target_bin" update --version v0.9.0-myswy.2 2>&1)"; rc=$?
if [ "$rc" != 0 ]; then ok "update failed on a checksum mismatch"; else bad "update succeeded despite a checksum mismatch"; fi
if "$target_bin" version | grep -q "0.9.0-myswy.1"; then
  ok "the installed binary was left untouched"
else
  bad "the binary was replaced despite the failed verification"
fi
# Restore the good manifest for any later case.
cp "$WORK/sums.txt" "$ROOT/assets/v0.9.0-myswy.2/checksums.txt"

step "An unknown tag fails instead of installing the latest"
target_bin="$(fresh_target unknown)"
out="$("$target_bin" update --version v9.9.9-myswy.99 2>&1)"; rc=$?
if [ "$rc" != 0 ]; then ok "update failed for an unknown tag"; else bad "update succeeded for an unknown tag"; fi
if "$target_bin" version | grep -q "0.9.0-myswy.1"; then
  ok "the binary stayed on its installed version"
else
  bad "an unknown tag still replaced the binary"
fi
if printf '%s' "$out" | grep -q "zzttzzmyswy/multica"; then
  ok "the failure names the release repository it consulted"
else
  bad "the failure does not say where it looked: $out"
fi

printf '\n'
if [ "$FAIL" -eq 0 ]; then
  printf '\033[32m%s checks passed\033[0m\n' "$PASS"
  exit 0
fi
printf '\033[31m%s passed, %s failed\033[0m\n' "$PASS" "$FAIL"
for f in "${FAILURES[@]}"; do printf '  - %s\n' "$f"; done
exit 1
