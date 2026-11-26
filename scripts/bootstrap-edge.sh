#!/usr/bin/env bash
# 新机器初始化：Docker -> edge 网络 -> 共享 nginx-gateway -> 续期 cron。
# 可重复执行：只覆盖代码，不覆盖 sites/ certs/ acme/ wwwlogs/ projects/ 里的已有数据。
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

EDGE_ROOT="${EDGE_ROOT:-/opt/edge}"
EDGE_NETWORK="${EDGE_NETWORK:-edge}"
INSTALL_DOCKER=0
NO_START=0
NO_BUILD=0
NO_CRON=0
NO_COPY=0
FORCE=0

usage() {
    cat <<'USAGE'
用法：
  sudo ./scripts/bootstrap-edge.sh [options]

选项：
  --edge-root DIR        网关安装根目录，默认 /opt/edge
  --edge-network NAME    共享网络名，默认 edge
  --install-docker       Docker 不存在时用 get.docker.com 安装（仅 Linux/root）
  --no-start             只安装文件，不启动 gateway
  --no-build             不执行 docker build，直接用现有镜像启动
  --no-cron              不安装证书续期/检查 cron
  --no-copy              不复制代码，直接使用当前目录（适合已经在 /opt/edge/nginx-gateway 的情况）
  --force                覆盖 sites/00-default.conf 和 projects/example.env.example
  -h, --help             显示帮助

默认布局：
  /opt/edge/nginx-gateway/
    sites/ certs/ acme/ wwwlogs/ streams/ projects/
    scripts/ docker-compose.gateway.yml

安装后：
  cd /opt/edge/nginx-gateway
  cp projects/example.env.example projects/a.env
  vi projects/a.env
  ./scripts/register-project.sh a
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --edge-root)
            [[ $# -ge 2 ]] || die "--edge-root requires a value"
            EDGE_ROOT="$2"
            shift 2
            ;;
        --edge-network)
            [[ $# -ge 2 ]] || die "--edge-network requires a value"
            EDGE_NETWORK="$2"
            shift 2
            ;;
        --install-docker) INSTALL_DOCKER=1; shift ;;
        --no-start) NO_START=1; shift ;;
        --no-build) NO_BUILD=1; shift ;;
        --no-cron) NO_CRON=1; shift ;;
        --no-copy) NO_COPY=1; shift ;;
        --force) FORCE=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown option: $1" ;;
    esac
done

[[ "$EDGE_ROOT" == /* ]] || die "--edge-root must be an absolute path"
[[ "$EDGE_NETWORK" =~ ^[A-Za-z0-9_.-]+$ ]] || die "invalid network name: $EDGE_NETWORK"

SOURCE_DIR="$BASE_DIR"
TARGET_DIR="${EDGE_ROOT}/nginx-gateway"

log "edge root:  $EDGE_ROOT"
log "gateway:    $TARGET_DIR"
log "network:    $EDGE_NETWORK"

# ── 1. Docker ────────────────────────────────────────────────────────────────
if ! command -v docker >/dev/null 2>&1; then
    if [[ "$INSTALL_DOCKER" != "1" ]]; then
        die "docker not found. Install Docker first, or rerun with --install-docker (Linux/root)."
    fi
    [[ "$(uname -s)" == "Linux" ]] || die "--install-docker only supports Linux"
    [[ "${EUID}" -eq 0 ]] || die "--install-docker requires root"
    require_cmd curl
    TMP_INSTALL="$(mktemp)"
    trap 'rm -f "$TMP_INSTALL"' EXIT
    log "installing Docker via get.docker.com"
    curl -fsSL https://get.docker.com -o "$TMP_INSTALL"
    sh "$TMP_INSTALL"
    systemctl enable --now docker 2>/dev/null || true
    rm -f "$TMP_INSTALL"
    trap - EXIT
fi

if ! docker info >/dev/null 2>&1; then
    if [[ "${EUID}" -eq 0 ]]; then
        systemctl start docker 2>/dev/null || true
    fi
    docker info >/dev/null 2>&1 || die "docker daemon is not running or not accessible"
fi

docker compose version >/dev/null 2>&1 || die "docker compose v2 plugin is required"

# ── 2. 共享网络 ──────────────────────────────────────────────────────────────
if docker network inspect "$EDGE_NETWORK" >/dev/null 2>&1; then
    log "network '$EDGE_NETWORK' already exists"
else
    docker network create "$EDGE_NETWORK" >/dev/null
    log "created network '$EDGE_NETWORK'"
fi

# ── 3. 安装/更新网关文件 ─────────────────────────────────────────────────────
if ! mkdir -p "$EDGE_ROOT" "$TARGET_DIR" 2>/dev/null; then
    die "cannot create $TARGET_DIR; run as root or set --edge-root to a writable path"
fi

for d in sites certs acme wwwlogs streams letsencrypt letsencrypt-lib projects; do
    mkdir -p "$TARGET_DIR/$d"
done

if [[ "$NO_COPY" != "1" && "$SOURCE_DIR" != "$TARGET_DIR" ]]; then
    for f in Dockerfile .dockerignore nginx.conf docker-compose.gateway.yml README.md SPEC.md AI-INTEGRATION.md; do
        [[ -f "$SOURCE_DIR/$f" ]] && cp -f "$SOURCE_DIR/$f" "$TARGET_DIR/$f"
    done
    for d in conf.d snippets stream.d scripts onboarding; do
        [[ -d "$SOURCE_DIR/$d" ]] || continue
        mkdir -p "$TARGET_DIR/$d"
        cp -R "$SOURCE_DIR/$d/." "$TARGET_DIR/$d/"
    done

    if [[ "$FORCE" == "1" ]]; then
        cp -f "$SOURCE_DIR/sites/00-default.conf" "$TARGET_DIR/sites/00-default.conf"
    elif [[ ! -f "$TARGET_DIR/sites/00-default.conf" ]]; then
        # 只在 sites 完全为空时铺默认站；已有任意站点时不要重新塞回 default。
        shopt -s nullglob
        existing_sites=("$TARGET_DIR/sites"/*.conf)
        shopt -u nullglob
        if [[ "${#existing_sites[@]}" -eq 0 ]]; then
            cp -f "$SOURCE_DIR/sites/00-default.conf" "$TARGET_DIR/sites/00-default.conf"
        fi
    fi
    if [[ ! -f "$TARGET_DIR/sites/20-app2.conf.example" ]]; then
        cp -f "$SOURCE_DIR/sites/20-app2.conf.example" "$TARGET_DIR/sites/20-app2.conf.example"
    fi
    if [[ ! -f "$TARGET_DIR/projects/example.env.example" || "$FORCE" == "1" ]]; then
        cp -f "$SOURCE_DIR/projects/example.env.example" "$TARGET_DIR/projects/example.env.example"
    fi
    if [[ ! -f "$TARGET_DIR/projects/README.md" ]]; then
        cp -f "$SOURCE_DIR/projects/README.md" "$TARGET_DIR/projects/README.md"
    fi
else
    log "source is target or --no-copy set; using files in place"
fi

chmod +x "$TARGET_DIR/scripts"/*.sh 2>/dev/null || true
chmod 0700 "$TARGET_DIR/certs" 2>/dev/null || true

# ── 4. 启动 ──────────────────────────────────────────────────────────────────
if [[ "$NO_START" != "1" ]]; then
    cd "$TARGET_DIR"
    if [[ "$NO_BUILD" == "1" ]]; then
        docker compose -f docker-compose.gateway.yml up -d
    else
        docker compose -f docker-compose.gateway.yml up -d --build
    fi
    docker compose -f docker-compose.gateway.yml ps

    ok=0
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        if docker exec nginx-gateway wget -q -O - http://127.0.0.1:8080/healthz >/dev/null 2>&1; then
            ok=1
            break
        fi
        sleep 1
    done
    [[ "$ok" == "1" ]] || die "gateway health check failed; inspect: docker compose -f docker-compose.gateway.yml logs gateway"
    log "gateway is healthy"
else
    log "start skipped (--no-start)"
fi

# ── 5. 证书续期/检查 cron ───────────────────────────────────────────────────
if [[ "$NO_CRON" != "1" ]]; then
    if [[ "${EUID}" -eq 0 ]]; then
        cat > /etc/cron.d/nginx-gateway-renew <<EOF
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
17 3 * * * root cd $TARGET_DIR && ./scripts/renew-certs.sh >> wwwlogs/renew.log 2>&1
17 4 * * * root cd $TARGET_DIR && ./scripts/check-certs.sh >> wwwlogs/cert-check.log 2>&1
EOF
        chmod 0644 /etc/cron.d/nginx-gateway-renew
        log "installed /etc/cron.d/nginx-gateway-renew"
    else
        log "not root; add this cron manually:"
        log "17 3 * * * cd $TARGET_DIR && ./scripts/renew-certs.sh >> wwwlogs/renew.log 2>&1"
        log "17 4 * * * cd $TARGET_DIR && ./scripts/check-certs.sh >> wwwlogs/cert-check.log 2>&1"
    fi
fi

cat <<EOF

bootstrap done.

gateway:   $TARGET_DIR
projects:  $TARGET_DIR/projects
network:   $EDGE_NETWORK

next:
  cd $TARGET_DIR
  cp projects/example.env.example projects/a.env
  vi projects/a.env
  ./scripts/register-project.sh a
EOF
