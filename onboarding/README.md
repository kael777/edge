# 项目 B 接入交付包

给项目 B 的只有“文档 + 两个模板 + 一条命令”，不要把 `edge/` 的写权限、证书、其他项目配置交给 B。

## 交付文件

| 文件 | 用途 |
|---|---|
| `edge/AI-INTEGRATION.md` | 接入契约：网络、服务名、证书、禁止项 |
| `edge/onboarding/b.env.example` | B 的项目注册表模板；填好交回平台 |
| `edge/onboarding/docker-compose.edge.example.yml` | B 的 compose 接入示例 |
| `edge/README.md` | 平台背景，可选 |

不要给 B：

- `edge/sites/*.conf` 写权限
- `edge/certs/`、`edge/letsencrypt/` 访问权限
- 其他项目的 `projects/*.env`
- gateway 的 `nginx.conf`、`conf.d/`、`snippets/`

## 责任边界

| 角色 | 负责 |
|---|---|
| 平台 | 80/443、TLS、证书续期、`sites/*.conf`、网关 reload |
| 项目 B | 自己的 compose/app/db/redis；入口服务接 `edge`；提供 `b.env` |
| 平台或 B 的部署 agent | 执行 `register-project.sh b`（需要平台机器权限） |

## B 要做的三件事

### 1. 改 compose

入口服务必须：

- 服务名唯一：`b-web`，不要叫 `web`。
- 加入 `edge` 网络。
- 不发布 80/443。
- DB/Redis 不接 `edge`。

参考 `docker-compose.edge.example.yml`。

### 2. 填 `b.env`

把 `b.env.example` 复制到 B 的仓库，例如 `deploy/edge.env`，填：

```env
PROJECT=b
DOMAIN=b.example.com
MODE=proxy
UPSTREAM=b-web:8080
BODY_SIZE=16m
WEBSOCKET=1
EMAIL=ops@example.com
CERT_MODE=auto
STAGING=0
```

要求：

- `PROJECT` 必须是 `b`，和最终文件名 `projects/b.env` 一致。
- `UPSTREAM` 必须是 B 在 `edge` 网络里的唯一服务名 + 端口。
- 静态站点用 `MODE=static`、`ROOT=/srv/b`，并让平台把静态目录只读挂到网关。
- 域名 A/AAAA 先解析到本机；80 端口要能被 Let's Encrypt 访问。
- 换域名不要复用旧证书；用新 project 名或先清旧证书。
- 管理面板需要限制来源时加 `ADMIN_ALLOWLIST=203.0.113.10,10.0.0.0/8`，只影响管理面板前缀（默认 `/admin-panel/`，可用 `ADMIN_PATH` 改）。

### 3. 交回平台，或让平台执行注册

B 把 `deploy/edge.env` 交给平台。平台执行：

```bash
install -m 0644 /path/to/b/deploy/edge.env /opt/edge/nginx-gateway/projects/b.env
cd /opt/edge/nginx-gateway
./scripts/register-project.sh b --dry-run
./scripts/register-project.sh b
```

如果 B 的 agent 有平台机器权限：

```bash
cd /opt/edge/nginx-gateway
cp /path/to/b/deploy/edge.env projects/b.env
./scripts/register-project.sh b --dry-run
./scripts/register-project.sh b
```

B 不需要、也不应该直接改 `sites/`。

## 平台验收

```bash
docker exec nginx-gateway nginx -t
curl -kI https://b.example.com/
docker exec nginx-gateway grep -R "server_name b.example.com" /etc/nginx/sites
```

期望：

- `sites/20-b.conf` 存在。
- `nginx -t` 通过。
- 域名返回 200/301/302，不是 502。
- A 项目的站点和证书不受影响。

## 常见返工

| 现象 | 检查 |
|---|---|
| 502 | B 的 `b-web` 没起、端口错、服务名不是 `b-web` |
| 两个项目串站 | B 的入口服务还叫 `web`，和 A 抢 `edge` DNS |
| 413 | `BODY_SIZE` 太小 |
| 证书失败 | DNS 未生效、80 不通、Cloudflare 代理 |
| 改了配置没生效 | 没执行 `register-project.sh b` 或 reload |
