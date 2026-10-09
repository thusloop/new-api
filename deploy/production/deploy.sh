#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

if [[ $EUID -ne 0 || $# -ne 4 ]]; then
  printf 'Run as root with: DOMAIN IMAGE_DIGEST APP_VERSION ARCHIVE_SHA256\n' >&2
  exit 1
fi

domain=$1
image=$2
version=$3
archive_sha256=$4
[[ "$domain" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*\.[a-zA-Z]{2,63}$ ]]
[[ "$image" =~ ^ghcr\.io/[a-z0-9._/-]+@sha256:[a-f0-9]{64}$ ]]
[[ "$version" =~ ^deploy-[a-f0-9]{40}$ ]]
[[ "$archive_sha256" =~ ^[a-f0-9]{64}$ ]]
image_base=${image%@sha256:*}

source_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
[[ "$source_dir" =~ ^/var/tmp/new-api-deploy\.[a-zA-Z0-9]+$ ]]
deploy_root=/opt/new-api-production
exec 9>/var/lock/new-api-production.lock
flock -n 9 || { printf 'Another deployment is running.\n' >&2; exit 1; }

# Ubuntu's release codename selects Docker's matching signed package repository.
# shellcheck source=/dev/null
source /etc/os-release
[[ "$ID" == ubuntu && "$(uname -m)" == x86_64 ]]
export DEBIAN_FRONTEND=noninteractive
if ! command -v curl >/dev/null || ! command -v jq >/dev/null || ! command -v openssl >/dev/null; then
  apt-get -o DPkg::Lock::Timeout=120 update
  apt-get -o DPkg::Lock::Timeout=120 install -y ca-certificates curl jq openssl gnupg
fi
if ! command -v docker >/dev/null || ! docker compose version >/dev/null 2>&1; then
  apt-get -o DPkg::Lock::Timeout=120 update
  apt-get -o DPkg::Lock::Timeout=120 install -y ca-certificates curl gnupg
  install -d -m 755 /etc/apt/keyrings
  curl --fail --silent --show-error --retry 3 https://download.docker.com/linux/ubuntu/gpg |
    gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
  chmod 644 /etc/apt/keyrings/docker.gpg
  printf 'deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu %s stable\n' \
    "$VERSION_CODENAME" > /etc/apt/sources.list.d/docker.list
  apt-get -o DPkg::Lock::Timeout=120 update
  apt-get -o DPkg::Lock::Timeout=120 install -y \
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi
systemctl enable --now docker
docker info >/dev/null

if [[ -L "$deploy_root" ]]; then
  printf 'Deployment directory must not be a symlink.\n' >&2
  exit 1
fi
install -d -m 700 "$deploy_root" "$deploy_root/releases" "$deploy_root/backups" \
  "$deploy_root/data" "$deploy_root/logs" "$deploy_root/maintenance"
if [[ -e "$deploy_root/current" && ! -L "$deploy_root/current" ]]; then
  printf 'The current release path must be a symlink.\n' >&2
  exit 1
fi
release_dir=''
maintenance_started=false
new_app_started=false
old_container=''
old_app_running=false

cleanup() {
  result=$?
  trap - EXIT
  if ((result != 0)); then
    # Only restart the unchanged container if failure happened before the new app ran.
    if $maintenance_started && ! $new_app_started && $old_app_running; then
      if docker start "$old_container" >/dev/null; then
        for ((attempt = 0; attempt < 15; attempt++)); do
          if [[ "$(docker inspect -f '{{.State.Health.Status}}' "$old_container")" == healthy ]]; then
            rm -f "$deploy_root/maintenance/maintenance"
            break
          fi
          sleep 2
        done
      fi
    fi
    printf 'Deployment failed. Release files: %s\n' "$release_dir" >&2
    printf 'Backups: %s/backups. No database restore was performed.\n' "$deploy_root" >&2
    if [[ -f "$deploy_root/maintenance/maintenance" ]]; then
      printf 'Maintenance mode remains enabled. Correct the failure and rerun this workflow.\n' >&2
    fi
  fi
  rm -rf -- "$source_dir"
  exit "$result"
}
trap cleanup EXIT
trap 'exit 143' TERM
trap 'exit 130' INT

printf 'Verifying transferred image archive.\n'
printf '%s  %s\n' "$archive_sha256" "$source_dir/images.tar.gz" | sha256sum --check
jq -e --arg version "$version" --arg base "$image_base" --arg source "$image" '
  .version == $version and .image_base == $base and
  (.images | keys) == ["caddy", "new-api", "postgres", "redis"] and
  (.images | to_entries | all(
    .value.reference == ($base + ":" + $version + "-" + .key + "-" + (.value.id | ltrimstr("sha256:"))) and
    (.value.id | test("^sha256:[a-f0-9]{64}$"))
  )) and .images["new-api"].source == $source
' "$source_dir/images.json" > /dev/null
printf 'Importing transferred images (10-minute limit).\n'
timeout --foreground --signal=TERM --kill-after=30s 10m docker load --input "$source_dir/images.tar.gz"
while IFS=$'\t' read -r service reference expected_id; do
  actual_id=$(docker image inspect -f '{{.Id}}' "$reference")
  if [[ "$actual_id" != "$expected_id" ]]; then
    printf 'Imported image ID mismatch for %s.\n' "$service" >&2
    exit 1
  fi
done < <(jq -r '.images | to_entries[] | [.key, .value.reference, .value.id] | @tsv' "$source_dir/images.json")
image=$(jq -r '.images["new-api"].reference' "$source_dir/images.json")

existing_database=false
if docker volume inspect new-api-production-postgres >/dev/null 2>&1; then
  existing_database=true
fi
if ! $existing_database && [[ -e "$deploy_root/current" || -L "$deploy_root/current" ]]; then
  printf 'The existing installation has lost its database volume; restore it before deploying.\n' >&2
  exit 1
fi

if [[ ! -f "$deploy_root/.env" ]]; then
  if $existing_database || [[ -e "$deploy_root/current" || -L "$deploy_root/current" ]]; then
    printf 'Existing installation has no .env; restore its original secrets before deploying.\n' >&2
    exit 1
  fi
  if ! docker network inspect new-api-production-edge >/dev/null 2>&1; then
    docker network create new-api-production-edge >/dev/null
  fi
  proxy_subnet=$(docker network inspect -f '{{(index .IPAM.Config 0).Subnet}}' new-api-production-edge)
  {
    printf 'DEPLOY_ROOT=%s\nPROXY_SUBNET=%s\n' "$deploy_root" "$proxy_subnet"
    printf 'POSTGRES_PASSWORD=%s\n' "$(openssl rand -hex 32)"
    printf 'REDIS_PASSWORD=%s\n' "$(openssl rand -hex 32)"
    printf 'SESSION_SECRET=%s\n' "$(openssl rand -hex 32)"
    printf 'CRYPTO_SECRET=%s\n' "$(openssl rand -hex 32)"
  } > "$deploy_root/.env.pending"
  for service in postgres redis caddy; do
    reference=$(jq -r --arg service "$service" '.images[$service].reference' "$source_dir/images.json")
    expected_id=$(jq -r --arg service "$service" '.images[$service].id' "$source_dir/images.json")
    printf '%s_IMAGE=%s\n%s_IMAGE_ID=%s\n' \
      "${service^^}" "$reference" "${service^^}" "$expected_id" >> "$deploy_root/.env.pending"
  done
  install -m 600 "$source_dir/images.json" "$deploy_root/infrastructure-images.json"
  mv "$deploy_root/.env.pending" "$deploy_root/.env"
fi
chmod 600 "$deploy_root/.env"
declare DEPLOY_ROOT PROXY_SUBNET POSTGRES_IMAGE REDIS_IMAGE CADDY_IMAGE
set -a
# shellcheck source=/dev/null
source "$deploy_root/.env"
set +a
: "${DEPLOY_ROOT:?}" "${PROXY_SUBNET:?}" "${POSTGRES_IMAGE:?}" "${REDIS_IMAGE:?}" "${CADDY_IMAGE:?}"
[[ "$DEPLOY_ROOT" == "$deploy_root" ]]
# Existing infrastructure remains pinned; an application release must not upgrade it.
for service in postgres redis caddy; do
  variable="${service^^}_IMAGE"
  id_variable="${service^^}_IMAGE_ID"
  reference=${!variable}
  if ! actual_id=$(docker image inspect -f '{{.Id}}' "$reference"); then
    printf 'Pinned %s image is missing; restore it before deploying.\n' "$service" >&2
    exit 1
  fi
  if [[ -v "$id_variable" && "$actual_id" != "${!id_variable}" ]]; then
    printf 'Pinned %s image ID has changed; deployment stopped.\n' "$service" >&2
    exit 1
  fi
done
if ! docker network inspect new-api-production-edge >/dev/null 2>&1; then
  docker network create --subnet "$PROXY_SUBNET" new-api-production-edge >/dev/null
fi
actual_subnet=$(docker network inspect -f '{{(index .IPAM.Config 0).Subnet}}' new-api-production-edge)
[[ "$actual_subnet" == "$PROXY_SUBNET" ]]

release_dir=$(mktemp -d "$deploy_root/releases/${version}.XXXXXXXX")
install -m 600 "$source_dir/compose.yml" "$release_dir/compose.yml"
install -m 600 "$source_dir/Caddyfile" "$release_dir/Caddyfile"
install -m 600 "$source_dir/images.json" "$release_dir/images.json"
printf 'APP_DOMAIN=%s\nNEW_API_IMAGE=%s\n' "$domain" "$image" > "$release_dir/release.env"
compose=(docker compose --project-name new-api-production
  --env-file "$deploy_root/.env" --env-file "$release_dir/release.env"
  -f "$release_dir/compose.yml")
"${compose[@]}" config --quiet
docker run --rm --pull=never -e "APP_DOMAIN=$domain" \
  -v "$release_dir/Caddyfile:/etc/caddy/Caddyfile:ro" \
  -v "$deploy_root/maintenance:/srv:ro" \
  "$CADDY_IMAGE" caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile

old_container=$("${compose[@]}" ps --all --quiet new-api)
if [[ -n "$old_container" && "$(docker inspect -f '{{.State.Running}}' "$old_container")" == true ]]; then
  old_app_running=true
fi
touch "$deploy_root/maintenance/maintenance"
maintenance_started=true
"${compose[@]}" up -d --wait --wait-timeout 120 postgres redis
if [[ -n "$old_container" ]]; then
  "${compose[@]}" stop --timeout 30 new-api
fi

if $existing_database; then
  backup_dir=$(mktemp -d "$deploy_root/backups/$(date -u +%Y%m%dT%H%M%SZ).XXXXXXXX")
  "${compose[@]}" exec -T postgres pg_dump -U newapi -d new-api -Fc > "$backup_dir/database.dump.partial"
  test -s "$backup_dir/database.dump.partial"
  "${compose[@]}" exec -T postgres pg_restore --list < "$backup_dir/database.dump.partial" > /dev/null
  mv "$backup_dir/database.dump.partial" "$backup_dir/database.dump"
  cp "$deploy_root/.env" "$backup_dir/server.env"
  if [[ -f "$deploy_root/infrastructure-images.json" ]]; then
    cp "$deploy_root/infrastructure-images.json" "$backup_dir/"
  fi
  tar -czf "$backup_dir/data.tar.gz" -C "$deploy_root" data
  if [[ -L "$deploy_root/current" ]]; then
    previous_release=$(readlink -f "$deploy_root/current")
    [[ "$previous_release" == "$deploy_root/releases/"* ]]
    cp "$previous_release/compose.yml" "$previous_release/Caddyfile" \
      "$previous_release/release.env" "$backup_dir/"
    if [[ -f "$previous_release/images.json" ]]; then
      cp "$previous_release/images.json" "$backup_dir/"
    fi
  fi
  printf 'Pre-deployment backup: %s\n' "$backup_dir"
fi

# Once this starts, schema migration may have run; never blindly roll the image back.
new_app_started=true
"${compose[@]}" up -d --no-deps --wait --wait-timeout 300 new-api
"${compose[@]}" up -d --no-deps caddy
curl --fail --silent --show-error --retry 24 --retry-all-errors \
  --retry-delay 5 --connect-timeout 5 --max-time 10 \
  --resolve "$domain:443:127.0.0.1" "https://$domain/api/status" |
  jq -e --arg version "$version" '.success == true and .data.version == $version' > /dev/null
ln -sfn "$release_dir" "$deploy_root/current"
rm -f "$deploy_root/maintenance/maintenance"
maintenance_started=false
printf 'Deployment succeeded: https://%s (%s)\n' "$domain" "$version"
