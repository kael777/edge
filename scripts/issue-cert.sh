#!/usr/bin/env bash
# 用 Let's Encrypt HTTP-01 签发证书，复制到 certs/<site>/，然后自动 enable-https。
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

usage() {
    cat <<'USAGE'
用法：issue-cert.sh <site> [--email you@example.com] [--staging] [--force] [--dry-run] [--no-enable]

说明：
  - 站点必须已经由 add-site.sh 创建，且 80 端口配置包含 snippets/acme.conf。
  - 域名必须已经解析到本机，80 端口必须能从公网访问。
  - 默认签发后自动执行 enable-https.sh。
  - 邮箱也可用环境变量 CERTBOT_EMAIL。

示例：
  ./scripts/issue-cert.sh app2 --email ops@example.com
  ./scripts/issue-cert.sh app2 --email ops@example.com --staging
USAGE
}

SITE_ARG=""
EMAIL="${CERTBOT_EMAIL:-}"
STAGING=0
FORCE=0
DRY_RUN=0
NO_ENABLE=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --email)
            [[ $# -ge 2 ]] || die "--email requires a value"
            EMAIL="$2"
            shift 2
            ;;
        --staging) STAGING=1; shift ;;
        --force) FORCE=1; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        --no-enable) NO_ENABLE=1; shift ;;
        -h|--help) usage; exit 0 ;;
        -*) die "unknown option: $1" ;;
        *)
            [[ -z "$SITE_ARG" ]] || die "unexpected argument: $1"
            SITE_ARG="$1"
            shift
            ;;
    esac
done

[[ -n "$SITE_ARG" ]] || { usage; exit 2; }
[[ -n "$EMAIL" ]] || die "--email or CERTBOT_EMAIL is required"
load_meta "$SITE_ARG"

CONFIG="${SITES_DIR}/${PRIORITY}-${SITE}.conf"
[[ -f "$CONFIG" ]] || die "site config not found: $CONFIG"
grep -q 'snippets/acme.conf' "$CONFIG" || die "site config lacks snippets/acme.conf; recreate it with add-site.sh"

acquire_cert_lock
require_cmd docker
mkdir -p "$ACME_DIR" "$CERTBOT_DIR" "$CERTBOT_LIB_DIR" "$CERTS_DIR/$SITE"
chmod 0700 "$CERTS_DIR/$SITE"

ARGS=(
    certonly
    --webroot
    -w /var/www/acme
    -d "$DOMAIN"
    --email "$EMAIL"
    --agree-tos
    --non-interactive
    --preferred-challenges http
)

[[ "$STAGING" == "1" ]] && ARGS+=(--staging)
[[ "$FORCE" == "1" ]] && ARGS+=(--force-renewal)
[[ "$DRY_RUN" == "1" ]] && ARGS+=(--dry-run)

log "requesting certificate for $DOMAIN (site=$SITE, staging=$STAGING, dry_run=$DRY_RUN)"

docker run --rm \
    -v "${ACME_DIR}:/var/www/acme" \
    -v "${CERTBOT_DIR}:/etc/letsencrypt" \
    -v "${CERTBOT_LIB_DIR}:/var/lib/letsencrypt" \
    "${CERTBOT_IMAGE}" \
    "${ARGS[@]}"

if [[ "$DRY_RUN" == "1" ]]; then
    log "dry-run completed; no certificate copied"
    exit 0
fi

LIVE_DIR="${CERTBOT_DIR}/live/${DOMAIN}"
[[ -s "${LIVE_DIR}/fullchain.pem" && -s "${LIVE_DIR}/privkey.pem" ]] \
    || die "certbot did not produce ${LIVE_DIR}/fullchain.pem or privkey.pem"

install -m 0644 "${LIVE_DIR}/fullchain.pem" "${CERTS_DIR}/${SITE}/fullchain.pem"
install -m 0600 "${LIVE_DIR}/privkey.pem" "${CERTS_DIR}/${SITE}/privkey.pem"
log "certificate installed: ${CERTS_DIR}/${SITE}/"

if [[ "$NO_ENABLE" == "1" ]]; then
    log "skipped enable-https (--no-enable)"
else
    "${BASE_DIR}/scripts/enable-https.sh" "$SITE"
fi
