#!/usr/bin/env bash
# 证书就位后，把站点从 HTTP-only 切换为 HTTP(ACME+301) + HTTPS。
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

usage() {
    cat <<'USAGE'
用法：enable-https.sh <site> [--no-reload]

前置：certs/<site>/fullchain.pem 和 privkey.pem 已存在。
USAGE
}

SITE_ARG=""
NO_RELOAD=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-reload) NO_RELOAD=1; shift ;;
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
load_meta "$SITE_ARG"

cert_exists "$SITE" || die "missing ${CERTS_DIR}/${SITE}/fullchain.pem or privkey.pem; run issue-cert.sh or self-signed-cert.sh first"

acquire_lock
apply_site yes "$([[ "$NO_RELOAD" == "1" ]] && echo no || echo yes)"
log "HTTPS enabled for $SITE (${DOMAIN})"
