#!/usr/bin/env bash
# 生成自签证书，用于内网/联调/证书流程验证。生产请用 issue-cert.sh。
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

usage() {
    cat <<'USAGE'
用法：self-signed-cert.sh <site>

前置：站点已由 add-site.sh 创建（sites/.meta/<site>.env 存在）。
生成：certs/<site>/fullchain.pem、certs/<site>/privkey.pem（有效期 365 天，仅含该域名 SAN）。
USAGE
}

SITE_ARG="${1:-}"
if [[ "$SITE_ARG" == "-h" || "$SITE_ARG" == "--help" ]]; then
    usage
    exit 0
fi
[[ -n "$SITE_ARG" ]] || { usage; exit 2; }
load_meta "$SITE_ARG"

require_cmd openssl
mkdir -p "${CERTS_DIR}/${SITE}"
chmod 0700 "${CERTS_DIR}/${SITE}"

TMP_CONF="$(mktemp)"
trap 'rm -f "$TMP_CONF"' EXIT

cat > "$TMP_CONF" <<EOF
[req]
distinguished_name = dn
x509_extensions = v3_req
prompt = no

[dn]
CN = ${DOMAIN}

[v3_req]
subjectAltName = DNS:${DOMAIN}
basicConstraints = CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
EOF

openssl req -x509 -nodes -newkey rsa:2048 -days 365 \
    -keyout "${CERTS_DIR}/${SITE}/privkey.pem" \
    -out "${CERTS_DIR}/${SITE}/fullchain.pem" \
    -config "$TMP_CONF" >/dev/null 2>&1

chmod 0600 "${CERTS_DIR}/${SITE}/privkey.pem"
chmod 0644 "${CERTS_DIR}/${SITE}/fullchain.pem"

log "self-signed certificate written: ${CERTS_DIR}/${SITE}/"
log "next: ./scripts/enable-https.sh $SITE"
