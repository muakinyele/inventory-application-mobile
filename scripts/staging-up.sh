#!/usr/bin/env bash
#
# Staging, on this machine: build the working tree and run the whole stack in
# Docker.
#
#   ./scripts/staging-up.sh          # build, recreate, verify
#   ./scripts/staging-up.sh --fresh  # the same, on an empty database
#
# There is no remote staging host. A GitHub runner could not reach this
# machine, so the deploy workflow publishes images for a non-production branch
# and stops; this is what actually runs one.
#
# IT VERIFIES RATHER THAN ASSUMES. `docker compose up` answering on the port
# proves nothing: a stack from a previous build answers exactly the same way,
# and a stale one served a two-week-old bundle against a database with no
# inventory tables for long enough to be mistaken for a bug in the app. So the
# checks at the end compare what is running against what is in the tree, and
# the script fails if they disagree.

set -euo pipefail

cd "$(dirname "$0")/.."

fresh=false
[ "${1:-}" = "--fresh" ] && fresh=true

if [ ! -f .env ]; then
  echo "No .env. Copy .env.example and set POSTGRES_PASSWORD and TOKEN_PEPPER." >&2
  exit 1
fi

port="$(grep -E '^WEB_PORT=' .env | cut -d= -f2 | tr -d '[:space:]')"
port="${port:-8080}"
branch="$(git rev-parse --abbrev-ref HEAD)"
commit="$(git rev-parse --short HEAD)"

echo "Staging ← $branch ($commit), serving on http://localhost:$port"
echo

if $fresh; then
  echo "== dropping the database =="
  docker compose down -v
fi

echo "== build =="
docker compose build

echo "== up =="
# --force-recreate, because a container built from an older image is not
# replaced just because a newer image exists.
docker compose up -d --force-recreate --wait

echo
echo "== checks =="
fail=0

check() { # name expected actual
  if [ "$2" = "$3" ]; then
    printf '  ok    %-22s %s\n' "$1" "$3"
  else
    printf '  FAIL  %-22s expected %s, got %s\n' "$1" "$2" "$3"
    fail=1
  fi
}

# The schema drift expects, so a half-migrated database is caught here rather
# than as a 500 from a screen that looks broken.
want_schema=$(grep -oE 'schemaVersion => [0-9]+' server/lib/src/db/database.dart | grep -oE '[0-9]+')
got_schema=$(docker compose exec -T db psql -U "${POSTGRES_USER:-stockpile}" -d "${POSTGRES_DB:-stockpile}" \
  -tAc 'select version from __schema' 2>/dev/null || echo '?')
check "schema version" "$want_schema" "$got_schema"

got_categories=$(docker compose exec -T db psql -U "${POSTGRES_USER:-stockpile}" -d "${POSTGRES_DB:-stockpile}" \
  -tAc "select coalesce(to_regclass('public.categories')::text,'missing')" 2>/dev/null || echo '?')
check "categories table" "categories" "$got_categories"

# The bundle being served is this build's, not one still in the browser's or
# the image's past. The stamp is the hash of main.dart.js, so it cannot match
# by accident.
want_stamp=$(docker compose exec -T web sha256sum /usr/share/nginx/html/main.dart.js 2>/dev/null | cut -c1-12 || echo '?')
got_stamp=$(curl -fsS --max-time 10 "http://localhost:$port/" 2>/dev/null \
  | grep -oE 'flutter_bootstrap\.js\?v=[a-f0-9]+' | cut -d= -f2 || echo '?')
check "served bundle" "$want_stamp" "$got_stamp"

got_health=$(curl -fsS --max-time 10 "http://localhost:$port/healthz" 2>/dev/null | tr -d '[:space:]' || echo '?')
check "web healthz" "ok" "$got_health"

# 401 is the right answer unauthenticated: it proves the API is reachable
# through the proxy and that the route exists. 404 would mean an older API.
got_api=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
  "http://localhost:$port/api/inventory/categories" 2>/dev/null || echo '?')
check "api reachable" "401" "$got_api"

echo
if [ "$fail" -ne 0 ]; then
  echo "Staging is NOT serving this working tree. Try: ./scripts/staging-up.sh --fresh" >&2
  exit 1
fi

echo "Staging is serving $branch ($commit) at http://localhost:$port"

if docker compose run --rm --entrypoint /app/bin/migrate api 2>/dev/null | grep -q 'No administrator exists'; then
  echo
  echo "No administrator yet. Create one with:"
  echo "  docker compose run --rm --entrypoint /app/bin/create_admin api \\"
  echo "    --email you@example.com --name \"Your Name\""
  echo "Claim the link it prints on port $port, not the 8080 it shows."
fi
