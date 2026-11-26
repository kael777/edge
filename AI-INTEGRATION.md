# Edge 接入文档（给 AI / 其他项目）

本文件是平台级共享 nginx 的接入契约。任何项目要把站点挂到这台机器，只按本文件操作；不要改 `edge/` 的镜像内部配置，也不要改其他项目的站点文件。

## 0. 角色边界

| 层 | 归属 | 职责 |
|---|---|---|
| `edge/` | 平台 | 全局唯一前置 nginx：80/443、TLS、SNI、证书、站点路由 |
| `projects/<name>.env` | 平台 | 项目注册表：域名、上游、证书模式 |
| 项目 compose | 项目 | 自己的 app/db/redis；只把 HTTP 入口服务接入 `edge` |
| `sites/<NN>-<name>.conf` | 平台生成 | 不要手改；由 `register-project.sh` 生成 |

固定事实：

- 网关占 80/443；项目**禁止**再发布 80/443。
- 项目只把 HTTP 入口服务接入 `edge`；数据库、Redis、队列不接。
- 接入 `edge` 的服务名必须全局唯一，例如 `a-web`、`b-web`；两个项目都叫 `web` 会抢同一个 DNS 名。
- 新增站点只新增 `sites/<NN>-<name>.conf` 和 `projects/<name>.env`，不改其他项目。

## 1. 两种场景

| 场景 | 触发 | 入口 |
|---|---|---|
| A. 新机器装机 | 新服务器第一次部署 | `scripts/bootstrap-edge.sh` |
| B. 新增站点 | 已有网关，新项目/新域名接入 | `projects/<name>.env` + `scripts/register-project.sh` |

---

## 2. 场景 A：新机器装机

### 2.1 前置

- Linux，root 或 sudo。
- 80/443 没有被宝塔/其他 nginx 占用。
- 能访问 Docker Hub 和 `get.docker.com`。
- 代码在 `/path/to/repo/edge`，或已经复制到 `/opt/edge/nginx-gateway`。

### 2.2 执行

```bash
cd /path/to/repo/edge
sudo ./scripts/bootstrap-edge.sh --install-docker
```

已经装好 Docker 的机器：

```bash
sudo ./scripts/bootstrap-edge.sh
```

脚本会：

1. 检查 Docker；带 `--install-docker` 且缺失时安装。
2. 检查 `docker compose` v2。
3. 创建 external network `edge`（已存在则跳过）。
4. 把 `edge/` 安装到 `/opt/edge/nginx-gateway`；已有 `sites/ certs/ acme/ wwwlogs/ projects/` 不覆盖。
5. `docker compose -f docker-compose.gateway.yml up -d --build`。
6. 检查容器内 `/healthz`。
7. 写 `/etc/cron.d/nginx-gateway-renew`，每天 03:17 续期证书。

开发机/非 root：

```bash
EDGE_ROOT="$HOME/edge" ./scripts/bootstrap-edge.sh --no-cron
```

### 2.3 验收

```bash
docker network inspect edge >/dev/null
docker ps --filter name=nginx-gateway
docker exec nginx-gateway wget -q -O - http://127.0.0.1:8080/healthz
docker exec nginx-gateway nginx -t
```

期望：

- `nginx-gateway` 容器 `Up`。
- `/healthz` 返回 `ok`。
- `nginx -t` 通过。
- 宿主机 80/443 由 `nginx-gateway` 监听。

### 2.4 禁止

- 不要在项目 compose 里发布 80/443。
- 不要在网关之前先起项目的前置 nginx。
- 不要用 `nginx:latest` / `nginx:stable`；基线是 `1.30.7-alpine`，Dockerfile 有版本门槛。
- 不要把证书、私钥、`.env`、业务静态文件打进网关镜像。
- 不要 `docker restart` 网关；配置变更用 `scripts/reload.sh`。

---

## 3. 场景 B：新增站点

### 3.1 项目 compose 改造

入口服务必须满足：

- 服务名唯一：`a-web`、`b-web`、`app-web`，不要叫 `web`。
- 加入 `edge` 网络。
- 不发布 80/443。
- DB/Redis 不接 `edge`。

```yaml
services:
  a-web:
    image: your-app:latest
    networks:
      edge:
        aliases:
          - a-web
    # 不要写 80:80 / 443:443
  a-db:
    image: postgres:16
    # 留在项目默认网络
  a-redis:
    image: redis:7
    # 留在项目默认网络

networks:
  edge:
    external: true
    name: edge
```

静态站点不需要入口服务，但要把宿主机目录只读挂到网关，例如：

```yaml
# edge/docker-compose.gateway.yml
volumes:
  - ./static/a:/srv/a:ro
```

然后 `projects/a.env` 用 `MODE=static`、`ROOT=/srv/a`。

### 3.2 写注册文件

`/opt/edge/nginx-gateway/projects/a.env`：

```env
PROJECT=a
DOMAIN=a.example.com
MODE=proxy
UPSTREAM=a-web:8080
BODY_SIZE=16m
WEBSOCKET=1
ADMIN_ALLOWLIST=203.0.113.10,10.0.0.0/8
EMAIL=ops@example.com
CERT_MODE=auto
STAGING=0
```

字段：

| 字段 | 必填 | 说明 |
|---|---|---|
| `PROJECT` | 是 | 必须和文件名一致 |
| `DOMAIN` | 是 | 域名 |
| `MODE` | 是 | `proxy` 或 `static` |
| `UPSTREAM` | proxy 必填 | `服务名:端口`，必须是 `edge` 里的唯一服务名 |
| `ROOT` | static 必填 | 容器内静态根，例如 `/srv/a` |
| `BODY_SIZE` | 否 | 默认 `1m` |
| `WEBSOCKET` | 否 | `1` 生成 `/ws/` |
| `ADMIN_ALLOWLIST` | 否 | 管理面板的 IP/CIDR 白名单，逗号分隔；仅 proxy |
| `ADMIN_PATH` | 否 | 管理面板前缀，默认 `/admin-panel/` |
| `SPA` | 否 | 静态回退 `/index.html` |
| `PRIORITY` | 否 | 两位；不填自动分配；覆盖时保留 |
| `EMAIL` | 视证书 | Let's Encrypt 邮箱 |
| `CERT_MODE` | 否 | `auto` / `letsencrypt` / `self-signed` / `none` |
| `STAGING` | 否 | `1` 用 Let's Encrypt staging |

### 3.2.1 管理面板白名单

管理面板建议在网关层加白名单；前缀默认 `/admin-panel/`，可用 `ADMIN_PATH` 改：

```env
ADMIN_ALLOWLIST=203.0.113.10,10.0.0.0/8
ADMIN_PATH=/admin-panel/
```

或：

```bash
./scripts/register-project.sh a   --domain a.example.com   --upstream a-web:8080   --admin-allowlist 203.0.113.10,10.0.0.0/8
```

生成：

```nginx
location ^~ /admin-panel/ {
    allow 203.0.113.10;
    allow 10.0.0.0/8;
    deny all;
    include /etc/nginx/snippets/proxy-common.conf;
    proxy_pass http://a_up;
}
```

`/admin` 仍由 origin 的 `deny all` 保护；管理端口不对外。

### 3.3 先 dry-run，再执行

```bash
cd /opt/edge/nginx-gateway
./scripts/register-project.sh a --dry-run
./scripts/register-project.sh a
```

执行内容：

1. 读 `projects/a.env`。
2. 生成 `sites/<NN>-a.conf`。
3. 有证书则直接 HTTPS；没有证书则先生成 HTTP + ACME。
4. `CERT_MODE=auto` 且有 `EMAIL`：签发 Let's Encrypt。
5. 在运行中的 `nginx-gateway` 里 `nginx -t`。
6. 通过后 `nginx -s reload`；失败自动回滚。

重复执行是幂等的：覆盖同名站点配置，保留优先级。

### 3.4 证书

首次签发前确认：

- 域名 A/AAAA 已解析到本机。
- 80 端口公网可达。
- 没有 Cloudflare 小黄云代理（HTTP-01 会被挡；需要 DNS-01）。

```bash
# 先 staging
./scripts/register-project.sh a --staging

# 再正式
./scripts/register-project.sh a
```

只补证书：

```bash
./scripts/issue-cert.sh a --email ops@example.com --staging
./scripts/issue-cert.sh a --email ops@example.com
```

自签/联调：

```bash
./scripts/self-signed-cert.sh a
./scripts/enable-https.sh a
```

### 3.5 验收

```bash
docker exec nginx-gateway nginx -t
curl -kI https://a.example.com/
curl -k  https://a.example.com/
```

容器内检查：

```bash
docker exec nginx-gateway grep -R "server_name a.example.com" /etc/nginx/sites
docker exec nginx-gateway nginx -T | grep -A5 "server_name a.example.com"
```

日志：

```bash
docker logs -f nginx-gateway
```

### 3.6 回滚 / 删除站点

```bash
cd /opt/edge/nginx-gateway
rm -f sites/20-a.conf
rm -f projects/a.env
# 证书默认保留；确认不再需要再删 certs/a/ 和 letsencrypt/live/a.example.com/
./scripts/reload.sh
```

不要只删项目容器而不清理 vhost，否则域名会一直打到 502。

---

## 4. 必须遵守的契约

1. 网关独占 80/443；项目不得发布这两个端口。
2. 项目入口服务名全局唯一；不要用 `web` 这种通用名。
3. 只有 HTTP 入口服务接 `edge`；DB/Redis/队列不接。
4. 站点只通过 `register-project.sh` 注册；不要手写 `sites/*.conf`。
5. `projects/<name>.env` 是项目注册的 source of truth；重复执行脚本收敛。
6. 新增项目不得修改其他项目的 `sites/*.conf`、`projects/*.env`。
7. 证书、私钥、`.env`、业务静态文件不进镜像、不进 git。
8. 配置变更先 `nginx -t`，再 `nginx -s reload`；禁止 `docker restart`。
9. 换域名不要只 `--force`：旧证书 CN/SAN 不匹配。用新 site 名，或先移走 `certs/<site>/` 和 `letsencrypt/live/<旧域名>/`。
10. 2026-11-18 之后基线必须 ≥ nginx 1.30.7；不要降级到 1.30.6/1.28.x。
11. 删除站点用 `scripts/remove-project.sh <name>`；证书到期检查用 `scripts/check-certs.sh`。

## 5. AI 操作顺序

给 AI 的硬性顺序：

1. 读本文件 + `edge/SPEC.md` + 目标项目 compose。
2. 判断场景：新机器（A）还是新增站点（B）。
3. 场景 A：只在机器初始化时执行 `bootstrap-edge.sh`；不要重复装 Docker。
4. 场景 B：先改项目 compose（唯一入口服务、接 `edge`、不发布 80/443）。
5. 写/改 `projects/<name>.env`。
6. 先 `register-project.sh <name> --dry-run`，把输出给用户确认。
7. 再正式执行；确认 `nginx -t`、`/healthz`、curl 目标域名。
8. 失败时先回滚 `sites/*.conf` 和 `projects/*.env`，不要改网关内部配置。

AI 禁止：

- 禁止编辑 `edge/conf.d/`、`edge/nginx.conf`、`edge/snippets/`，除非任务明确是平台升级。
- 禁止编辑其他项目的 `sites/*.conf`。
- 禁止在项目 compose 加 `80:80` / `443:443`。
- 禁止把 DB/Redis 接到 `edge`。
- 禁止 `docker restart nginx-gateway`。
- 禁止使用 `nginx:latest` / `nginx:stable`。
- 禁止把证书私钥写进仓库。

## 6. 现有项目迁移示例

如果项目已经自带 nginx，先做最小迁移，不要一上来搬全部路由：

1. 保留项目入口服务作为内部 origin，改名为 `<project>-web`，不要继续叫 `web`。
2. 删除公网 `80:80`、`443:443` 映射。
3. 给 `<project>-web` 加 `edge` 网络，服务名/alias 都是 `<project>-web`。
4. 项目专用端口按需保留在项目侧，或后续迁移到网关 `stream`。
5. 注册：

```bash
cd /opt/edge/nginx-gateway
./scripts/register-project.sh app \
  --domain app.example.com \
  --upstream app-web:80 \
  --email ops@example.com
```

这样网关负责 80/443/TLS，`app-web` 只处理内部路由和静态文件。后续再把 `origin.conf` 的路由逐段上移到网关。

## 7. 常见故障

| 现象 | 原因/处理 |
|---|---|
| 502 | 上游容器没起、服务名/端口错、alias 冲突；`docker ps`、`docker network inspect edge` |
| 404 | `server_name` 不匹配、站点文件没被 include、域名解析到别的机器 |
| 413 | `BODY_SIZE` 太小；改 `projects/<name>.env` 后重新 register |
| 证书失败 | 80 不通、DNS 未生效、Cloudflare 代理、staging 限制；先 `--staging` |
| `zone ... is too small` | upstream zone <128k；改成 `128k` |
| `"resolve" parameter is not supported` | nginx <1.27.3；基线 1.30.7 |
| 两个项目互相打到 | 两个入口服务都叫 `web`；改成唯一服务名 |
| 端口占用 | 宝塔/其他 nginx 占了 80/443；停掉或让网关独占 |
| 改配置没生效 | 只改了文件没 reload；执行 `./scripts/reload.sh` |
