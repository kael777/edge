#!/usr/bin/env bash
# 续期所有 Let's Encrypt 证书，复制到 certs/<site>/，有变化则 reload。
# 建议 cron：17 3 * * * cd /opt/nginx-gateway && ./scripts/renew-certs.sh >> wwwlogs/renew.log 2>&1
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

acquire_cert_lock
require_cmd docker
mkdir -p "$ACME_DIR" "$CERTBOT_DIR" "$CERTBOT_LIB_DIR"

docker run --rm \
    -v "${ACME_DIR}:/var/www/acme" \
    -v "${CERTBOT_DIR}:/etc/letsencrypt" \
    -v "${CERTBOT_LIB_DIR}:/var/lib/letsencrypt" \
    "${CERTBOT_IMAGE}" \
    renew --webroot -w /var/www/acme --quiet || {
        log "ERROR: certbot renew failed"
        exit 1
    }

changed=0
shopt -s nullglob
for meta in "$META_DIR"/*.env; do
    SITE=""
    DOMAIN=""
    MODE=""
    UPSTREAM=""
    ROOT=""
    BODY_SIZE=""
    WEBSOCKET=""
    SPA=""
    PRIORITY=""
    # shellcheck disable=SC1090
    . "$meta"

    [[ -n "$SITE" && -n "$DOMAIN" ]] || continue
    live="${CERTBOT_DIR}/live/${DOMAIN}"
    [[ -s "${live}/fullchain.pem" && -s "${live}/privkey.pem" ]] || continue

    mkdir -p "${CERTS_DIR}/${SITE}"
    site_changed=0
    if ! cmp -s "${live}/fullchain.pem" "${CERTS_DIR}/${SITE}/fullchain.pem"; then
        install -m 0644 "${live}/fullchain.pem" "${CERTS_DIR}/${SITE}/fullchain.pem"
        site_changed=1
    fi
    if ! cmp -s "${live}/privkey.pem" "${CERTS_DIR}/${SITE}/privkey.pem"; then
        install -m 0600 "${live}/privkey.pem" "${CERTS_DIR}/${SITE}/privkey.pem"
        site_changed=1
    fi
    if [[ "$site_changed" == "1" ]]; then
        log "refreshed certificate for ${SITE} (${DOMAIN})"
        changed=1
    fi
done
shopt -u nullglob

if [[ "$changed" == "1" ]]; then
    "${BASE_DIR}/scripts/reload.sh"
else
    log "no certificates renewed"
fi
