# nginx-gateway

薄 nginx 网关。镜像只含运行时、全局策略、公共 snippet、健康检查；站点、证书、静态文件、日志全部外部挂载。

It is a project develop by AI for deploy AI developed project(this is the only human sentence :D)

## 接入文档

- [AI-INTEGRATION.md](AI-INTEGRATION.md)：给 AI / 其他项目的接入契约，覆盖“新机器装机”和“新增站点”两种场景。
- [onboarding/README.md](onboarding/README.md)：项目 B 的交付包清单、责任边界和验收。
- [SPEC.md](SPEC.md)：网关自身的硬性规约。

## 版本与安全基线

- 基线：`nginx:1.30.7-alpine@sha256:caf4...`，即 2026-11-18 的稳定版安全更新，修复 NGINX2Root 的五个 CVE。
- 禁止使用 1.30.6 及以下；1.28.x 已不是当前稳定分支。Dockerfile 里加了构建期版本门槛，低于 1.30.7 直接构建失败。
- certbot 也锁 digest（`CERTBOT_IMAGE`），避免 `latest` 漂移。
- “无漏洞”无法承诺；必须每月重建、用 `trivy`/`grype` 扫描、按 nginx 安全公告升级，并按 digest 部署。
- `server_tokens off;` 已在 `nginx.conf` 默认开启：响应头只显示 `Server: nginx`，不显示版本号。若要去掉整个 `Server` 头，需要 headers-more 等额外模块，不在薄镜像默认层。

## 目录

```text
edge/
├── README.md
├── SPEC.md
├── AI-INTEGRATION.md        # 给 AI/其他项目的接入契约
├── Dockerfile
├── nginx.conf
├── docker-compose.gateway.yml
├── conf.d/                  # 镜像自带，禁止整目录覆盖挂载
│   ├── 00-common.conf
│   └── 00-health.conf
├── snippets/                # 镜像自带
├── stream.d/                # 镜像自带
├── sites/                   # 部署侧，挂载到 /etc/nginx/sites:ro
│   ├── 00-default.conf
│   └── .meta/               # add-site.sh 写入的站点元数据
├── certs/                   # 挂载到 /etc/nginx/certs:ro
├── acme/                    # 挂载到 /var/www/acme:ro
├── wwwlogs/                 # 挂载到 /www/wwwlogs
├── letsencrypt/             # certbot 账户/证书，不挂进 nginx
├── letsencrypt-lib/         # certbot 工作目录
├── projects/                # 项目注册
│   ├── example.env.example
│   └── README.md
├── onboarding/              # 交给新项目的交付包
│   ├── README.md
│   ├── b.env.example
│   └── docker-compose.edge.example.yml
└── scripts/
    ├── bootstrap-edge.sh
    ├── register-project.sh
    ├── add-site.sh
    ├── remove-project.sh
    ├── enable-https.sh
    ├── issue-cert.sh
    ├── renew-certs.sh
    ├── check-certs.sh
    ├── self-signed-cert.sh
    ├── reload.sh
    └── lib.sh
```

## 新机器初始化（推荐）

```bash
cd edge
sudo ./scripts/bootstrap-edge.sh --install-docker
```

做四件事：安装 Docker（可选）、创建 `edge` 网络、启动 gateway、安装证书续期/检查 cron。默认安装到 `/opt/edge/nginx-gateway`，可重复执行，不覆盖 `sites/ certs/ acme/ wwwlogs/ projects/` 里的已有数据。

## 项目注册（A/B 共用前置）

A 项目：

```bash
cd /opt/edge/nginx-gateway
cp projects/example.env.example projects/a.env
vi projects/a.env
# PROJECT=a
# DOMAIN=a.example.com
# MODE=proxy
# UPSTREAM=a-web:8080
# EMAIL=ops@example.com
./scripts/register-project.sh a
```

B 项目后加入：

```bash
cp projects/example.env.example projects/b.env
vi projects/b.env
./scripts/register-project.sh b
```

只会新增 `sites/20-b.conf` 并 reload，A 不受影响。项目 compose 只把 HTTP 入口服务接入 `edge`，使用唯一服务名/alias（`a-web`、`b-web`）；数据库和 Redis 不要接 `edge`。

## 手工启动（已有 Docker/网络）

```bash
cd edge

# 业务容器要加入的网络，只需一次
docker network create edge

docker compose -f docker-compose.gateway.yml up -d --build
docker compose -f docker-compose.gateway.yml ps
docker exec nginx-gateway wget -q -O - http://127.0.0.1:8080/healthz
```

业务 compose 只把 **HTTP 入口服务**接入同一网络。最小迁移方式：保留项目自己的入口服务作为内部 origin，服务名改成 `app-web`，网关只反代它：

```yaml
services:
  app-web:
    networks:
      edge:
        aliases:
          - app-web

networks:
  edge:
    external: true
    name: edge
```

注意：接入 `edge` 的服务名本身必须唯一。Compose 会把服务名注册成网络 alias，两个项目都叫 `web` 时，即使加自定义 alias 也会抢同一个 DNS 名。把入口服务直接命名为 `app-web` / `a-web` / `b-web`。

然后注册：

```bash
./scripts/add-site.sh app app.example.com --upstream app-web:80
```

只有当你决定把原 `origin.conf` 的全部路由拆到网关时，才把 `app-panel/app-admin/app-php/app-c2c` 也接 `edge`：

```yaml
services:
  panel:
    networks:
      edge:
        aliases: [ios-panel]
  admin:
    networks:
      edge:
        aliases: [ios-admin]
  php:
    networks:
      edge:
        aliases: [ios-php]
  c2c:
    networks:
      edge:
        aliases: [app-c2c]
```

数据库、Redis、内部队列不要接 `edge`。两个项目的入口服务不能都叫 `web`，必须用唯一 alias。

## 加新站点

多项目共用前置时，优先用 `register-project.sh`（读 `projects/<name>.env`，自动加站点 + 证书）。下面是底层 `add-site.sh` 的用法。

反代站点：

```bash
./scripts/add-site.sh app2 app2.example.com \
  --upstream app2:3000 \
  --websocket \
  --body-size 16m
```

静态站点：

```bash
# 先确认 compose 有只读挂载：
#   - ./static/docs:/srv/docs:ro
./scripts/add-site.sh docs docs.example.com \
  --root /srv/docs \
  --spa
```

生成结果（`<NN>` 为自动分配的优先级，首个业务站通常是 10）：

```text
sites/<NN>-app2.conf
sites/.meta/app2.env
```

如果 `certs/app2/` 已有证书，`add-site.sh` 直接生成 HTTPS；否则生成 HTTP + ACME，并提示下一步签发。

覆盖已有站点：

```bash
./scripts/add-site.sh app2 app2.example.com --upstream app2:3000 --force
```

`--no-reload` 只写文件，不执行 `nginx -t`/reload。

注意：只改域名时不要只 `--force`。`certs/<site>/` 里的旧证书 CN/SAN 不匹配新域名，浏览器仍会报错。换域名用新的 site 名，或先移走 `certs/<site>/` 和 `letsencrypt/live/<旧域名>/` 再重新 `issue-cert.sh`。

## 管理面板 IP 白名单（可选）

给管理面板加网关层白名单；前缀默认 `/admin-panel/`，可用 `ADMIN_PATH` 改：

```env
# projects/<name>.env
ADMIN_ALLOWLIST=203.0.113.10,10.0.0.0/8
ADMIN_PATH=/admin-panel/
```

或命令行：

```bash
./scripts/register-project.sh aa \
  --domain aa.example.com \
  --upstream app-web:80 \
  --admin-allowlist 203.0.113.10,10.0.0.0/8 \
  --admin-path /admin-panel/
```

生成的站点会多一个：

```nginx
location ^~ /admin-panel/ {
    allow 203.0.113.10;
    allow 10.0.0.0/8;
    deny all;
    include /etc/nginx/snippets/proxy-common.conf;
    proxy_pass http://aa_up;
}
```

注意：

- 只对 proxy 站点生效。
- 白名单只保护 `/admin-panel/`；`/admin` 本来就被 origin 拒绝。
- 也可以用 `snippets/admin-allowlist.conf` 手工 include，但 `register-project.sh --force` 会重写自动生成的站点，优先用 `ADMIN_ALLOWLIST`。

## 加 HTTPS

证书脚本会读写 600 私钥和 Docker 挂载目录，建议用 **root 或 sudo** 执行；至少保证当前用户对 `letsencrypt/`、`certs/`、`acme/` 有读写权限。

### Let's Encrypt（生产）

前置：

- 域名 A/AAAA 已解析到本机。
- 80 端口能从公网访问。
- 站点已由 `add-site.sh` 创建，80 配置包含 `snippets/acme.conf`。
- 不要开 Cloudflare 小黄云代理，除非改用 DNS-01。

```bash
./scripts/issue-cert.sh app2 --email ops@example.com --staging   # 先演练
./scripts/issue-cert.sh app2 --email ops@example.com             # 正式
```

脚本会：

1. `certbot certonly --webroot` 签发到 `letsencrypt/`。
2. 复制 `fullchain.pem`、`privkey.pem` 到 `certs/app2/`。
3. 自动执行 `enable-https.sh app2`：HTTP 保留 ACME 并 301 到 HTTPS，新增 443 server。
4. 在运行中的 `nginx-gateway` 容器里 `nginx -t`，通过后 `nginx -s reload`；失败自动回滚。

已有证书、只想切 HTTPS：

```bash
./scripts/enable-https.sh app2
```

### 自签（内网/联调）

```bash
./scripts/self-signed-cert.sh app2
./scripts/enable-https.sh app2
```

### 续期

```bash
./scripts/renew-certs.sh
```

cron 示例：

```cron
17 3 * * * cd /opt/nginx-gateway && ./scripts/renew-certs.sh >> wwwlogs/renew.log 2>&1
```

`renew-certs.sh` 会续期 `letsencrypt/` 下所有证书，按 `.meta` 复制到 `certs/<site>/`，有变化才 reload。

## 手工 reload

```bash
./scripts/reload.sh
```

等价于：

```bash
docker exec nginx-gateway nginx -t
docker exec nginx-gateway nginx -s reload
```

## 从项目自带 nginx 迁移

最小迁移：保留项目自己的入口服务作为内部 origin，改名为 `<project>-web`，删掉公网 80/443，只接 `edge`；网关直接反代：

```bash
./scripts/register-project.sh app \
  --domain app.example.com \
  --upstream app-web:80 \
  --email ops@example.com
```

这样不用把项目原有的 `origin.conf` 搬进网关。只有决定把路由全部上移时，才做完全迁移：

1. 备份项目原有 nginx 配置。
2. 将 `origin.conf` 复制为 `sites/10-<project>.conf`。
3. 删除文件顶部的 `resolver`，改用镜像全局 resolver。
4. upstream 的 `zone ... 64k` 改成 `128k`：新版 nginx 对 `resolve` upstream 的 zone 最小尺寸更严，64k 会报 `zone ... is too small`。
5. upstream 改名为 `<project>-<role>`，并让对应服务接 `edge`、加唯一 alias。
6. 静态根改到 `/srv/<project>`，按目录逐条只读挂载，不要整仓挂进网关。
7. 证书迁到 `certs/<project>/`。
8. 项目专用端口按需保留在项目侧，或迁移到网关 `stream`。
9. 先保留旧入口容器停机作为回滚，观察后再删除。

## Shell 自动化能到哪一步

可以替代宝塔里“nginx 站点 + 证书”这一小块，而且更适合版本化：

| 能力 | Shell 方案 | 结论 |
|---|---|---|
| 新机器初始化 | `bootstrap-edge.sh`：装 Docker、建网络、起网关、装 cron | 可行 |
| 多项目注册 | `projects/<name>.env` + `register-project.sh` | 可行 |
| 新增/覆盖站点 | `add-site.sh` 生成 vhost + meta | 可行 |
| 删除站点 | `remove-project.sh` 备份、校验、reload | 可行 |
| 申请证书 | certbot webroot + `issue-cert.sh` | 可行 |
| 续期 | cron + `renew-certs.sh` | 可行 |
| 证书到期检查 | `check-certs.sh` + cron/监控 | 可行 |
| 配置校验 | `nginx -t` 后 reload | 必须 |
| 回滚 | 备份上一版 + `nginx -t` 失败自动恢复 | 可行 |
| 多租户 UI / 权限 / 审计 | Shell 不适合 | 用面板或控制器 |
| 多节点一致性 | 单机 shell 不够 | 用 Ansible/Terraform/GitOps |
| 复杂 DNS-01 / 多 CA | certbot 插件或 acme.sh | 可行，但脚本复杂度上升 |
| 高可用 / 动态扩缩 | Shell 不适合 | 用 Traefik/Caddy/Ingress |

结论：**单机、单网关、站点数量可控时，shell 自动化完全可行**。不要把宝塔整个面板用 bash 重写；只把“生成配置、签发证书、校验、reload、备份回滚”做成脚本，配置进 git，cron 做续期。

脚本层安全约束：

- 所有脚本 `set -euo pipefail`。
- 写配置用临时文件 + 原子 `mv`。
- 改配置前备份到 `sites/.backup/`。
- 先 `nginx -t`，失败自动回滚，不 reload。
- 同名站点默认拒绝覆盖，必须显式 `--force`。
- 证书先 `--staging` 演练，再正式。
- 操作加 `flock`/目录锁，避免并发写。
- 日志写 `wwwlogs/`，cron 输出重定向。
- 不把证书、私钥、`.env` 放进镜像或 git。

## 证书检查与删除项目

```bash
# 检查 certs/*/fullchain.pem 是否在 21 天内过期；失败返回 1
./scripts/check-certs.sh

# 删除站点注册，默认保留证书
./scripts/remove-project.sh aa

# 连证书一起删
./scripts/remove-project.sh aa --purge-cert
```

`check-certs.sh` 已加入 bootstrap 的 cron（每天 04:17），也可接外部监控。

## 回滚

- 配置：从 `sites/.backup/` 取上一版，`./scripts/reload.sh`。
- 镜像：切回上一个 digest，`docker compose -f docker-compose.gateway.yml up -d`。
- 证书：保留 `letsencrypt/` 历史；紧急情况从 `certs/<site>/` 恢复上一份文件后 reload。
