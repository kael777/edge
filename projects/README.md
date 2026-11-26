# projects 注册目录

每个项目一个 `<name>.env`，由 `scripts/register-project.sh` 读取。项目部署时只做三件事：

1. 项目入口服务加入 `edge` 网络，使用唯一 alias，例如 `a-web`。
2. 写 `projects/a.env`。
3. 执行 `./scripts/register-project.sh a`。

之后 A、B 共用同一个前置 nginx，不需要改端口，也不需要重启网关。

## 字段

| 字段 | 必填 | 说明 |
|---|---|---|
| `PROJECT` | 是 | 必须和文件名一致，例如 `a.env` 里写 `PROJECT=a` |
| `DOMAIN` | 是 | 域名，例如 `a.example.com` |
| `MODE` | 是 | `proxy` 或 `static` |
| `UPSTREAM` | proxy 必填 | 容器服务名:端口，例如 `a-web:8080`；必须是 `edge` 网络里的唯一 alias |
| `ROOT` | static 必填 | 容器内静态根，例如 `/srv/a`；宿主机需只读挂载到该路径 |
| `BODY_SIZE` | 否 | `client_max_body_size`，默认 `1m` |
| `WEBSOCKET` | 否 | `1` 时额外生成 `/ws/` 反代 |
| `ADMIN_ALLOWLIST` | 否 | 管理面板的 IP/CIDR 白名单，逗号分隔；仅 proxy 模式 |
| `ADMIN_PATH` | 否 | 管理面板前缀，默认 `/admin-panel/`，以 `/` 开头和结尾 |
| `SPA` | 否 | 静态站点回退到 `/index.html` |
| `PRIORITY` | 否 | 两位优先级；不填则自动分配，覆盖同名项目时保留原值 |
| `EMAIL` | 视证书 | Let's Encrypt 邮箱；`CERT_MODE=letsencrypt/auto` 时使用 |
| `CERT_MODE` | 否 | `auto`（默认）、`letsencrypt`、`self-signed`、`none` |
| `STAGING` | 否 | `1` 时使用 Let's Encrypt staging |

## 示例：A 项目

`projects/a.env`：

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

```bash
cd /opt/edge/nginx-gateway
./scripts/register-project.sh a
```

## 示例：B 项目后加入

`projects/b.env`：

```env
PROJECT=b
DOMAIN=b.example.com
MODE=proxy
UPSTREAM=b-web:8080
EMAIL=ops@example.com
CERT_MODE=auto
```

```bash
./scripts/register-project.sh b
```

只会新增 `sites/20-b.conf` 并 reload，A 不受影响。

## 静态站点

```env
PROJECT=docs
DOMAIN=docs.example.com
MODE=static
ROOT=/srv/docs
SPA=1
CERT_MODE=self-signed
```

同时在 `docker-compose.gateway.yml` 加只读挂载：

```yaml
- ./static/docs:/srv/docs:ro
```

然后：

```bash
./scripts/register-project.sh docs
```

## 命令行为

- 重复执行 `register-project.sh a` 会覆盖 `sites/10-a.conf`，但保留原优先级和数据；这是幂等更新。
- 已有证书会复用；`CERT_MODE=none` 只生成 HTTP + ACME。
- `CERT_MODE=letsencrypt` 必须有 `EMAIL`；`auto` 没有 `EMAIL` 时只上 HTTP 并提示。
- `--no-reload` 只写文件，不执行 `nginx -t`/reload。
- `--dry-run` 只打印计划，不写文件。
- `--no-save` 不更新 `projects/<name>.env`，只用命令行参数。
- `--all` 依次注册 `projects/*.env`。
