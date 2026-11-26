# nginx-gateway 薄镜像
# 只放运行时、全局策略、公共 snippet、健康检查；站点/证书/静态文件全部外部挂载。
# 构建：docker build -t registry.example.com/platform/nginx-gateway:1.30.7-r1 .
# 基线：nginx 1.30.7 stable（2026-11-18 安全版本，修复 NGINX2Root 五个 CVE）。
# 禁止回退到 1.30.6 及以下；1.28.x 已不是当前稳定分支。
# 已锁多架构 manifest digest；升级时同时更新 tag + digest。
FROM nginx:1.30.7-alpine@sha256:caf4e1e032a20f9c3c5e28fc7f25ffd768ad8677b4975c54193075997b3a97e3

# 构建期硬门槛：低于 1.30.7 直接失败，防止误用带 NGINX2Root 漏洞的基线。
# 同时确认官方镜像带 stream 模块（本项目 nginx.conf 使用 stream {}）。
RUN set -eux; \
    v="$(nginx -v 2>&1 | awk -F/ '{print $2}')"; \
    major="${v%%.*}"; rest="${v#*.}"; minor="${rest%%.*}"; patch="${rest#*.}"; patch="${patch%%[!0-9]*}"; \
    if [ "$major" -lt 1 ] || { [ "$major" -eq 1 ] && [ "$minor" -lt 30 ]; } || { [ "$major" -eq 1 ] && [ "$minor" -eq 30 ] && [ "$patch" -lt 7 ]; }; then \
        echo "ERROR: nginx >= 1.30.7 required, got $v" >&2; \
        exit 1; \
    fi; \
    nginx -V 2>&1 | grep -q -- '--with-stream'

LABEL org.opencontainers.image.title="nginx-gateway" \
      org.opencontainers.image.description="Thin nginx gateway: runtime + shared policy, site configs mounted at runtime" \
      org.opencontainers.image.version="1.30.7-r1" \
      org.opencontainers.image.source="https://git.example.com/platform/nginx-gateway"

# 官方镜像自带 default.conf 会在 80 端口多出一个默认站点，必须清掉。
RUN rm -f /etc/nginx/conf.d/default.conf

COPY nginx.conf /etc/nginx/nginx.conf
COPY conf.d/ /etc/nginx/conf.d/
COPY snippets/ /etc/nginx/snippets/
COPY stream.d/ /etc/nginx/stream.d/

# 镜像自带配置自检；带 sites/ 的完整校验在 CI 或运行中的容器里做。
RUN nginx -t

EXPOSE 80 443 8080
STOPSIGNAL SIGQUIT

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD wget -q -O - http://127.0.0.1:8080/healthz || exit 1
