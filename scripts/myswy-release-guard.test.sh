#!/usr/bin/env bash
# Behavioural tests for scripts/myswy-release-guard.sh.
#
# The guard is the only thing standing between a rerun and an overwritten
# release/image tag, so these tests run the script as the workflow runs it —
# real curl, real jq, real JSON parsing — against a local GitHub+GHCR stub
# (scripts/myswy-release-guard-stub.py). Nothing reaches github.com or ghcr.io.
#
# Deliberately NOT tested by injecting an exit code: the two defects that
# shipped were both about interpretation ("403 means the tag is free", "any
# `not found` on stderr means the image is absent"), and an injected status code
# skips exactly the code that was wrong. Here the registry's reported reason is
# what decides.
set -uo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
GUARD="$SCRIPT_DIR/myswy-release-guard.sh"
STUB="$SCRIPT_DIR/myswy-release-guard-stub.py"

PASS=0
FAIL=0
FAILURES=()

ok()   { PASS=$((PASS + 1)); printf '    \033[32m✓\033[0m %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); FAILURES+=("$1"); printf '    \033[31m✗\033[0m %s\n' "$1"; }
step() { printf '\n==> %s\n' "$1"; }

[ -f "$GUARD" ] || { echo "missing $GUARD" >&2; exit 1; }
[ -f "$STUB" ] || { echo "missing $STUB" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "python3 is required by the stub" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "jq is required by the guard" >&2; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/myswy-release-guard.XXXXXX")" || exit 1
STUB_PID=""
cleanup() {
  [ -n "$STUB_PID" ] && kill "$STUB_PID" 2>/dev/null
  rm -rf "$TMP"
}
trap cleanup EXIT

TAG="v0.9.0-myswy.1"
CONFIG="$TMP/config.json"
PORT_FILE="$TMP/port"
REQUEST_LOG="$TMP/requests.log"

# The stub is started once; each case rewrites the config it re-reads per
# request. Configs are written whole, so a case can never inherit a stray key.
start_stub() {
  rm -f "$PORT_FILE"
  python3 "$STUB" "$CONFIG" "$PORT_FILE" "$REQUEST_LOG" &
  STUB_PID=$!
  local waited=0
  while [ ! -s "$PORT_FILE" ]; do
    sleep 0.05
    waited=$((waited + 1))
    if [ "$waited" -gt 200 ]; then
      echo "registry stub did not start" >&2
      exit 1
    fi
  done
  PORT="$(cat "$PORT_FILE")"
}

configure() {
  cat >"$CONFIG"
}

# Nothing published: no release, no packages at all.
config_first_publish() {
  configure <<'JSON'
{
  "release_status": 404,
  "repositories": {}
}
JSON
}

# Runs the guard against the stub. $TMP/out and $TMP/err hold the output; the
# exit code is returned.
run_guard() {
  : >"$REQUEST_LOG"
  env -i \
    PATH="/usr/bin:/bin:/usr/local/bin" \
    HOME="$TMP" \
    GITHUB_TOKEN=test-token \
    GITHUB_REPOSITORY=zzttzzmyswy/multica \
    GITHUB_API_URL="http://127.0.0.1:${PORT}" \
    GHCR_USERNAME=zzttzzmyswy \
    GHCR_TOKEN=test-token \
    REGISTRY_API_BASE="http://127.0.0.1:${PORT}" \
    REGISTRY_TOKEN_URL="http://127.0.0.1:${PORT}/token" \
    bash "$GUARD" "$@" >"$TMP/out" 2>"$TMP/err"
}

start_stub

# ---------------------------------------------------------------------------

step "Nothing published: the first publish is allowed"
config_first_publish
if run_guard --tag "$TAG"; then
  ok "guard exited 0"
else
  bad "guard blocked a first publish: $(cat "$TMP/err")"
fi
grep -q "publishing may proceed" "$TMP/out" \
  && ok "guard reported the tag as free" \
  || bad "guard did not confirm the tag was free: $(cat "$TMP/out")"
grep -q "no multica-backend package has been published yet" "$TMP/out" \
  && ok "a package that was never created is reported as such, not as a missing tag" \
  || bad "guard did not distinguish 'package absent': $(cat "$TMP/out")"
grep -q 'tags/list' "$REQUEST_LOG" \
  && ok "the tag check asked the registry for the repository's tags first" \
  || bad "guard never proved the package state before reading a manifest"

step "The release already exists: the guard refuses"
configure <<'JSON'
{"release_status": 200, "repositories": {}}
JSON
if run_guard --tag "$TAG"; then
  bad "guard allowed a release to be re-published over existing assets"
else
  ok "guard refused an existing release"
fi
grep -q "already exists" "$TMP/err" \
  && ok "the refusal says the release already exists" \
  || bad "the refusal does not explain the conflict: $(cat "$TMP/err")"
grep -q '/v2/' "$REQUEST_LOG" \
  && bad "guard touched the registry after the release check already failed" \
  || ok "guard stopped before touching the registry"

step "An image tag already exists: the guard refuses"
configure <<'JSON'
{
  "release_status": 404,
  "repositories": {
    "zzttzzmyswy/multica-backend": {"manifests": {"v0.9.0-myswy.1": {"status": 200}}},
    "zzttzzmyswy/multica-web": {"manifests": {"v0.9.0-myswy.1": {"status": 200}}}
  }
}
JSON
if run_guard --tag "$TAG"; then
  bad "guard allowed an existing image tag to be overwritten"
else
  ok "guard refused an existing image tag"
fi
grep -q "multica-backend" "$TMP/err" && grep -q "already exists" "$TMP/err" \
  && ok "the refusal names the conflicting image" \
  || bad "the refusal does not name the image: $(cat "$TMP/err")"
grep -q "multica-web" "$TMP/err" \
  && bad "guard kept checking after the first image already conflicted" \
  || ok "guard stopped at the first conflicting image"

step "A package that exists without this tag is not a conflict"
configure <<'JSON'
{
  "release_status": 404,
  "repositories": {
    "zzttzzmyswy/multica-backend": {"tags": ["v0.9.0-myswy.0"], "manifests": {"v0.9.0-myswy.0": {"status": 200}}},
    "zzttzzmyswy/multica-web": {"tags": ["v0.9.0-myswy.0"], "manifests": {"v0.9.0-myswy.0": {"status": 200}}}
  }
}
JSON
if run_guard --tag "$TAG"; then
  ok "guard allowed a new tag in an existing package"
else
  bad "guard refused a new tag in an existing package: $(cat "$TMP/err")"
fi
grep -q "carries no ${TAG} tag" "$TMP/out" \
  && ok "guard distinguished 'package exists, tag does not' from 'package absent'" \
  || bad "guard did not report the existing-package/missing-tag state: $(cat "$TMP/out")"

step "A 403 on the release lookup is not read as 'the tag is free'"
configure <<'JSON'
{"release_status": 403, "repositories": {}}
JSON
if run_guard --tag "$TAG"; then
  bad "guard proceeded after a 403, which would allow an unverified overwrite"
else
  ok "guard refused on a 403"
fi
grep -qi "refused\|not evidence" "$TMP/err" \
  && ok "the failure explains that a permission error is not proof of absence" \
  || bad "the failure does not explain the distinction: $(cat "$TMP/err")"

step "A 401 on the release lookup is not read as 'the tag is free'"
configure <<'JSON'
{"release_status": 401, "repositories": {}}
JSON
run_guard --tag "$TAG" \
  && bad "guard proceeded after a 401" \
  || ok "guard refused on a 401"

step "A 5xx on the release lookup is not read as 'the tag is free'"
for code in 500 502 503; do
  configure <<JSON
{"release_status": $code, "repositories": {}}
JSON
  if run_guard --tag "$TAG"; then
    bad "guard proceeded after HTTP $code"
  else
    ok "guard refused on HTTP $code"
  fi
done

step "A refused registry token is not read as 'the image is free'"
# This is the first-publish case that actually broke: an anonymous lookup of a
# package that does not exist is refused, not answered.
configure <<'JSON'
{"release_status": 404, "token_status": 403, "repositories": {}}
JSON
if run_guard --tag "$TAG"; then
  bad "guard proceeded after the registry refused its credentials"
else
  ok "guard refused when the registry refused its credentials"
fi
grep -qi "refused" "$TMP/err" \
  && ok "the failure reports the refusal instead of swallowing it" \
  || bad "the failure does not report the refusal: $(cat "$TMP/err")"

step "A 5xx from the registry is not read as 'the image is free'"
configure <<'JSON'
{"release_status": 404, "token_status": 503, "repositories": {}}
JSON
run_guard --tag "$TAG" \
  && bad "guard proceeded after a registry 5xx" \
  || ok "guard refused on a registry 5xx"

step "An anonymous registry lookup is never attempted"
# The guard must not be able to reach the anonymous path at all: for a package
# that does not exist ghcr.io answers 403 there, which is unreadable. Missing
# credentials are a hard error, not a fallback.
configure <<'JSON'
{"release_status": 404, "repositories": {}}
JSON
: >"$REQUEST_LOG"
env -i \
  PATH="/usr/bin:/bin:/usr/local/bin" \
  HOME="$TMP" \
  GITHUB_TOKEN=test-token \
  GITHUB_REPOSITORY=zzttzzmyswy/multica \
  GITHUB_API_URL="http://127.0.0.1:${PORT}" \
  REGISTRY_API_BASE="http://127.0.0.1:${PORT}" \
  REGISTRY_TOKEN_URL="http://127.0.0.1:${PORT}/token" \
  bash "$GUARD" --tag "$TAG" >"$TMP/out" 2>"$TMP/err" \
  && bad "guard published without registry credentials" \
  || ok "guard refused to check the registry without credentials"
grep -q "GHCR_USERNAME and GHCR_TOKEN" "$TMP/err" \
  && ok "the failure names the missing credentials" \
  || bad "the failure does not name the missing credentials: $(cat "$TMP/err")"
grep -q "auth=no" "$REQUEST_LOG" \
  && bad "guard sent an unauthenticated request to the registry" \
  || ok "guard sent no unauthenticated registry request"
grep -q '"/token' "$REQUEST_LOG" && bad "guard reached the token endpoint without credentials" \
  || true

step "A bare 404 without an OCI error code is not absence"
configure <<'JSON'
{
  "release_status": 404,
  "repositories": {
    "zzttzzmyswy/multica-backend": {
      "manifests": {"v0.9.0-myswy.1": {"status": 404, "error_code": ""}}
    }
  }
}
JSON
if run_guard --tag "$TAG"; then
  bad "guard read a 404 with no reason as proof that the image is absent"
else
  ok "guard refused to treat an unexplained 404 as absence"
fi
grep -qi "MANIFEST_UNKNOWN\|without" "$TMP/err" \
  && ok "the failure says the registry did not report why the tag was missing" \
  || bad "the failure does not name the missing reason: $(cat "$TMP/err")"

step "An unknown repository 404 without NAME_UNKNOWN is not absence"
configure <<'JSON'
{
  "release_status": 404,
  "repositories": {
    "zzttzzmyswy/multica-backend": {
      "tags_list": {"status": 404, "error_code": ""}
    }
  }
}
JSON
run_guard --tag "$TAG" \
  && bad "guard read an unexplained 404 on the tag list as 'package absent'" \
  || ok "guard refused an unexplained 404 on the tag list"

step "A registry MANIFEST_UNKNOWN is a definitive absence"
configure <<'JSON'
{
  "release_status": 404,
  "repositories": {
    "zzttzzmyswy/multica-backend": {"tags": ["other"], "manifests": {}},
    "zzttzzmyswy/multica-web": {"tags": ["other"], "manifests": {}}
  }
}
JSON
if run_guard --tag "$TAG"; then
  ok "guard treated MANIFEST_UNKNOWN as absent and allowed the publish"
else
  bad "guard refused a genuinely absent image: $(cat "$TMP/err")"
fi

step "The guard performs no write, ever"
# Its contract is read-only. Every request is logged; a mutating verb in the log
# is the failure.
config_first_publish
run_guard --tag "$TAG" >/dev/null 2>&1
if grep -Eq 'WRITE|^(PUT|POST|PATCH|DELETE) ' "$REQUEST_LOG"; then
  bad "guard performed a write; it must be read-only"
else
  ok "guard issued only read requests"
fi
run_guard --tag "$TAG" >/dev/null 2>&1
if grep -Eq 'WRITE|^(PUT|POST|PATCH|DELETE) ' "$REQUEST_LOG"; then
  bad "guard performed a write on a repeat run"
else
  ok "a repeat run also performed zero writes"
fi

step "Only this repository and exact vX.Y.Z-myswy.N tags may publish"
config_first_publish
for bad_tag in v0.9.0 v0.9.0-dirty v1.2.3 0.9.0-myswy.1 latest \
               v0.9.0-myswy.1-extra v0.9.0-myswy v0.9.0-myswy. v0.9.0-MYSWY.1 \
               v0.9.0-myswy.1.2 v0.9.0-rc.1-myswy.1 v0.9.0-myswy.x v0.9-myswy.1; do
  if run_guard --tag "$bad_tag" >/dev/null 2>&1; then
    bad "guard accepted the non-distribution tag '$bad_tag'"
  else
    ok "guard rejected tag '$bad_tag'"
  fi
done
# The boundary in the other direction: a tag that does match the documented
# pattern must not be rejected by an over-strict implementation.
if run_guard --tag "v10.20.30-myswy.41" >/dev/null 2>&1; then
  ok "guard accepted a multi-digit version that matches the pattern"
else
  bad "guard rejected a tag that matches the documented pattern: $(cat "$TMP/err")"
fi
run_guard --tag "$TAG" --repository "multica-ai/multica" >/dev/null 2>&1 \
  && bad "guard accepted an unexpected repository" \
  || ok "guard rejected a repository outside this distribution"

step "A scoped check looks at exactly one artifact"
# `--scope image` is what each merge job runs before its own push, so it must not
# fail because a sibling artifact is already published — that is the normal state
# late in a run that is going fine.
configure <<'JSON'
{
  "release_status": 200,
  "repositories": {
    "zzttzzmyswy/multica-backend": {"manifests": {"v0.9.0-myswy.1": {"status": 200}}},
    "zzttzzmyswy/multica-web": {"manifests": {"v0.9.0-myswy.1": {"status": 404}}}
  }
}
JSON
: >"$REQUEST_LOG"
if run_guard --tag "$TAG" --scope image --image multica-web >"$TMP/out" 2>"$TMP/err"; then
  ok "a web merge is not blocked by an already-published backend tag or release"
else
  bad "a scoped image check failed on a sibling artifact: $(cat "$TMP/err")"
fi
grep -q "multica-backend" "$REQUEST_LOG" \
  && bad "a scoped web check queried the backend repository" \
  || ok "a scoped web check queried only the web repository"

if run_guard --tag "$TAG" --scope image --image multica-backend >/dev/null 2>&1; then
  bad "a scoped image check allowed an existing tag to be re-pushed"
else
  ok "a scoped image check refuses its own existing tag"
fi

configure <<'JSON'
{"release_status": 200, "repositories": {}}
JSON
if run_guard --tag "$TAG" --scope release >/dev/null 2>&1; then
  bad "a scoped release check allowed an existing release"
else
  ok "a scoped release check refuses an existing release"
fi
configure <<'JSON'
{"release_status": 404, "repositories": {}}
JSON
: >"$REQUEST_LOG"
if run_guard --tag "$TAG" --scope release >/dev/null 2>&1; then
  ok "a scoped release check allows an unpublished release"
else
  bad "a scoped release check blocked a free tag: $(cat "$TMP/err")"
fi
grep -q '/v2/' "$REQUEST_LOG" \
  && bad "a scoped release check queried the registry" \
  || ok "a scoped release check queried only the release API"

step "Unknown scopes and images are refused"
run_guard --tag "$TAG" --scope everything >/dev/null 2>&1 \
  && bad "guard accepted an unknown scope" \
  || ok "guard rejected an unknown scope"
run_guard --tag "$TAG" --scope image >/dev/null 2>&1 \
  && bad "guard accepted --scope image without --image" \
  || ok "guard rejected --scope image without --image"
run_guard --tag "$TAG" --scope image --image multica-desktop >/dev/null 2>&1 \
  && bad "guard accepted an image this distribution does not publish" \
  || ok "guard rejected an image outside this distribution"

step "An unreachable API is not read as 'the tag is free'"
# Port 1 is not listening: this is the transport-error branch, not an HTTP one.
env -i \
  PATH="/usr/bin:/bin:/usr/local/bin" \
  HOME="$TMP" \
  GITHUB_TOKEN=test-token \
  GITHUB_REPOSITORY=zzttzzmyswy/multica \
  GITHUB_API_URL="http://127.0.0.1:1" \
  GHCR_USERNAME=zzttzzmyswy \
  GHCR_TOKEN=test-token \
  REGISTRY_API_BASE="http://127.0.0.1:1" \
  REGISTRY_TOKEN_URL="http://127.0.0.1:1/token" \
  bash "$GUARD" --tag "$TAG" >"$TMP/out" 2>"$TMP/err" \
  && bad "guard published when it could not reach the API at all" \
  || ok "guard refused when the API was unreachable"
grep -qi "refusing to publish blind" "$TMP/err" \
  && ok "the failure says it will not publish blind" \
  || bad "the failure does not explain the refusal: $(cat "$TMP/err")"

step "A missing tool is not evidence that a tag is free"
# The reported defect: `docker: command not found` on stderr, exit 127, and the
# old guard read it as "no manifest" because the text contains 'not found'.
# The guard no longer shells out to docker at all; if either of its own tools is
# missing it must say so rather than proceed.
mkdir -p "$TMP/emptybin"
# bash itself has to be reachable to interpret the guard; curl and jq must not be.
ln -sf "$(command -v bash)" "$TMP/emptybin/bash"
env -i \
  PATH="$TMP/emptybin" \
  HOME="$TMP" \
  GITHUB_TOKEN=test-token \
  GITHUB_REPOSITORY=zzttzzmyswy/multica \
  "$TMP/emptybin/bash" "$GUARD" --tag "$TAG" >"$TMP/out" 2>"$TMP/err" \
  && bad "guard proceeded with no curl or jq available" \
  || ok "guard refused to run without its tools"
grep -qi "curl is required\|jq is required" "$TMP/err" \
  && ok "the failure names the missing tool" \
  || bad "the failure does not name the missing tool: $(cat "$TMP/err")"

# A docker stub that is on PATH and exits 127 with the misleading message must
# change nothing: the guard does not consult docker, so its absence or failure is
# irrelevant to the verdict.
mkdir -p "$TMP/dockerbin"
cat >"$TMP/dockerbin/docker" <<'STUB'
#!/usr/bin/env bash
echo "docker: command not found" >&2
exit 127
STUB
chmod +x "$TMP/dockerbin/docker"
config_first_publish
if env -i \
  PATH="$TMP/dockerbin:/usr/bin:/bin:/usr/local/bin" \
  HOME="$TMP" \
  GITHUB_TOKEN=test-token \
  GITHUB_REPOSITORY=zzttzzmyswy/multica \
  GITHUB_API_URL="http://127.0.0.1:${PORT}" \
  GHCR_USERNAME=zzttzzmyswy \
  GHCR_TOKEN=test-token \
  REGISTRY_API_BASE="http://127.0.0.1:${PORT}" \
  REGISTRY_TOKEN_URL="http://127.0.0.1:${PORT}/token" \
  bash "$GUARD" --tag "$TAG" >"$TMP/out" 2>"$TMP/err"; then
  ok "a broken docker on PATH cannot change the verdict"
else
  bad "a broken docker on PATH broke the guard: $(cat "$TMP/err")"
fi

printf '\n'
if [ "$FAIL" -eq 0 ]; then
  printf '\033[32m%s checks passed\033[0m\n' "$PASS"
  exit 0
fi
printf '\033[31m%s passed, %s failed\033[0m\n' "$PASS" "$FAIL"
for f in "${FAILURES[@]}"; do printf '  - %s\n' "$f"; done
exit 1
