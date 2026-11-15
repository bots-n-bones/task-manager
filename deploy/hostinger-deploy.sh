#!/usr/bin/env bash
# Install as /usr/local/sbin/task-manager-deploy and use as an SSH forced command.
set -Eeuo pipefail
umask 077
if [[ ! ${SSH_ORIGINAL_COMMAND:-} =~ ^deploy\ ([0-9a-f]{40})$ ]]; then
  echo "Expected deploy followed by a commit SHA" >&2
  exit 2
fi
revision=${BASH_REMATCH[1]}
exec 9>/var/lock/task-manager-deploy.lock
flock -w 900 9
destination=/opt/team-task-manager
staging=$(mktemp -d /opt/task-manager-release.XXXXXX)
trap 'rm -rf "$staging"' EXIT
curl --fail --silent --show-error --location --retry 3 \
  "https://api.github.com/repos/bots-n-bones/task-manager/tarball/$revision" -o "$staging/source.tar.gz"
mkdir "$staging/source"
tar -xzf "$staging/source.tar.gz" --strip-components=1 -C "$staging/source"
cd "$staging/source"
# Checks execute in the same Node major version as production.
docker run --rm -v "$PWD:/source:ro" -w /source node:24-alpine sh -ec \
  'for source in web/*.js web/*.mjs server/*.mjs bot/*.mjs; do node --check "$source"; done; node scripts/checks/browser-compatibility.mjs'
cd "$destination"
python3 deploy/backup.py
docker image tag deploy-web:latest task-manager-web:previous
docker image tag deploy-bot:latest task-manager-bot:previous
# Keep the previous source alongside its runtime images for a failed release.
mkdir "$staging/previous"
for path in web server bot deploy Dockerfile package.json package-lock.json .dockerignore; do
  cp -a "$path" "$staging/previous/"
done
# Environment and database volumes stay on the server.
for path in web server bot; do
  rsync -a --delete "$staging/source/$path/" "$destination/$path/"
done
rsync -a --exclude='.env*' "$staging/source/deploy/" "$destination/deploy/"
cp "$staging/source/"{Dockerfile,package.json,package-lock.json,.dockerignore} .
rollback() {
  echo "Deployment failed. Restoring previous application." >&2
  for path in web server bot deploy; do
    rsync -a --delete "$staging/previous/$path/" "$destination/$path/"
  done
  cp "$staging/previous/"{Dockerfile,package.json,package-lock.json,.dockerignore} .
  docker image tag task-manager-web:previous deploy-web:latest
  docker image tag task-manager-bot:previous deploy-bot:latest
  docker compose -f deploy/compose.yml up -d --no-deps --no-build --force-recreate --wait --wait-timeout 120 web bot
}
if ! docker compose -f deploy/compose.yml build web bot; then
  rollback
  exit 1
fi
if ! docker compose -f deploy/compose.yml up -d --no-deps --no-build --wait --wait-timeout 120 web bot; then
  rollback
  exit 1
fi
if ! curl --fail --silent --show-error --retry 12 --retry-delay 5 --retry-all-errors https://tasks.molotilka.site/health; then
  rollback
  exit 1
fi
printf '%s\n' "$revision" > "$destination/.deployed-revision"
echo "Deployed $revision"
