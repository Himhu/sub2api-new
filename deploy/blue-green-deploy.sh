#!/usr/bin/env bash
# Deploy a Sub2API image with a zero-downtime blue/green switch.
#
# The script is intended for the server layout used by this deployment:
#   /opt/sub2api/.env                         secrets and admin settings
#   sub2api_sub2api_data                     persistent application volume
#   sub2api_sub2api-network                   database/redis network
#   new-api_new-api-network                   optional shared gateway network
#
# Usage:
#   ./blue-green-deploy.sh sub2api:20260913
#
# The inactive container is recreated on its own loopback port, health checked,
# and then selected by the Sub2API-only Nginx configuration. The previous
# container is left running so a rollback only requires changing the active
# color and reloading Nginx.

set -Eeuo pipefail

BASE_DIR=${BASE_DIR:-/opt/sub2api}
STATE_FILE=${STATE_FILE:-$BASE_DIR/active-color}
NGINX_CONF=${NGINX_CONF:-/etc/nginx/conf.d/sub2api.conf}
NGINX_UPSTREAM_CONF=${NGINX_UPSTREAM_CONF:-/etc/nginx/conf.d/sub2api-upstream.conf}
DATA_VOLUME=${DATA_VOLUME:-sub2api_sub2api_data}
APP_NETWORK=${APP_NETWORK:-sub2api_sub2api-network}
SHARED_NETWORK=${SHARED_NETWORK:-new-api_new-api-network}
HEALTH_TIMEOUT_SECONDS=${HEALTH_TIMEOUT_SECONDS:-180}

if [[ $# -ne 1 ]]; then
  echo "usage: $0 IMAGE_TAG" >&2
  exit 2
fi

IMAGE=$1

log() { printf '[sub2api blue-green] %s\n' "$*"; }
die() { log "ERROR: $*" >&2; exit 1; }

command -v docker >/dev/null || die "docker is required"
command -v nginx >/dev/null || die "nginx is required"
[[ -f "$BASE_DIR/.env" ]] || die "missing $BASE_DIR/.env"
docker image inspect "$IMAGE" >/dev/null 2>&1 || die "image not found locally: $IMAGE"

if [[ -f "$STATE_FILE" ]]; then
  active=$(tr -d '[:space:]' < "$STATE_FILE")
else
  active=blue
fi
[[ "$active" == blue || "$active" == green ]] || die "invalid active color: $active"
if [[ "$active" == blue ]]; then
  inactive=green; inactive_port=8082
else
  inactive=blue; inactive_port=8081
fi

active_name="sub2api-$active"
inactive_name="sub2api-$inactive"
env_file=$(mktemp)
cleanup() { rm -f "$env_file"; }
trap cleanup EXIT
chmod 600 "$env_file"

# Reuse the active container's complete environment. This preserves settings
# added to the server compose file without copying any secret into the repo.
if docker inspect "$active_name" >/dev/null 2>&1; then
  docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$active_name" > "$env_file"
elif docker inspect sub2api >/dev/null 2>&1; then
  # One-time migration from the old single-container name.
  docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' sub2api > "$env_file"
else
  # Fresh installations can use the deployment .env as their environment.
  cp "$BASE_DIR/.env" "$env_file"
fi

log "starting $inactive_name with $IMAGE on 127.0.0.1:$inactive_port"
docker rm -f "$inactive_name" >/dev/null 2>&1 || true
docker run -d \
  --name "$inactive_name" \
  --restart unless-stopped \
  --env-file "$env_file" \
  --ulimit nofile=100000:100000 \
  -p "127.0.0.1:$inactive_port:8080" \
  -v "$DATA_VOLUME:/app/data" \
  --network "$APP_NETWORK" \
  --health-cmd='wget -q -T 5 -O /dev/null http://localhost:8080/health' \
  --health-interval=30s \
  --health-timeout=10s \
  --health-retries=3 \
  --health-start-period=30s \
  "$IMAGE" >/dev/null
docker network connect "$SHARED_NETWORK" "$inactive_name"

deadline=$((SECONDS + HEALTH_TIMEOUT_SECONDS))
status=starting
while (( SECONDS < deadline )); do
  status=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$inactive_name" 2>/dev/null || true)
  case "$status" in
    healthy|running) break ;;
    unhealthy|exited|dead) docker logs --tail 80 "$inactive_name" >&2; die "$inactive_name failed health check ($status)" ;;
  esac
  sleep 3
done
[[ "$status" == healthy || "$status" == running ]] || die "$inactive_name did not become healthy (last status: $status)"

# Keep the hostname used by newAPI stable. Only the instance about to receive
# traffic owns the `sub2api` alias on the shared network. There is a very short
# DNS handoff while the old endpoint is detached; existing connections remain
# open and Nginx is switched only after the new endpoint is ready.
if docker inspect "$active_name" >/dev/null 2>&1; then
  docker network disconnect "$SHARED_NETWORK" "$active_name" >/dev/null 2>&1 || true
  docker network connect "$SHARED_NETWORK" "$active_name"
fi
docker network connect --alias sub2api "$SHARED_NETWORK" "$inactive_name"

timestamp=$(date -u +%Y%m%dT%H%M%SZ)
if [[ -f "$NGINX_CONF" ]]; then
  cp "$NGINX_CONF" "$NGINX_CONF.bak.$timestamp"
fi
cat > "$NGINX_UPSTREAM_CONF" <<EOF
upstream sub2api_upstream {
    server 127.0.0.1:$inactive_port;
    keepalive 256;
}
EOF
if [[ -f "$NGINX_CONF" ]]; then
  sed -i 's#proxy_pass http://127\.0\.0\.1:8080;#proxy_pass http://sub2api_upstream;#g' "$NGINX_CONF"
fi
nginx -t
systemctl reload nginx
printf '%s\n' "$inactive" > "$STATE_FILE"

# Complete the one-time migration after traffic has moved to the new pair.
if docker inspect sub2api >/dev/null 2>&1; then
  docker rm -f sub2api >/dev/null
fi

log "active color: $inactive ($inactive_name, 127.0.0.1:$inactive_port)"
log "previous color remains available for rollback: $active_name"
curl -fsS --max-time 10 http://127.0.0.1:$inactive_port/health >/dev/null || die "post-switch health request failed"
log "deployment complete"
