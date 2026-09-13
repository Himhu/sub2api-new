#!/usr/bin/env bash
# Switch traffic back to the other healthy Sub2API color.
set -Eeuo pipefail

BASE_DIR=${BASE_DIR:-/opt/sub2api}
STATE_FILE=${STATE_FILE:-$BASE_DIR/active-color}
UPSTREAM_CONF=${UPSTREAM_CONF:-/etc/nginx/conf.d/sub2api-upstream.conf}

[[ -f "$STATE_FILE" ]] || { echo "missing active color state: $STATE_FILE" >&2; exit 1; }
active=$(tr -d '[:space:]' < "$STATE_FILE")
[[ "$active" == blue || "$active" == green ]] || { echo "invalid active color: $active" >&2; exit 1; }
if [[ "$active" == blue ]]; then target=green; port=8082; else target=blue; port=8081; fi
target_name="sub2api-$target"

status=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$target_name" 2>/dev/null || true)
[[ "$status" == healthy || "$status" == running ]] || { echo "$target_name is not healthy ($status)" >&2; exit 1; }

timestamp=$(date -u +%Y%m%dT%H%M%SZ)
cp /etc/nginx/conf.d/sub2api.conf "/etc/nginx/conf.d/sub2api.conf.bak.rollback.$timestamp"
cat > "$UPSTREAM_CONF" <<EOF
upstream sub2api_upstream {
    server 127.0.0.1:$port;
    keepalive 256;
}
EOF
nginx -t
systemctl reload nginx
printf '%s\n' "$target" > "$STATE_FILE"
curl -fsS --max-time 10 "http://127.0.0.1:$port/health" >/dev/null
echo "rolled back to $target_name (127.0.0.1:$port)"
