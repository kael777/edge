# nginx-gateway 规约

关键词：**必须 / 禁止** 为硬约束，**应当** 为默认做法，**可以** 为可选。

## 0. 定位

- 镜像：`registry.example.com/platform/nginx-gateway`。
- 镜像只提供 nginx 运行时、全局策略、公共 snippet、健康检查。
- 站点 vhost、证书、静态文件、环境域名、业务密钥全部外部挂载。
- 禁止挂 Docker socket，禁止把应用源码根目录整体挂进网关。

## 1. 镜像边界

| 内容 | 进镜像 | 外部挂载 |
|---|---|---|
| `nginx.conf` | 必须 | 禁止 |
| `conf.d/00-common.conf` | 必须 | 禁止 |
| `conf.d/00-health.conf` | 必须 | 禁止 |
| `snippets/*.conf` | 必须 | 禁止 |
| `stream.d/00-common.conf` | 可以 | — |
| `sites/*.conf` | 禁止 | 必须 |
| `streams/*.conf` | 禁止 | 可以 |
| `certs/`、私钥 | 禁止 | 必须 |
| `acme/` | 禁止 | 必须 |
| 业务静态文件 | 禁止 | 按站点显式只读挂载 |
| `.env`、应用密钥 | 禁止 | 不注入网关 |

## 2. 目录契约

```text
/etc/nginx/
├── nginx.conf                  # 镜像
├── conf.d/                     # 镜像，禁止整目录覆盖挂载
│   ├── 00-common.conf
│   └── 00-health.conf
├── snippets/                   # 镜像
├── stream.d/                   # 镜像，可选
├── sites/                      # 挂载，只读
├── streams/                    # 挂载，只读，可选
├── certs/                      # 挂载，只读
└── snippets.local/             # 挂载，只读，可选
```

`nginx.conf` 固定 include 顺序：

```nginx
http {
    include /etc/nginx/conf.d/*.conf;
    include /etc/nginx/sites/*.conf;
}

stream {
    include /etc/nginx/stream.d/*.conf;
    include /etc/nginx/streams/*.conf;
}
```

- `conf.d/` 归镜像所有；禁止把宿主机目录挂到 `/etc/nginx/conf.d`。
- `sites/` 归部署所有，文件名前缀 `10-`、`20-`、`30-`。
- `snippets/` 归镜像所有；站点私有 snippet 放 `snippets.local/`。
- `projects/` 是项目注册表，不挂进 nginx；每项目一个 `<name>.env`。
- 外部挂载必须 `:ro`，日志目录除外。

## 3. 构建

- 必须使用 `nginx:1.30.7-alpine` 或更高 1.30.x，并锁 digest。
- 禁止使用 1.30.6 及以下。1.30.7 是 2026-11-18 安全版本，修复 NGINX2Root 的五个 CVE；1.28.x 已不是当前稳定分支。
- 禁止 `nginx:latest`、`nginx:stable` 作为生产 tag。
- 应当同时构建 `linux/amd64` 和 `linux/arm64`。
- 必须删除官方 `/etc/nginx/conf.d/default.conf`。
- 构建阶段 `RUN nginx -t` 只校验镜像自带配置；带 `sites/` 的完整校验放 CI 或运行中容器。
- 不存在“零漏洞”承诺；必须建立月度重建 + CVE 扫描 + 按安全公告回滚/升级的流程。

参考 Dockerfile 见 `Dockerfile`。

## 4. 全局 nginx.conf

参考 `nginx.conf`。约束：

- 全局日志必须走 stdout/stderr。
- 必须保持 `server_tokens off;`：响应头只保留 `Server: nginx`，不显示版本号。若要去掉整个 `Server` 头，需额外模块或上游处理，不放进薄镜像默认层。
- `client_max_body_size` 默认 1m，站点按需覆盖，禁止全局放宽。
- `resolver 127.0.0.11` 仅适用于 Docker 用户自定义网络；禁止 `network_mode: host`。
- 全局禁止写 `server { }`；server 只出现在 `conf.d/00-health.conf` 和 `sites/`。
- HSTS、CSP、限流不得默认强加，按站点 opt-in。
- 健康检查只监听 `127.0.0.1:8080`，禁止对外发布。

## 5. 公共 snippet

- `proxy-common.conf`：普通 HTTP 反代公共头，含 connect/send timeout；不写 `proxy_read_timeout`，避免和 `websocket.conf` 重复。
- `websocket.conf`：WebSocket/SSE，必须在 `proxy-common.conf` 之后 include；它负责把 `proxy_read_timeout` 覆盖为 86400s。
- `ssl-common.conf`：TLS 1.2/1.3、session、497。
- `acme.conf`：HTTP-01 校验路径。
- `static.conf`：静态默认不缓存、不 gzip。
- `security-headers.conf`：基础安全头，按站点 opt-in。
- `deny-dotfiles.conf`：server 级拒绝点文件，放行 ACME。

## 6. 站点文件

命名：

```text
sites/00-default.conf
sites/10-app.conf
sites/20-app-c2c.conf
sites/30-app2.conf
```

必须：

- 一个文件只放一个逻辑站点/域名组。
- 业务 server 必须写显式 `server_name`；禁止用 `_` 兜业务。
- 上游名全局唯一，格式 `<project>-<role>`，例如 `ios-panel`。
- 有上游的站点必须使用 `upstream + zone + resolve`，或变量 `proxy_pass`；禁止裸写 `proxy_pass http://service:port`。
- `zone` 至少 `128k`；64k 在较新 nginx 上会报 `zone ... is too small`。
- 证书路径固定为 `/etc/nginx/certs/<site>/fullchain.pem` 和 `privkey.pem`。
- 请求体超过 1m 的 location 必须显式 `client_max_body_size`。
- 静态文件只能挂到 `/srv/<site>/...`，禁止把整个仓库根挂进网关。
- 80 端口的 ACME location 必须在 301 跳转之前。
- `default_server` 只允许出现在 `sites/00-default.conf`。

站点生成优先使用 `scripts/add-site.sh`，不要手写重复配置。

## 7. 证书

- 目录：`certs/<site>/fullchain.pem`、`certs/<site>/privkey.pem`。
- 私钥 600，目录 700，属主 root。
- 证书目录只读挂载；禁止写进镜像、禁止进 git。
- 轮换：替换文件 → `nginx -t` → `nginx -s reload`。
- ACME webroot：网关只读挂载 `/var/www/acme`；签发容器读写挂载。
- HSTS 在全站 HTTPS 验证完成后按站点开启。

## 8. 网络与命名

- 网关和上游必须在同一 external network，例如 `edge`。
- compose 服务名固定 `gateway`；容器名 `nginx-gateway`。
- 跨项目上游必须加唯一 alias，例如 `ios-panel`。
- 禁止多个项目复用同一 alias。
- 网关只发布 80/443 和明确需要的业务端口；应用端口默认绑 `127.0.0.1`。
- 禁止 `network_mode: host`、禁止挂 Docker socket。

### 8.1 项目注册契约

每个项目一个 `projects/<name>.env`：

```env
PROJECT=a
DOMAIN=a.example.com
MODE=proxy
UPSTREAM=a-web:8080
BODY_SIZE=16m
WEBSOCKET=1
ADMIN_ALLOWLIST=203.0.113.10,10.0.0.0/8
ADMIN_PATH=/admin-panel/
EMAIL=ops@example.com
CERT_MODE=auto
```

规则：

- 项目只把 HTTP 入口服务接入 `edge`，数据库、Redis、队列不接。
- 入口服务 alias 必须唯一，例如 `a-web`、`b-web`；禁止两个项目都用 `web`。
- 项目不得发布 80/443；由网关统一占用。
- 项目部署最后一步执行 `scripts/register-project.sh <name>`，由网关统一 `add-site + 证书 + reload`。
- `register-project.sh` 必须幂等：重复执行覆盖同名站点配置，但保留优先级和数据。
- 新增项目只允许新增 `sites/<NN>-<name>.conf` 和 `projects/<name>.env`，不得改其他项目配置。
- 删除项目必须显式执行 `remove-project.sh` 并 reload，不能直接删容器后不清理 vhost。
- 公网管理面板（默认前缀 `/admin-panel/`，可用 `ADMIN_PATH` 改）应当用 `ADMIN_ALLOWLIST` 或网关侧 IP 白名单限制；`/admin` 由 origin 继续 `deny all`。

## 9. 日志与可观测

- 全局 access/error 走 stdout/stderr。
- 需要审计的站点可额外写 `/www/wwwlogs/<site>.log`，由宿主机轮转。
- 日志格式包含 `$request_id`、`$upstream_addr`、`$upstream_response_time`。
- `/healthz` 不记 access log。
- `stub_status` 如需要，只监听 `127.0.0.1:8081`。
- 指标 exporter 用 sidecar，不打进网关镜像。

## 10. 发布与版本

Tag：

```text
1.30.7-r1      # nginx 版本 + 镜像修订号
1.30           # 浮动 minor，仅测试
sha-<commit>   # 不可变构建
```

- 生产按 digest 部署，禁止 `latest`。
- 基础镜像和 certbot 镜像都锁 digest；每月重建补 CVE。
- 镜像修订号只在镜像内文件变化时递增；站点配置变化不触发镜像重建。
- 发布产物：镜像 + SBOM + 漏洞扫描 + cosign 签名。

CI 最少：

```bash
docker buildx build --platform linux/amd64,linux/arm64 -t "$IMAGE:$TAG" .
docker run --rm "$IMAGE:$TAG" nginx -t
docker run --rm "$IMAGE:$TAG" nginx -V 2>&1 | grep -E 'with-stream|with-http_ssl'
docker run --rm -v "$PWD/sites:/etc/nginx/sites:ro" -v "$PWD/test-certs:/etc/nginx/certs:ro" "$IMAGE:$TAG" nginx -t
trivy image "$IMAGE:$TAG"
syft "$IMAGE:$TAG" -o spdx-json > sbom.json
cosign sign "$IMAGE@$DIGEST"
```

### 10.1 机器初始化

新机器只执行一次：

```bash
sudo ./scripts/bootstrap-edge.sh --install-docker
```

- 默认安装到 `/opt/edge/nginx-gateway`。
- 创建 external network `edge`。
- 启动 gateway 并做 `/healthz` 检查。
- 安装 `/etc/cron.d/nginx-gateway-renew`：03:17 续期，04:17 检查证书到期。
- 可重复执行：代码覆盖，`sites/ certs/ acme/ wwwlogs/ projects/` 不覆盖。
- `--install-docker` 仅 Linux/root；其他系统先手工装 Docker。
- 生产环境应当从镜像仓库拉取已扫描的 gateway 镜像，而不是每次在宿主机 build。

## 11. 运行与变更

参考 `docker-compose.gateway.yml`。约束：

- 只改 `sites/`、`certs/`：`nginx -t` → `nginx -s reload`，不重建容器。
- 改镜像内文件：重新构建、打 `rN`、按 digest 发布。
- 禁止 `docker restart` 代替 reload。
- 禁止进容器改配置。
- 回滚：切回上一个 digest 或上一版配置。
- 删除项目：`scripts/remove-project.sh <name>`，默认保留证书；`--purge-cert` 才删证书。
- 证书检查：`scripts/check-certs.sh`，默认 21 天预警，失败返回 1，可接监控。

## 12. 从项目自带 nginx 迁移

最小迁移：保留项目自己的入口服务作为内部 origin，改名为 `<project>-web`，删掉公网 80/443，只接 `edge`；网关用 `add-site.sh <project> <domain> --upstream <project>-web:80` 反代。这样不需要搬项目原有的 `origin.conf`。

完全迁移：把路由逐段搬到网关，按下面步骤执行。

1. 使用顶层 `edge/`（`edge/nginx-gateway` 是安装后的运行目录）。
2. `origin.conf` → `sites/10-<project>.conf`。
3. 删除文件顶部 `resolver`，改用镜像全局 resolver。
4. upstream 改名 `<project>-<role>` 并加 compose alias。
5. 静态根改到 `/srv/<project>`，按需逐条只读挂载。
6. 证书迁到 `certs/<project>/`。
7. 项目专用端口按需保留在项目侧，或迁移到网关 `stream`。
8. 保留旧入口容器停机作为回滚。

## 13. 验收

- `docker run --rm image nginx -t` 通过。
- 镜像内 `sites/`、`certs/` 为空或不存在。
- `scripts/bootstrap-edge.sh --no-start --no-cron` 可重复执行，不覆盖已有 sites/certs/projects。
- `scripts/register-project.sh <name> --dry-run` 不写文件；正式执行可重复注册同一项目。
- 项目入口服务只在 `edge` 上有唯一 alias，未发布 80/443。
- `nginx -V` 含 `--with-stream`（需要时）。
- 镜像无证书、无私钥、无 `.env`、无业务静态文件。
- `sites/`、`certs/`、`acme/` 全部 `:ro`。
- `/healthz` 返回 200，8080 未对外。
- 80/443 只暴露网关。
- `nginx -t` 后 `nginx -s reload` 零中断。
- 日志可见且带 `request_id`。
- 回滚 digest 可用。
- 生产按 digest 部署。

## 14. 禁止项

- `FROM nginx:latest` / `nginx:stable` 浮动 tag。
- 把 `sites/`、证书、私钥、业务静态文件打进镜像。
- 把宿主机目录直接覆盖挂到 `/etc/nginx/conf.d`。
- 在网关挂应用源码根目录、数据库目录、Docker socket。
- 裸 `proxy_pass http://service:port`，不配 `resolve`/变量。
- 多个 `default_server`，或拿业务证书当默认证书。
- 用 `if` 写复杂路由；只允许 `return`、`rewrite ... break`。
- 公网暴露 8080、`stub_status`。
- 进容器改配置，或 `docker restart` 代替 reload。
- 一个网关容器跨多个互不信任的项目共用。镜像可以共用，容器按信任边界拆。
