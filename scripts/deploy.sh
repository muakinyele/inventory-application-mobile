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

# ---------------------------------------------------------------------------
# Retire the previous project name, if one is still running
# ---------------------------------------------------------------------------
# The compose project was renamed from `stockpile` to `inv`, and Compose keys
# everything on that name: containers, network, and the `docker compose down`
# that would otherwise stop them. So a host that ran the old name keeps those
# containers alive and *holding the published port*, and the new stack then
# fails to bind with an error that says nothing about why.
#
# Stopping it here is idempotent — on a host that never ran the old name this
# finds nothing and says so. The old volume is deliberately left alone: it is
# not this script's business to delete data.
LEGACY_PROJECT="stockpile"
if docker ps -a --format '{{.Names}}' | grep -q "^${LEGACY_PROJECT}-"; then
  log "Stopping the previous project ($LEGACY_PROJECT)"
  docker compose -p "$LEGACY_PROJECT" -f "$COMPOSE_FILE" --env-file "$ENV_FILE" down --remove-orphans 2>/dev/null \
    || docker rm -f $(docker ps -aq --filter "name=^${LEGACY_PROJECT}-") 2>/dev/null \
    || true
  echo "  Its volume (${LEGACY_PROJECT}_db-data) is left in place. Remove it by hand once you are satisfied nothing is needed from it."
fi

log "Pulling images"
# The compose file names images as `inv/api:<tag>` so that `docker ps` shows
# something readable rather than sixty characters of registry path. Nothing
# can pull that name, though — it exists only on this host — so the registry
# copy is fetched here and re-tagged.
#
# Pulled before anything stops, so a bad tag or an unreachable registry fails
# while the current release is still serving.
registry="${IMAGE_REGISTRY:-ghcr.io}"
namespace=$(grep -E '^IMAGE_NAMESPACE=' "$ENV_FILE" | cut -d= -f2- || true)
[ -n "$namespace" ] || fail "IMAGE_NAMESPACE is not set in $ENV_FILE."

for service in api web; do
  remote="${registry}/${namespace}/${service}:${requested_tag}"
  local_tag="inv/${service}:${requested_tag}"

  docker pull --quiet "$remote" \
    || fail "Could not pull $remote. Nothing was changed."
  docker tag "$remote" "$local_tag"

  # The registry reference is dropped once the short tag points at the same
  # image, so `docker images` does not list both. The layers are shared, so
  # this frees nothing and loses nothing — it is purely about what is shown.
  docker rmi "$remote" >/dev/null 2>&1 || true
done

# postgres is a public image referenced by its real name, so compose fetches
# it the ordinary way.
compose pull --quiet db || fail "Could not pull the database image."

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
