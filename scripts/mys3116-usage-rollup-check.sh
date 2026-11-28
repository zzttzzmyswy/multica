#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
: "${ADMIN_DSN:?set ADMIN_DSN to the isolated PostgreSQL connection URI}"

case "${1:---read-only}" in
  --read-only)
    # One read-only snapshot of the restored database, including every workspace.
    psql -X "$ADMIN_DSN" -v ON_ERROR_STOP=1 <<'SQL'
BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY;
DO $$ BEGIN
    IF (SELECT count(*) FROM schema_migrations WHERE version IN
        ('739_task_usage_hourly_squad_col','759_task_usage_hourly_rollup_hour_key')) <> 2 THEN
        RAISE EXCEPTION 'required 739 and 759 ledger entries missing';
    END IF;
END $$;
\i mys3116-usage-compare.sql
\if :matches
COMMIT;
\else
DO $$ BEGIN RAISE EXCEPTION 'hourly usage differs from raw usage'; END $$;
\endif
SQL
    ;;
  --fixture)
    # Only the database created here receives fixture rows and rollup writes.
    fixture_db="mys3116_usage_$(python3 -c 'import uuid; print(uuid.uuid4().hex)')"
    fixture_dsn=$(python3 - "$fixture_db" <<'PY'
import os, sys
from urllib.parse import urlsplit, urlunsplit, parse_qsl
uri = urlsplit(os.environ["ADMIN_DSN"])
if uri.scheme not in ("postgres", "postgresql") or any(k in {"database", "dbname"} for k, _ in parse_qsl(uri.query)):
    sys.exit("expected a PostgreSQL URI without a database name override")
print(urlunsplit(uri._replace(path="/" + sys.argv[1])))
PY
)
    createdb --maintenance-db="$ADMIN_DSN" --template=template0 "$fixture_db"
    trap 'dropdb --maintenance-db="$ADMIN_DSN" "$fixture_db"' EXIT
    (cd ../server && DATABASE_URL="$fixture_dsn" go run ./cmd/migrate up >/dev/null)
    psql -X "$fixture_dsn" -v ON_ERROR_STOP=1 -f mys3116-usage-fixture.sql
    ;;
  *) echo "usage: $0 [--read-only|--fixture]" >&2; exit 2 ;;
esac
