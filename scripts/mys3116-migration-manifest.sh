#!/usr/bin/env bash
# Emit a reproducible manifest of this build's migration tree, so the database
# phase can prove the SQL it runs is the SQL this commit contains.
#
# Why this exists: "the candidate migrate binary" is only meaningful together
# with the exact SQL it will read, and a renumbering sync is precisely the case
# where a file can be renamed without its content being what the reviewer saw.
# The manifest pins both — the runner's commit and every file's digest — so a
# mismatch is a failed verification rather than a judgement call.
#
# Usage:
#   bash scripts/mys3116-migration-manifest.sh [OUT_DIR]
#
# Outputs, in OUT_DIR (default: a new temp dir):
#   migrate-manifest.sha256   <sha256>  <relative path>  for every migration file
#   migrate-manifest.tsv      <version> <direction> <sha256> <bytes>  ordered
#   migrate-manifest.json     the same, plus commit, tree hash and counts
#   BUILD.txt                 how to reproduce the migrate binary from this commit
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${1:-$(mktemp -d "${TMPDIR:-/tmp}/migrate-manifest.XXXXXX")}"
mkdir -p "$OUT_DIR"
MIG_DIR="$ROOT_DIR/server/migrations"

cd "$ROOT_DIR"
COMMIT="$(git rev-parse HEAD)"
SHORT="$(git rev-parse --short HEAD)"
DIRTY=""
if ! git diff --quiet HEAD -- server/migrations server/cmd/migrate; then
  DIRTY="-dirty"
fi

# The runner's own source is part of the artifact: the cleanup maps and the
# lineage allowlist in it decide what happens on retry and on a foreign ledger.
RUNNER_FILES=(
  "server/cmd/migrate/main.go"
  "server/internal/migrations/migrations.go"
)

say() { printf '%s\n' "$*"; }

say "commit $COMMIT$DIRTY"
say "migrations directory: $MIG_DIR"

# sha256sum -c compatible, so the database phase can verify in one command.
( cd "$ROOT_DIR" && find server/migrations -name '*.sql' -type f -print0 \
    | sort -z | xargs -0 sha256sum ) >"$OUT_DIR/migrate-manifest.sha256"

{
  printf 'version\tdirection\tsha256\tbytes\tfile\n'
  while IFS= read -r path; do
    base="$(basename "$path")"
    stem="${base%.up.sql}"
    stem="${stem%.down.sql}"
    case "$base" in
      *.up.sql)   direction=up ;;
      *.down.sql) direction=down ;;
      *)          direction=other ;;
    esac
    read -r sum bytes _ < <(sha256sum "$path"; stat -c '%s' "$path" | tr '\n' ' ')
    printf '%s\t%s\t%s\t%s\t%s\n' "$stem" "$direction" "$sum" "$(stat -c '%s' "$path")" "$path"
  done < <(cd "$ROOT_DIR" && find server/migrations -name '*.sql' -type f | LC_ALL=C sort)
} >"$OUT_DIR/migrate-manifest.tsv"

UP_COUNT="$(find "$MIG_DIR" -name '*.up.sql' | wc -l | tr -d ' ')"
DOWN_COUNT="$(find "$MIG_DIR" -name '*.down.sql' | wc -l | tr -d ' ')"
HEAD_VERSION="$(find "$MIG_DIR" -name '*.up.sql' -printf '%f\n' | sed 's/_.*//' | sort -n | tail -1)"
TREE_HASH="$(cd "$ROOT_DIR" && find server/migrations -name '*.sql' -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | cut -d' ' -f1)"

{
  printf '{\n'
  printf '  "commit": "%s",\n' "$COMMIT$DIRTY"
  printf '  "up_migrations": %s,\n' "$UP_COUNT"
  printf '  "down_migrations": %s,\n' "$DOWN_COUNT"
  printf '  "head_version": "%s",\n' "$HEAD_VERSION"
  printf '  "tree_sha256": "%s",\n' "$TREE_HASH"
  printf '  "runner": {\n'
  for f in "${RUNNER_FILES[@]}"; do
    printf '    "%s": "%s",\n' "$f" "$(sha256sum "$ROOT_DIR/$f" | cut -d' ' -f1)"
  done
  printf '    "_": null\n  }\n'
  printf '}\n'
} >"$OUT_DIR/migrate-manifest.json"

cat >"$OUT_DIR/BUILD.txt" <<EOF
Migrate artifact for this release candidate
==========================================

commit:      $COMMIT$DIRTY
head version: $HEAD_VERSION  ($UP_COUNT up / $DOWN_COUNT down files)
tree sha256:  $TREE_HASH

Reproduce the migrate binary from exactly this commit:

    git checkout $COMMIT
    cd server
    go build -trimpath -buildvcs=true -o /tmp/migrate ./cmd/migrate
    sha256sum /tmp/migrate

Verify the SQL in a checkout of this commit against the manifest:

    sha256sum -c migrate-manifest.sha256

Apply, from the checkout whose tree hash matches (the runner resolves
server/migrations relative to its own location, so run it from the tree):

    DATABASE_URL="\$ISOLATED_DSN" /tmp/migrate up

The tree hash covers file CONTENT, not only names: a renumbering that renamed a
file to the right stem but carried the wrong body changes the hash.
EOF

say ""
say "up migrations:   $UP_COUNT"
say "down migrations: $DOWN_COUNT"
say "head version:    $HEAD_VERSION"
say "tree sha256:     $TREE_HASH"
say ""
say "written to $OUT_DIR:"
ls -1 "$OUT_DIR" | sed 's/^/  /'

# A symmetric up/down tree is the structural invariant the runner depends on; a
# one-sided rename would make `migrate down` unable to undo what `up` applied.
if [ "$UP_COUNT" != "$DOWN_COUNT" ]; then
  say ""
  say "NOTE: up and down counts differ ($UP_COUNT vs $DOWN_COUNT). That is
expected only for migrations whose down direction is deliberately absent; check
before shipping."
fi
