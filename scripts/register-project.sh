#!/usr/bin/env bash
# 项目注册：读取 projects/<name>.env，生成站点，按需签发证书，reload。
# 这是多项目共用前置 nginx 的入口：A 先注册，B 后注册，只多一个 sites/*.conf。
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

usage() {
    cat <<'USAGE'
用法：
  register-project.sh <project> [options]
  register-project.sh --all

读取：
  projects/<project>.env（可选；命令行参数覆盖）

选项：
  --domain D              域名
  --upstream host:port    proxy 上游，容器服务名:端口
  --root /srv/<project>   static 根目录（容器内路径）
  --email E               Let's Encrypt 邮箱
  --body-size SIZE        client_max_body_size，默认 1m
  --websocket             生成 /ws/ 反代
  --admin-allowlist LIST  管理面板 IP/CIDR 白名单，逗号分隔（仅 proxy）
  --admin-path PATH       管理面板前缀，默认 /admin-panel/
  --spa                   静态站点回退 /index.html
  --priority NN           两位优先级 10-99
  --cert MODE             auto | letsencrypt | self-signed | none
  --staging               使用 Let's Encrypt staging
  --force                 强制重新签发证书
  --renew-cert            同 --force，仅针对证书
  --no-reload             只写文件，不执行 nginx -t/reload
  --no-save               不更新 projects/<project>.env
  --dry-run               只打印计划，不写文件、不执行
  --all                   依次注册 projects/*.env

示例：
  cp projects/example.env.example projects/a.env
  vi projects/a.env
  ./scripts/register-project.sh a

  ./scripts/register-project.sh b --domain b.example.com --upstream b-web:8080 --email ops@example.com
USAGE
}

if [[ "${1:-}" == "--all" ]]; then
    shift
    [[ $# -eq 0 ]] || die "--all cannot be combined with other options"
    shopt -s nullglob
    files=("$PROJECTS_DIR"/*.env)
    shopt -u nullglob
    [[ "${#files[@]}" -gt 0 ]] || die "no projects/*.env found"
    for f in "${files[@]}"; do
        name="$(basename "$f" .env)"
        log "registering project: $name"
        "$BASE_DIR/scripts/register-project.sh" "$name"
    done
    exit 0
fi

PROJECT_ARG="${1:-}"
[[ -n "$PROJECT_ARG" ]] || { usage; exit 2; }
shift || true
valid_site "$PROJECT_ARG" || die "invalid project name: $PROJECT_ARG"
PROJECT="$PROJECT_ARG"

ENV_FILE="${PROJECTS_DIR}/${PROJECT}.env"

# 默认值；如果 env 存在，先 source，再由命令行覆盖。
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
EMAIL=""
CERT_MODE="auto"
STAGING=0

if [[ -f "$ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    . "$ENV_FILE"
    [[ "${PROJECT:-}" == "$PROJECT_ARG" ]] || die "$ENV_FILE: PROJECT must match filename ($PROJECT_ARG)"
else
    log "no $ENV_FILE; using command-line values"
fi

FORCE=0
RENEW_CERT=0
NO_RELOAD=0
NO_SAVE=0
DRY_RUN=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --domain)
            [[ $# -ge 2 ]] || die "--domain requires a value"
            DOMAIN="$2"
            shift 2
            ;;
        --upstream)
            [[ $# -ge 2 ]] || die "--upstream requires a value"
            MODE="proxy"
            UPSTREAM="$2"
            shift 2
            ;;
        --root)
            [[ $# -ge 2 ]] || die "--root requires a value"
            MODE="static"
            ROOT="$2"
            shift 2
            ;;
        --email)
            [[ $# -ge 2 ]] || die "--email requires a value"
            EMAIL="$2"
            shift 2
            ;;
        --body-size)
            [[ $# -ge 2 ]] || die "--body-size requires a value"
            BODY_SIZE="$2"
            shift 2
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
        --websocket) WEBSOCKET=1; shift ;;
        --spa) SPA=1; shift ;;
        --priority)
            [[ $# -ge 2 ]] || die "--priority requires a value"
            PRIORITY="$2"
            shift 2
            ;;
        --cert)
            [[ $# -ge 2 ]] || die "--cert requires a value"
            CERT_MODE="$2"
            shift 2
            ;;
        --staging) STAGING=1; shift ;;
        --force) FORCE=1; shift ;;
        --renew-cert) RENEW_CERT=1; shift ;;
        --no-reload) NO_RELOAD=1; shift ;;
        --no-save) NO_SAVE=1; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "unexpected argument: $1" ;;
    esac
done

BODY_SIZE="${BODY_SIZE:-1m}"
CERT_MODE="${CERT_MODE:-auto}"
WEBSOCKET="${WEBSOCKET:-0}"
SPA="${SPA:-0}"
STAGING="${STAGING:-0}"

valid_domain "$DOMAIN" || die "invalid or missing DOMAIN: $DOMAIN"
valid_size "$BODY_SIZE" || die "invalid BODY_SIZE: $BODY_SIZE"
[[ -z "$ADMIN_ALLOWLIST" ]] || valid_allowlist "$ADMIN_ALLOWLIST" || die "invalid ADMIN_ALLOWLIST: $ADMIN_ALLOWLIST"
ADMIN_ALLOWLIST="${ADMIN_ALLOWLIST// /}"
[[ "$ADMIN_PATH" == */ ]] || ADMIN_PATH="${ADMIN_PATH}/"
valid_admin_path "$ADMIN_PATH" || die "invalid ADMIN_PATH: $ADMIN_PATH"
[[ -z "$PRIORITY" ]] || valid_priority "$PRIORITY" || die "invalid PRIORITY: $PRIORITY (10-99)"

case "$MODE" in
    proxy)
        UPSTREAM="${UPSTREAM#http://}"
        UPSTREAM="${UPSTREAM#https://}"
        valid_upstream "$UPSTREAM" || die "invalid UPSTREAM: $UPSTREAM (expected host:port)"
        ROOT=""
        ;;
    static)
        valid_root "$ROOT" || die "invalid ROOT: $ROOT (absolute container path required)"
        [[ -n "$ADMIN_ALLOWLIST" ]] && die "ADMIN_ALLOWLIST only applies to proxy mode"
        UPSTREAM=""
        ;;
    *)
        die "MODE must be proxy or static (set --upstream or --root, or MODE in $ENV_FILE)"
        ;;
esac

case "$CERT_MODE" in
    auto|letsencrypt|self-signed|none) ;;
    *) die "invalid CERT_MODE: $CERT_MODE (auto|letsencrypt|self-signed|none)" ;;
esac

if [[ -n "$EMAIL" && ! "$EMAIL" =~ ^[^@]+@[^@]+\.[^@]+$ ]]; then
    die "invalid EMAIL: $EMAIL"
fi
if [[ "$CERT_MODE" == "letsencrypt" && -z "$EMAIL" ]]; then
    die "CERT_MODE=letsencrypt requires EMAIL"
fi

save_env() {
    mkdir -p "$PROJECTS_DIR"
    local tmp
    tmp="$(mktemp "${PROJECTS_DIR}/.${PROJECT}.XXXXXX")"
    cat > "$tmp" <<EOF
PROJECT=$PROJECT
DOMAIN=$DOMAIN
MODE=$MODE
UPSTREAM=$UPSTREAM
ROOT=$ROOT
BODY_SIZE=$BODY_SIZE
WEBSOCKET=$WEBSOCKET
SPA=$SPA
ADMIN_ALLOWLIST='$ADMIN_ALLOWLIST'
ADMIN_PATH='$ADMIN_PATH'
PRIORITY=$PRIORITY
EMAIL=$EMAIL
CERT_MODE=$CERT_MODE
STAGING=$STAGING
EOF
    chmod 0644 "$tmp"
    mv -f "$tmp" "$ENV_FILE"
    log "saved $ENV_FILE"
}

ADD_ARGS=("$PROJECT" "$DOMAIN")
case "$MODE" in
    proxy) ADD_ARGS+=(--upstream "$UPSTREAM") ;;
    static) ADD_ARGS+=(--root "$ROOT") ;;
esac
ADD_ARGS+=(--body-size "$BODY_SIZE")
[[ "$WEBSOCKET" == "1" ]] && ADD_ARGS+=(--websocket)
[[ "$SPA" == "1" ]] && ADD_ARGS+=(--spa)
[[ -n "$PRIORITY" ]] && ADD_ARGS+=(--priority "$PRIORITY")
[[ -n "$ADMIN_ALLOWLIST" ]] && ADD_ARGS+=(--admin-allowlist "$ADMIN_ALLOWLIST")
[[ -n "$ADMIN_PATH" ]] && ADD_ARGS+=(--admin-path "$ADMIN_PATH")
ADD_ARGS+=(--force)
[[ "$CERT_MODE" == "none" ]] && ADD_ARGS+=(--http-only)
[[ "$NO_RELOAD" == "1" ]] && ADD_ARGS+=(--no-reload)

# 证书计划
CERT_ACTION="none"
if [[ "$CERT_MODE" == "none" ]]; then
    CERT_ACTION="none"
elif [[ "$CERT_MODE" == "self-signed" ]]; then
    if cert_exists "$PROJECT" && [[ "$FORCE" != "1" && "$RENEW_CERT" != "1" ]]; then
        CERT_ACTION="reuse"
    else
        CERT_ACTION="self-signed"
    fi
else
    if cert_exists "$PROJECT" && [[ "$FORCE" != "1" && "$RENEW_CERT" != "1" ]]; then
        CERT_ACTION="reuse"
    elif [[ -n "$EMAIL" ]]; then
        CERT_ACTION="letsencrypt"
    else
        CERT_ACTION="none"
        log "no EMAIL; keeping HTTP only"
    fi
fi

if [[ "$DRY_RUN" == "1" ]]; then
    printf 'project: %s\ndomain:  %s\nmode:    %s\n' "$PROJECT" "$DOMAIN" "$MODE"
    [[ "$MODE" == "proxy" ]] && printf 'upstream: %s\n' "$UPSTREAM"
    [[ "$MODE" == "static" ]] && printf 'root:     %s\n' "$ROOT"
    printf 'cert:    %s\n' "$CERT_ACTION"
    printf 'command: '
    printf ' %q' "$BASE_DIR/scripts/add-site.sh" "${ADD_ARGS[@]}"
    printf '\n'
    if [[ "$CERT_ACTION" == "letsencrypt" ]]; then
        printf 'cert command: %q %q --email %q' "$BASE_DIR/scripts/issue-cert.sh" "$PROJECT" "$EMAIL"
        [[ "$STAGING" == "1" ]] && printf ' --staging'
        [[ "$FORCE" == "1" || "$RENEW_CERT" == "1" ]] && printf ' --force'
        [[ "$NO_RELOAD" == "1" ]] && printf ' --no-enable'
        printf '\n'
        [[ "$NO_RELOAD" == "1" ]] && printf 'reload command: %q %q --no-reload\n' "$BASE_DIR/scripts/enable-https.sh" "$PROJECT"
    elif [[ "$CERT_ACTION" == "self-signed" ]]; then
        printf 'cert command: %q %q\n' "$BASE_DIR/scripts/self-signed-cert.sh" "$PROJECT"
        printf 'enable command: %q %q' "$BASE_DIR/scripts/enable-https.sh" "$PROJECT"
        [[ "$NO_RELOAD" == "1" ]] && printf ' --no-reload'
        printf '\n'
    fi
    exit 0
fi

[[ "$NO_SAVE" == "1" ]] || save_env

"$BASE_DIR/scripts/add-site.sh" "${ADD_ARGS[@]}"

case "$CERT_ACTION" in
    none|reuse)
        :
        ;;
    self-signed)
        "$BASE_DIR/scripts/self-signed-cert.sh" "$PROJECT"
        if [[ "$NO_RELOAD" == "1" ]]; then
            "$BASE_DIR/scripts/enable-https.sh" "$PROJECT" --no-reload
        else
            "$BASE_DIR/scripts/enable-https.sh" "$PROJECT"
        fi
        ;;
    letsencrypt)
        ISSUE_ARGS=("$PROJECT" --email "$EMAIL")
        [[ "$STAGING" == "1" ]] && ISSUE_ARGS+=(--staging)
        [[ "$FORCE" == "1" || "$RENEW_CERT" == "1" ]] && ISSUE_ARGS+=(--force)
        if [[ "$NO_RELOAD" == "1" ]]; then
            ISSUE_ARGS+=(--no-enable)
            "$BASE_DIR/scripts/issue-cert.sh" "${ISSUE_ARGS[@]}"
            "$BASE_DIR/scripts/enable-https.sh" "$PROJECT" --no-reload
        else
            "$BASE_DIR/scripts/issue-cert.sh" "${ISSUE_ARGS[@]}"
        fi
        ;;
    *)
        die "internal error: unknown CERT_ACTION=$CERT_ACTION"
        ;;
esac

if [[ "$NO_RELOAD" == "1" ]]; then
    log "reload skipped; run: $BASE_DIR/scripts/reload.sh"
fi

log "project '$PROJECT' registered (domain=$DOMAIN, cert=$CERT_ACTION)"
