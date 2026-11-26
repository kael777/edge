#!/usr/bin/env bash
# 校验并热加载 nginx-gateway。
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

require_cmd docker
container_running || die "container '$CONTAINER' is not running"

docker exec "$CONTAINER" nginx -t
docker exec "$CONTAINER" nginx -s reload
log "nginx-gateway reloaded"
