#!/usr/bin/env bash
# Behavioural tests for scripts/myswy-release-guard.sh.
#
# The guard is the only thing standing between a rerun and an overwritten
# release/image tag. Two failure modes matter and are covered separately:
#
#   * it lets a write through when the tag already exists (the reported defect);
#   * it treats "I could not find out" — a 403, a 5xx, a registry timeout — as
#     "the tag is free", which silently allows the same overwrite.
#
# No network and no registry: the GitHub API is a local stub and the registry
# check is injected through REGISTRY_CHECK_CMD.
set -uo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
GUARD="$SCRIPT_DIR/myswy-release-guard.sh"

PASS=0
FAIL=0
FAILURES=()

ok()   { PASS=$((PASS + 1)); printf '    \033[32m✓\033[0m %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); FAILURES+=("$1"); printf '    \033[31m✗\033[0m %s\n' "$1"; }
step() { printf '\n==> %s\n' "$1"; }

[ -f "$GUARD" ] || { echo "missing $GUARD" >&2; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/myswy-release-guard.XXXXXX")" || exit 1
trap 'rm -rf "$TMP"' EXIT

TAG="v0.9.0-myswy.1"

# A `curl` stub that answers the release-tag lookup with a configurable status.
# Every invocation is logged, so a test can prove no write path was reached.
write_curl_stub() {
  local status=$1
  cat >"$TMP/curl" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"${CURL_LOG:-/dev/null}"
# The guard only uses -w '%{http_code}' with -o /dev/null for the lookup.
printf '%s' "$status"
exit 0
STUB
  chmod +x "$TMP/curl"
}

# Registry stub: exit status and message are configured per case.
write_registry_stub() {
  local status=$1
  local message=${2:-}
  cat >"$TMP/registry-check" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"\${REGISTRY_LOG:-/dev/null}"
echo "$message"
exit $status
STUB
  chmod +x "$TMP/registry-check"
}

# Runs the guard with stubs. Sets $TMP/out and $TMP/err, returns the exit code.
run_guard() {
  : >"$TMP/curl.log"
  : >"$TMP/registry.log"
  env -i \
    PATH="$TMP:$PATH" \
    HOME="$TMP" \
    GITHUB_TOKEN=test-token \
    GITHUB_REPOSITORY=zzttzzmyswy/multica \
    CURL_LOG="$TMP/curl.log" \
    REGISTRY_LOG="$TMP/registry.log" \
    REGISTRY_CHECK_CMD="$TMP/registry-check" \
    bash "$GUARD" "$@" >"$TMP/out" 2>"$TMP/err"
}

# ---------------------------------------------------------------------------

step "Nothing published: the guard allows the write"
write_curl_stub 404
write_registry_stub 1 "not found"
: >"$TMP/registry.log"
if run_guard --tag "$TAG"; then
  ok "guard exited 0"
else
  bad "guard blocked a first publish: $(cat "$TMP/err")"
fi
if grep -q "publishing may proceed" "$TMP/out"; then
  ok "guard reported the tag as free"
else
  bad "guard did not confirm the tag was free: $(cat "$TMP/out")"
fi
checks="$(wc -l <"$TMP/registry.log" | tr -d ' ')"
if [ "$checks" = "2" ]; then
  ok "both image tags were checked before any write"
else
  bad "expected 2 registry checks (backend and web), saw $checks"
fi

step "The release already exists: the guard refuses"
write_curl_stub 200
write_registry_stub 1 "not found"
if run_guard --tag "$TAG"; then
  bad "guard allowed a release to be re-published over existing assets"
else
  ok "guard refused an existing release"
fi
if grep -q "already exists" "$TMP/err"; then
  ok "the refusal says the release already exists"
else
  bad "the refusal does not explain the conflict: $(cat "$TMP/err")"
fi
if [ -s "$TMP/registry.log" ]; then
  bad "guard queried the registry after the release check already failed"
else
  ok "guard stopped before touching the registry"
fi

step "The image tag already exists: the guard refuses"
write_curl_stub 404
# Backend absent, web present: the second check must catch it.
cat >"$TMP/registry-check" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${REGISTRY_LOG:-/dev/null}"
case "$1" in
  *multica-web*) exit 0 ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$TMP/registry-check"
if run_guard --tag "$TAG"; then
  bad "guard allowed an existing image tag to be overwritten"
else
  ok "guard refused an existing image tag"
fi
if grep -q "multica-web" "$TMP/err" && grep -q "already exists" "$TMP/err"; then
  ok "the refusal names the conflicting image"
else
  bad "the refusal does not name the image: $(cat "$TMP/err")"
fi

step "A 403 on the release lookup is not read as 'the tag is free'"
write_curl_stub 403
write_registry_stub 1 "not found"
if run_guard --tag "$TAG"; then
  bad "guard proceeded after a 403, which would allow an unverified overwrite"
else
  ok "guard refused on a 403"
fi
if grep -qi "refused\|not evidence" "$TMP/err"; then
  ok "the failure explains that a permission error is not proof of absence"
else
  bad "the failure does not explain the distinction: $(cat "$TMP/err")"
fi

step "A 5xx on the release lookup is not read as 'the tag is free'"
for code in 500 502 503; do
  write_curl_stub "$code"
  write_registry_stub 1 "not found"
  if run_guard --tag "$TAG"; then
    bad "guard proceeded after HTTP $code"
  else
    ok "guard refused on HTTP $code"
  fi
done

step "An inconclusive registry answer is not read as 'the image is free'"
write_curl_stub 404
# exit 2 models an auth or transport failure rather than a missing manifest.
write_registry_stub 2 "unauthorized: authentication required"
if run_guard --tag "$TAG"; then
  bad "guard proceeded despite an inconclusive registry answer"
else
  ok "guard refused on an inconclusive registry answer"
fi
if grep -qi "inconclusive" "$TMP/err"; then
  ok "the failure names the answer as inconclusive"
else
  bad "the failure does not say the answer was inconclusive: $(cat "$TMP/err")"
fi

step "A registry 'manifest unknown' is a definitive absence"
write_curl_stub 404
write_registry_stub 1 "ERROR: manifest unknown"
if run_guard --tag "$TAG"; then
  ok "guard treated 'manifest unknown' as absent and allowed the publish"
else
  bad "guard refused a genuinely absent image: $(cat "$TMP/err")"
fi

step "Repeating the guard makes no write, ever"
# The guard's contract is that it performs no write at all; it only reads. Prove
# it by asserting no mutating verb appears in any request it made.
write_curl_stub 404
write_registry_stub 1 "not found"
run_guard --tag "$TAG" >/dev/null 2>&1
if grep -Eq -- "-X *(POST|PUT|PATCH|DELETE)|imagetools create|docker push" "$TMP/curl.log" "$TMP/registry.log"; then
  bad "guard performed a write; it must be read-only"
else
  ok "guard issued only read requests"
fi
# Running it twice changes nothing: still no write.
run_guard --tag "$TAG" >/dev/null 2>&1
if grep -Eq -- "-X *(POST|PUT|PATCH|DELETE)|imagetools create|docker push" "$TMP/curl.log" "$TMP/registry.log"; then
  bad "guard performed a write on a repeat run"
else
  ok "a repeat run also performed zero writes"
fi

step "Only this repository and vX.Y.Z-myswy.N tags may publish"
write_curl_stub 404
write_registry_stub 1 "not found"
for bad_tag in v0.9.0 v0.9.0-dirty v1.2.3 0.9.0-myswy.1 latest; do
  if run_guard --tag "$bad_tag" >/dev/null 2>&1; then
    bad "guard accepted the non-distribution tag '$bad_tag'"
  else
    ok "guard rejected tag '$bad_tag'"
  fi
done
if run_guard --tag "$TAG" --repository "multica-ai/multica" >/dev/null 2>&1; then
  bad "guard accepted an unexpected repository"
else
  ok "guard rejected a repository outside this distribution"
fi

printf '\n'
if [ "$FAIL" -eq 0 ]; then
  printf '\033[32m%s checks passed\033[0m\n' "$PASS"
  exit 0
fi
printf '\033[31m%s passed, %s failed\033[0m\n' "$PASS" "$FAIL"
for f in "${FAILURES[@]}"; do printf '  - %s\n' "$f"; done
exit 1
