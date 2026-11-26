#!/usr/bin/env bash
# nginx-gateway 脚本公共库。
set -euo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SITES_DIR="${BASE_DIR}/sites"
META_DIR="${SITES_DIR}/.meta"
BACKUP_DIR="${SITES_DIR}/.backup"
PROJECTS_DIR="${BASE_DIR}/projects"
CERTS_DIR="${BASE_DIR}/certs"
ACME_DIR="${BASE_DIR}/acme"
LOGS_DIR="${BASE_DIR}/wwwlogs"
CERTBOT_DIR="${BASE_DIR}/letsencrypt"
CERTBOT_LIB_DIR="${BASE_DIR}/letsencrypt-lib"
# 固定 certbot 多架构 digest；升级时改这里，或在环境变量里覆盖。
CERTBOT_IMAGE="${CERTBOT_IMAGE:-certbot/certbot@sha256:c5698da859429ccee0fcc299a8000368198222d1f9e789ab6e388b491e8ce06d}"
CERT_LOCK_FILE="${BASE_DIR}/.cert.lock"
CERT_LOCK_DIR="${CERT_LOCK_FILE}.d"
CONTAINER="${NGINX_GATEWAY_CONTAINER:-nginx-gateway}"

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }
require_cmd() { command -v "$1" >/dev/null 2>&1 || die "missing command: $1"; }

valid_site() { [[ "$1" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]]; }
valid_domain() { [[ "$1" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]; }
valid_upstream() { [[ "$1" =~ ^[A-Za-z0-9_.-]+:[0-9]{1,5}$ ]]; }
valid_root() { [[ "$1" =~ ^/[A-Za-z0-9._/-]+$ ]]; }
valid_size() { [[ "$1" =~ ^[0-9]+[kKmMgG]?$ ]]; }
valid_priority() { [[ "$1" =~ ^[0-9]{2}$ ]] && (( 10#$1 >= 10 && 10#$1 <= 99 )); }

valid_allowlist() {
    local item
    local -a items
    IFS=',' read -r -a items <<< "$1"
    for item in "${items[@]}"; do
        item="${item// /}"
        [[ -n "$item" ]] || continue
        [[ "$item" =~ ^[0-9a-fA-F:.]+(/[0-9]{1,3})?$ ]] || return 1
    done
    return 0
}

valid_admin_path() { [[ "$1" =~ ^/[A-Za-z0-9._/-]+/$ ]] && [[ "$1" != *".."* ]]; }

container_running() {
    docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null | grep -qx 'true'
}

acquire_lock() {
    LOCK_DIR="${BASE_DIR}/.lock"
    if ! mkdir "$LOCK_DIR" 2>/dev/null; then
        die "another operation is running (lock: $LOCK_DIR); remove it if stale"
    fi
    trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT
}

# 证书签发/续期全局锁：避免 cron 和手工同时操作 letsencrypt/ 与 certs/。
acquire_cert_lock() {
    if command -v flock >/dev/null 2>&1; then
        exec 9>"$CERT_LOCK_FILE"
        flock -n 9 || die "another certificate operation is running"
    else
        mkdir "$CERT_LOCK_DIR" 2>/dev/null || die "another certificate operation is running (remove $CERT_LOCK_DIR if stale)"
        trap 'rmdir "$CERT_LOCK_DIR" 2>/dev/null || true' EXIT
    fi
}

next_priority() {
    local max=0 f base n
    shopt -s nullglob
    for f in "$SITES_DIR"/[0-9][0-9]-*.conf; do
        base="${f##*/}"
        n="${base%%-*}"
        n=$((10#$n))
        (( n > max )) && max=$n
    done
    shopt -u nullglob
    (( max + 10 <= 99 )) || die "no free priority slot (max $max)"
    printf '%02d' $((max + 10))
}

cert_exists() {
    [[ -s "${CERTS_DIR}/$1/fullchain.pem" && -s "${CERTS_DIR}/$1/privkey.pem" ]]
}

write_meta() {
    mkdir -p "$META_DIR"
    cat > "${META_DIR}/${SITE}.env" <<EOF
SITE='${SITE}'
DOMAIN='${DOMAIN}'
MODE='${MODE}'
UPSTREAM='${UPSTREAM}'
ROOT='${ROOT}'
BODY_SIZE='${BODY_SIZE}'
WEBSOCKET='${WEBSOCKET}'
SPA='${SPA}'
PRIORITY='${PRIORITY}'
ADMIN_ALLOWLIST='${ADMIN_ALLOWLIST:-}'
ADMIN_PATH='${ADMIN_PATH:-/admin-panel/}'
EOF
    chmod 0644 "${META_DIR}/${SITE}.env"
}

load_meta() {
    local site="$1" f="${META_DIR}/$1.env"
    [[ -f "$f" ]] || die "no metadata for site '$site' ($f)"
    # shellcheck disable=SC1090
    . "$f"
    [[ "${SITE}" == "$site" ]] || die "metadata mismatch: $f"
}

render_locations() {
    if [[ "$MODE" == "proxy" ]]; then
        if [[ -n "${ADMIN_ALLOWLIST:-}" ]]; then
            local cidr
            local -a _admins
            IFS=',' read -r -a _admins <<< "$ADMIN_ALLOWLIST"
            cat <<EOF
    location ^~ ${ADMIN_PATH:-/admin-panel/} {
EOF
            for cidr in "${_admins[@]}"; do
                cidr="${cidr// /}"
                [[ -n "$cidr" ]] || continue
                printf '        allow %s;\n' "$cidr"
            done
            cat <<EOF
        deny all;
        include /etc/nginx/snippets/proxy-common.conf;
        proxy_pass http://${SITE}_up;
    }

EOF
        fi
        cat <<EOF
    location / {
        include /etc/nginx/snippets/proxy-common.conf;
        proxy_pass http://${SITE}_up;
    }
EOF
        if [[ "$WEBSOCKET" == "1" ]]; then
            cat <<EOF

    location /ws/ {
        include /etc/nginx/snippets/proxy-common.conf;
        include /etc/nginx/snippets/websocket.conf;
        proxy_pass http://${SITE}_up;
    }
EOF
        fi
    else
        local fallback="=404"
        [[ "$SPA" == "1" ]] && fallback="/index.html"
        cat <<EOF
    root ${ROOT};
    index index.html;

    location / {
        include /etc/nginx/snippets/static.conf;
        try_files \$uri \$uri/ ${fallback};
    }
EOF
    fi
}

render_site() {
    local tls="${1:-no}"

    if [[ "$MODE" == "proxy" ]]; then
        cat <<EOF
upstream ${SITE}_up {
    zone ${SITE}_up 128k;
    server ${UPSTREAM} resolve;
    keepalive 32;
}

EOF
    fi

    cat <<EOF
server {
    listen 80;
    server_name ${DOMAIN};

    include /etc/nginx/snippets/acme.conf;
EOF

    if [[ "$tls" == "yes" ]]; then
        cat <<EOF

    location / {
        return 301 https://\$host\$request_uri;
    }
}
EOF
    else
        cat <<EOF

    client_max_body_size ${BODY_SIZE};

$(render_locations)
}
EOF
    fi

    if [[ "$tls" == "yes" ]]; then
        cat <<EOF

server {
    listen 443 ssl;
    server_name ${DOMAIN};

    include /etc/nginx/snippets/ssl-common.conf;
    ssl_certificate     /etc/nginx/certs/${SITE}/fullchain.pem;
    ssl_certificate_key /etc/nginx/certs/${SITE}/privkey.pem;

    client_max_body_size ${BODY_SIZE};

$(render_locations)
}
EOF
    fi
}

apply_site() {
    local tls="${1:-no}" do_reload="${2:-yes}"
    local path="${SITES_DIR}/${PRIORITY}-${SITE}.conf"
    local tmp backup

    mkdir -p "$SITES_DIR" "$BACKUP_DIR"
    backup="${BACKUP_DIR}/${SITE}.$(date '+%Y%m%d%H%M%S').conf"
    [[ -f "$path" ]] && cp -p "$path" "$backup"

    tmp="$(mktemp "${SITES_DIR}/.${SITE}.XXXXXX")"
    render_site "$tls" > "$tmp"
    chmod 0644 "$tmp"
    mv -f "$tmp" "$path"
    log "wrote $path"

    if [[ "$do_reload" != "yes" ]]; then
        log "reload skipped (--no-reload)"
        return 0
    fi

    if ! container_running; then
        log "container '$CONTAINER' is not running; skipped nginx -t and reload"
        return 0
    fi

    if ! docker exec "$CONTAINER" nginx -t; then
        if [[ -f "$backup" ]]; then
            cp -p "$backup" "$path"
            log "nginx -t failed; restored $backup"
        else
            rm -f "$path"
            log "nginx -t failed; removed new config"
        fi
        die "configuration not applied"
    fi

    docker exec "$CONTAINER" nginx -s reload
    log "reloaded nginx"
}
