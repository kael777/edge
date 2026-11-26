#!/usr/bin/env bash
# 删除项目注册：移除 sites/<NN>-<name>.conf 和 projects/<name>.env，可选删证书。
# 默认保留证书；只有显式 --purge-cert 才删 certs/<name>/。
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

usage() {
    cat <<'USAGE'
用法：remove-project.sh <project> [--purge-cert] [--no-reload]

说明：
  - 删除 sites/<NN>-<project>.conf、projects/<project>.env、sites/.meta/<project>.env
  - 默认保留证书；--purge-cert 才删 certs/<project>/
  - 默认先 nginx -t，通过后 reload；--no-reload 只删文件
  - 不删除 letsencrypt/ 历史，也不删除业务 compose/数据卷
USAGE
}

PROJECT_ARG="${1:-}"
[[ -n "$PROJECT_ARG" ]] || { usage; exit 2; }
shift || true
valid_site "$PROJECT_ARG" || die "invalid project name: $PROJECT_ARG"

PURGE_CERT=0
NO_RELOAD=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --purge-cert) PURGE_CERT=1; shift ;;
        --no-reload) NO_RELOAD=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown option: $1" ;;
    esac
done

acquire_lock

CONFIG=""
if [[ -f "${META_DIR}/${PROJECT_ARG}.env" ]]; then
    load_meta "$PROJECT_ARG"
    [[ -n "${PRIORITY:-}" ]] && CONFIG="${SITES_DIR}/${PRIORITY}-${PROJECT_ARG}.conf"
fi

if [[ -z "$CONFIG" || ! -f "$CONFIG" ]]; then
    shopt -s nullglob
    matches=("$SITES_DIR"/[0-9][0-9]-"${PROJECT_ARG}".conf)
    shopt -u nullglob
    [[ "${#matches[@]}" -eq 1 ]] || die "cannot locate site config for '$PROJECT_ARG' (${#matches[@]} matches)"
    CONFIG="${matches[0]}"
fi

mkdir -p "$BACKUP_DIR"
STAMP="$(date '+%Y%m%d%H%M%S')"
BACKUP_CONFIG="${BACKUP_DIR}/${PROJECT_ARG}.${STAMP}.conf"
cp -p "$CONFIG" "$BACKUP_CONFIG"
[[ -f "${META_DIR}/${PROJECT_ARG}.env" ]] && cp -p "${META_DIR}/${PROJECT_ARG}.env" "${BACKUP_DIR}/${PROJECT_ARG}.${STAMP}.meta.env"
[[ -f "${PROJECTS_DIR}/${PROJECT_ARG}.env" ]] && cp -p "${PROJECTS_DIR}/${PROJECT_ARG}.env" "${BACKUP_DIR}/${PROJECT_ARG}.${STAMP}.project.env"

rm -f "$CONFIG"
log "removed $CONFIG"

if [[ "$NO_RELOAD" == "1" ]]; then
    rm -f "${META_DIR}/${PROJECT_ARG}.env" "${PROJECTS_DIR}/${PROJECT_ARG}.env"
    [[ "$PURGE_CERT" == "1" ]] && rm -rf "${CERTS_DIR}/${PROJECT_ARG}"
    log "reload skipped; run: $BASE_DIR/scripts/reload.sh"
    exit 0
fi

if container_running; then
    if ! docker exec "$CONTAINER" nginx -t; then
        cp -p "$BACKUP_CONFIG" "$CONFIG"
        log "nginx -t failed; restored $CONFIG"
        die "project not removed"
    fi
    if ! docker exec "$CONTAINER" nginx -s reload; then
        cp -p "$BACKUP_CONFIG" "$CONFIG"
        docker exec "$CONTAINER" nginx -t >/dev/null 2>&1 || true
        die "reload failed; restored $CONFIG"
    fi
    log "nginx reloaded"
else
    log "container '$CONTAINER' is not running; skipped nginx -t/reload"
fi

rm -f "${META_DIR}/${PROJECT_ARG}.env" "${PROJECTS_DIR}/${PROJECT_ARG}.env"
if [[ "$PURGE_CERT" == "1" ]]; then
    rm -rf "${CERTS_DIR}/${PROJECT_ARG}"
    log "removed certificate dir ${CERTS_DIR}/${PROJECT_ARG}"
fi

if [[ "$PURGE_CERT" == "1" ]]; then
    log "project '$PROJECT_ARG' removed (certificate removed)"
else
    log "project '$PROJECT_ARG' removed (certificate kept)"
fi
