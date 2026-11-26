#!/usr/bin/env bash
# 检查 certs/*/fullchain.pem 是否在 WARN_DAYS 天内过期；过期/临期返回 1。
# 可放 cron 或外部监控；失败时 cron 日志里会有 WARN。
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

require_cmd openssl
WARN_DAYS="${CERT_WARN_DAYS:-21}"
fail=0

shopt -s nullglob
for cert in "$CERTS_DIR"/*/fullchain.pem; do
    site="$(basename "$(dirname "$cert")")"
    if ! openssl x509 -checkend $((WARN_DAYS * 86400)) -noout -in "$cert" >/dev/null 2>&1; then
        end="$(openssl x509 -enddate -noout -in "$cert" | cut -d= -f2)"
        log "WARN: ${site} certificate expires within ${WARN_DAYS} days (${end})"
        fail=1
    fi
done
shopt -u nullglob

if [[ "$fail" == "1" ]]; then
    log "certificate check FAILED"
    exit 1
fi

log "certificate check ok (warn window ${WARN_DAYS}d)"
