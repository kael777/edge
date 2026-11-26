#!/usr/bin/env bash
# 新增站点：生成 sites/<priority>-<site>.conf + sites/.meta/<site>.env
# 有证书时直接生成 HTTPS；无证书时先生成 HTTP + ACME，签发后再 enable-https.sh。
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

usage() {
    cat <<'USAGE'
用法：
  add-site.sh <site> <domain> --upstream host:port [options]
  add-site.sh <site> <domain> --root /srv/<site> [options]

参数：
  --upstream host:port   反代上游，容器服务名:端口，例如 app2:3000
  --root /srv/<site>     静态站点在容器内的根目录（宿主机需只读挂载到该路径）
  --body-size SIZE       client_max_body_size，默认 1m，例如 16m
  --websocket            额外生成 /ws/ 反代（仅 proxy 模式）
  --admin-allowlist LIST 管理面板 IP/CIDR 白名单，逗号分隔；仅 proxy 模式
  --admin-path PATH       管理面板前缀，默认 /admin-panel/
  --spa                  静态站点回退到 /index.html（仅 static 模式）
  --priority NN          两位优先级，10-99；默认自动取下一个 10 的倍数
  --force                覆盖已存在的同名站点配置
  --http-only            即使已有证书也只生成 HTTP（用于 CERT_MODE=none）
  --no-reload            只写文件，不执行 nginx -t / reload

示例：
  ./scripts/add-site.sh app2 app2.example.com --upstream app2:3000 --websocket --body-size 16m
  ./scripts/add-site.sh docs docs.example.com --root /srv/docs --spa
USAGE
}

SITE=""
DOMAIN=""
MODE=""
UPSTREAM=""
ROOT=""
BODY_SIZE="1m"
WEBSOCKET=0
SPA=0
ADMIN_ALLOWLIST=""
ADMIN_PATH="/admin-panel/"
PRIORITY=""
FORCE=0
HTTP_ONLY=0
NO_RELOAD=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --upstream)
            [[ $# -ge 2 ]] || die "--upstream requires a value"
            [[ "$MODE" == "static" ]] && die "--upstream and --root are mutually exclusive"
            MODE="proxy"
            UPSTREAM="$2"
            shift 2
            ;;
        --root)
            [[ $# -ge 2 ]] || die "--root requires a value"
            [[ "$MODE" == "proxy" ]] && die "--upstream and --root are mutually exclusive"
            MODE="static"
            ROOT="$2"
            shift 2
            ;;
        --body-size)
            [[ $# -ge 2 ]] || die "--body-size requires a value"
            BODY_SIZE="$2"
            shift 2
            ;;
        --websocket)
            WEBSOCKET=1
            shift
            ;;
        --spa)
            SPA=1
            shift
            ;;
        --admin-allowlist)
            [[ $# -ge 2 ]] || die "--admin-allowlist requires a value"
            ADMIN_ALLOWLIST="$2"
            shift 2
            ;;
        --admin-path)
            [[ $# -ge 2 ]] || die "--admin-path requires a value"
            ADMIN_PATH="$2"
            shift 2
            ;;
        --priority)
            [[ $# -ge 2 ]] || die "--priority requires a value"
            PRIORITY="$2"
            shift 2
            ;;
        --force)
            FORCE=1
            shift
            ;;
        --http-only)
            HTTP_ONLY=1
            shift
            ;;
        --no-reload)
            NO_RELOAD=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        -*)
            die "unknown option: $1"
            ;;
        *)
            if [[ -z "$SITE" ]]; then
                SITE="$1"
            elif [[ -z "$DOMAIN" ]]; then
                DOMAIN="$1"
            else
                die "unexpected argument: $1"
            fi
            shift
            ;;
    esac
done

[[ -n "$SITE" && -n "$DOMAIN" ]] || { usage; exit 2; }
valid_site "$SITE" || die "invalid site name: $SITE (lowercase letters, digits, hyphen; max 32)"
valid_domain "$DOMAIN" || die "invalid domain: $DOMAIN"
valid_size "$BODY_SIZE" || die "invalid body size: $BODY_SIZE"
[[ -z "$ADMIN_ALLOWLIST" ]] || valid_allowlist "$ADMIN_ALLOWLIST" || die "invalid --admin-allowlist: $ADMIN_ALLOWLIST"
ADMIN_ALLOWLIST="${ADMIN_ALLOWLIST// /}"
[[ "$ADMIN_PATH" == */ ]] || ADMIN_PATH="${ADMIN_PATH}/"
valid_admin_path "$ADMIN_PATH" || die "invalid --admin-path: $ADMIN_PATH"

UPSTREAM="${UPSTREAM#http://}"
UPSTREAM="${UPSTREAM#https://}"

case "$MODE" in
    proxy)
        valid_upstream "$UPSTREAM" || die "invalid upstream: $UPSTREAM (expected host:port)"
        [[ "$SPA" == "1" ]] && die "--spa only applies to --root"
        ;;
    static)
        valid_root "$ROOT" || die "invalid root: $ROOT (must be an absolute container path)"
        [[ "$WEBSOCKET" == "1" ]] && die "--websocket only applies to --upstream"
        [[ -n "$ADMIN_ALLOWLIST" ]] && die "--admin-allowlist only applies to --upstream"
        ;;
    *)
        die "specify --upstream host:port or --root /srv/<site>"
        ;;
esac

# --force 覆盖同名站点时保留原优先级，避免站点在 include 顺序里漂移。
if [[ -z "$PRIORITY" && -f "${META_DIR}/${SITE}.env" ]]; then
    # shellcheck disable=SC1090
    PRIORITY="$(. "${META_DIR}/${SITE}.env"; printf '%s' "${PRIORITY:-}")"
fi
if [[ -z "$PRIORITY" ]]; then
    PRIORITY="$(next_priority)"
fi
valid_priority "$PRIORITY" || die "invalid priority: $PRIORITY (10-99)"

acquire_lock

shopt -s nullglob
existing=("$SITES_DIR"/[0-9][0-9]-"$SITE".conf)
shopt -u nullglob

if [[ "${#existing[@]}" -gt 0 || -f "${META_DIR}/${SITE}.env" ]]; then
    [[ "$FORCE" == "1" ]] || die "site '$SITE' already exists; use --force to replace"
    if [[ "${#existing[@]}" -gt 0 ]]; then
        rm -f "${existing[@]}"
        log "removed existing config(s): ${existing[*]}"
    fi
fi

write_meta

if [[ "$HTTP_ONLY" == "1" ]]; then
    apply_site no "$([[ "$NO_RELOAD" == "1" ]] && echo no || echo yes)"
    log "site '$SITE' created with HTTP + ACME only (--http-only)"
elif cert_exists "$SITE"; then
    apply_site yes "$([[ "$NO_RELOAD" == "1" ]] && echo no || echo yes)"
    log "site '$SITE' ready with HTTPS"
else
    apply_site no "$([[ "$NO_RELOAD" == "1" ]] && echo no || echo yes)"
    log "site '$SITE' created with HTTP + ACME only"
    log "next: ./scripts/issue-cert.sh $SITE $DOMAIN --email you@example.com"
    log "  or: ./scripts/self-signed-cert.sh $SITE && ./scripts/enable-https.sh $SITE"
fi

log "config: ${SITES_DIR}/${PRIORITY}-${SITE}.conf"
log "meta:   ${META_DIR}/${SITE}.env"
