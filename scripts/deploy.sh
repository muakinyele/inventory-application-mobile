#!/usr/bin/env bash
#
# Rolls out the stack on the deployment host. Run from the directory holding
# docker-compose.prod.yml and .env — the deploy workflow puts all three there.
#
#   ./deploy.sh              roll out the tag in .env
#   ./deploy.sh <image-tag>  roll out a specific tag (this is a rollback)
#
# The shape of it: record what is running, migrate, start the new containers,
# wait for health, and put the old tag back if health never arrives.

set -euo pipefail

COMPOSE_FILE="docker-compose.prod.yml"
ENV_FILE=".env"
PREVIOUS_FILE=".previous-tag"

compose() { docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" "$@"; }

log() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
fail() { printf '\n\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

[ -f "$COMPOSE_FILE" ] || fail "$COMPOSE_FILE not found. Run this from the deploy directory."
[ -f "$ENV_FILE" ]     || fail "$ENV_FILE not found. The deploy workflow writes it."

# ---------------------------------------------------------------------------
# Work out what we are deploying, and what we would go back to
# ---------------------------------------------------------------------------

current_tag=$(grep -E '^IMAGE_TAG=' "$ENV_FILE" | cut -d= -f2- || true)
requested_tag="${1:-$current_tag}"
[ -n "$requested_tag" ] || fail "No IMAGE_TAG in $ENV_FILE and none given."

# Whatever is genuinely running right now, not what the file claims — they
# differ precisely when a previous deploy failed halfway, which is the moment
# this matters most.
running_tag=$(compose ps --format json 2>/dev/null \
  | python3 -c "
import sys, json
tags = set()
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        entry = json.loads(line)
    except json.JSONDecodeError:
        continue
    image = entry.get('Image', '')
    if '/api:' in image:
        tags.add(image.rsplit(':', 1)[-1])
print(next(iter(tags)) if len(tags) == 1 else '')
" 2>/dev/null || true)

if [ -n "$running_tag" ] && [ "$running_tag" != "$requested_tag" ]; then
  echo "$running_tag" > "$PREVIOUS_FILE"
fi
rollback_tag=$(cat "$PREVIOUS_FILE" 2>/dev/null || true)

log "Deploying $requested_tag (currently running: ${running_tag:-none})"

# Point the environment file at the tag being deployed.
if grep -qE '^IMAGE_TAG=' "$ENV_FILE"; then
  sed -i.bak -E "s|^IMAGE_TAG=.*|IMAGE_TAG=${requested_tag}|" "$ENV_FILE" && rm -f "$ENV_FILE.bak"
else
  echo "IMAGE_TAG=${requested_tag}" >> "$ENV_FILE"
fi

# ---------------------------------------------------------------------------
# Roll out
# ---------------------------------------------------------------------------

log "Pulling images"
# Pulled before anything stops, so a bad tag or an unreachable registry fails
# while the current release is still serving.
compose pull --quiet db api web || fail "Could not pull $requested_tag. Nothing was changed."

log "Starting the database"
compose up -d --wait db || fail "The database did not become healthy."

log "Running migrations"
# Its own step, to completion, before any new API container serves — two
# replicas racing to create the same table is the failure this avoids.
if ! compose run --rm migrate; then
  fail "Migrations failed. The previous release is still running; nothing was replaced."
fi

log "Starting the application"
# --wait blocks on the healthchecks, so a container that starts and
# immediately falls over is a failed deploy rather than a silent one.
if compose up -d --wait --remove-orphans api web; then
  log "Healthy on $requested_tag"
  compose ps
  docker image prune -f --filter "until=168h" >/dev/null 2>&1 || true
  exit 0
fi

# ---------------------------------------------------------------------------
# Roll back
# ---------------------------------------------------------------------------

printf '\n\033[31mThe new release did not become healthy.\033[0m\n' >&2
compose logs --tail 60 api web >&2 || true

if [ -z "$rollback_tag" ]; then
  fail "No previous tag recorded, so there is nothing to roll back to. The stack is down — deploy a known-good tag with: ./deploy.sh <tag>"
fi

log "Rolling back to $rollback_tag"
sed -i.bak -E "s|^IMAGE_TAG=.*|IMAGE_TAG=${rollback_tag}|" "$ENV_FILE" && rm -f "$ENV_FILE.bak"

# Deliberately not re-run: migrations are forward-only, and the previous
# release's code has to tolerate the new schema. Additive migrations — which
# these are — make that true; a destructive one would not, and would need a
# considered manual step instead.
if compose up -d --wait api web; then
  fail "Rolled back to $rollback_tag. The deploy of $requested_tag failed; see the logs above."
fi

fail "Rollback to $rollback_tag also failed. The stack is down and needs a look."
