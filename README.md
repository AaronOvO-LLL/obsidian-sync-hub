# obsidian-sync-hub

自建 Obsidian 同步中枢（替代官方 Sync）的服务端配置仓库。
客户端插件用开源的 **[Self-hosted LiveSync](https://github.com/vrtmrz/obsidian-livesync)**，服务端 = CouchDB，实时同步、版本历史、端到端加密，全部数据在自己服务器上。

**部署形态**：CouchDB 跑在 Docker 里、只监听 `127.0.0.1:5984`；HTTPS 由宿主机**现有的 Caddy 边缘**（hao-rizon 站点那一个）以站点块 `sync.hao-rizon.com` 反代。一台机器只允许一个进程占 80/443，本仓库**不带**自己的 web 服务器。

```
┌────────────┐   ┌────────────┐   ┌────────────┐
│ Windows    │   │ 手机(iOS/  │   │ 其他设备…  │   ← Obsidian + LiveSync 插件
└─────┬──────┘   └─────┬──────┘   └─────┬──────┘
      └────────────┬───┴────────────┬───┘
                   ▼  HTTPS (443)   ▼
        ┌────────────────────────────────────┐
        │ Caddy 边缘（hao-rizon 同一个进程） │  ← 你的云服务器
        │   www.hao-rizon.com → 静态站       │
        │   sync.hao-rizon.com → 127.0.0.1:5984
        │        └→ CouchDB (Docker)         │
        │             数据卷存 E2EE 密文     │
        └────────────────────────────────────┘
```

- **同步方式**：各设备 ↔ 服务器中枢，实时（也可设为定时/开关文件时）
- **加密**：插件端 E2EE（AES，密码只在设备上），服务器只见密文
- **版本历史**：插件内置，可恢复历史版本、找回删除的文件

---

## 一、服务器一次性部署

> 前置：DNS 加一条 A 记录 `sync.hao-rizon.com → 129.204.31.88`（在你的域名解析控制台）；
> 80/443 已被 hao-rizon 站点放行，无需再动安全组。

### 1. 获取本仓库（放 `/srv/obsidian-sync-hub`，与 `/srv/haorizon` 同级同约定）

```bash
sudo mkdir -p /srv/obsidian-sync-hub
sudo chown ubuntu:ubuntu /srv/obsidian-sync-hub
git clone https://github.com/AaronOvO-LLL/obsidian-sync-hub.git /srv/obsidian-sync-hub
cd /srv/obsidian-sync-hub
```

### 2. 安装 Docker（脚本含腾讯云镜像加速，幂等）

```bash
sudo bash scripts/bootstrap-server.sh
```

### 3. 配置环境变量

```bash
cp .env.example .env
nano .env      # 填 COUCHDB_USER / COUCHDB_PASSWORD（强密码）
```

### 4. 启动 CouchDB

```bash
docker compose up -d
docker compose ps        # obsidian-couchdb 应为 running
```

### 5. 初始化 CouchDB

```bash
./scripts/init.sh
```

脚本幂等（可反复执行）。它按 LiveSync 官方 provision 逻辑完成：单节点集群、强制认证、CORS（Obsidian 三端来源）、请求体 4GB / 单文档 50MB（放行大附件）、创建数据库。输出全 `OK` 即成功。

### 6. 边缘接入（站点块，走 hao-rizon-dashboard 的 git 流程）

站点块在 **hao-rizon-dashboard** 仓库的 `deploy/Caddyfile` 里（已加）：

```caddyfile
sync.hao-rizon.com {
	reverse_proxy 127.0.0.1:5984
}
```

⚠ **不要在服务器上手改 `/etc/caddy/Caddyfile`**——haorizon 的发布是 `git reset --hard`，手改会被下次发布无声抹掉。正确流程永远是：改 hao-rizon-dashboard 仓库 → `./scripts/deploy.sh`（自动 `caddy validate` + reload）。

### 7. 验证

```bash
curl http://127.0.0.1:5984                  # 应 401（要认证）——本机回环
curl https://sync.hao-rizon.com/            # 应 401 —— 公网 HTTPS 全链路
```

公网那条返回 401 就说明：DNS ✓ 证书 ✓ Caddy 反代 ✓ CouchDB 认证 ✓。

### 8. 定时备份（必做！）

自建中枢的数据只在这一台机器上，务必：

```bash
crontab -e
# 每天 4:00 冷备份，本地留 14 份；装了 rclone 再配 RCLONE_REMOTE 异地保存
0 4 * * * cd /srv/obsidian-sync-hub && ./scripts/backup.sh >> /var/log/obsidian-sync-backup.log 2>&1
```

---

## 二、Obsidian 端接入

### 第一台设备

1. 设置 → 第三方插件 → 社区插件市场 → 安装 **Self-hosted LiveSync** 并启用
2. 运行 Setup Wizard：服务端类型选 **CouchDB**
   - URI：`https://sync.hao-rizon.com`
   - Username / Password：`.env` 里的 CouchDB 账号
   - Database：`obsidian`（或你指定的库名）
3. 加密：设置 **E2EE passphrase**（端到端加密密码）
   > ⚠️ 这个密码只在你的设备上，**丢了谁也找不回来**。请存进密码管理器。
4. 同步模式建议选 **LiveSync**（实时）；保存设置后点 "Check database configuration"，全绿即通

### 后续设备

第一台设备的 LiveSync 设置里 **Copy setup URI**（含地址/账号/密码/加密口令），新设备插件里选 "Connect with setup URI" 粘贴即可。手机端同理。

> 插件向导里的 "Detect and fix CouchDB issues" 可自动补齐缺的配置，服务器侧问题优先来这里修。

---

## 三、日常运维

| 场景 | 操作 |
|---|---|
| 改了本仓库配置 | 服务器 `/srv/obsidian-sync-hub` 里 `git pull && docker compose up -d` |
| 改了边缘/站点块 | hao-rizon-dashboard 仓库 → `./scripts/deploy.sh` |
| 看日志 | `docker compose logs -f couchdb`；Caddy 日志看 `journalctl -u caddy` |
| 管理界面 | 服务器本机开 `http://127.0.0.1:5984/_utils`（Fauxton，需管理员账号） |
| 升级 CouchDB | `docker compose pull && docker compose up -d`（先跑一次备份） |
| 恢复数据 | `docker compose stop couchdb` → 解压 tar 到数据卷 → `start`（见 backup.sh 头部注释） |

### 国内网络提示

- 拉镜像慢/失败：`bootstrap-server.sh` 已配腾讯云内网镜像 + daocloud 兜底；仍失败就再加 `registry-mirrors`
- 服务器上 `git clone` GitHub 超时：可先推到 Gitee 私有库再 clone，或本地 `git push` 后服务器走代理

---

## 四、安全须知

1. **E2EE passphrase ≠ CouchDB 密码**。前者是端到端加密密钥（丢了数据不可恢复），后者只是登录服务器的口令（可随时改）。
2. `.env` 含管理员密码，已被 `.gitignore` 忽略——**永远不要提交**。换服务器时手动带过去。
3. CouchDB 只绑 `127.0.0.1:5984`，对外只暴露 Caddy 的 HTTPS；`require_valid_user=true` 保证任何请求都要认证。
4. 服务器被攻破时：攻击者拿到的是 E2EE 密文（拿不到 passphrase 就读不了笔记），但**可以删除/毁掉数据**——所以备份是生命线。

## 五、故障排查

| 症状 | 处理 |
|---|---|
| `https://sync.hao-rizon.com` 打不开 | 先 `dig +short sync.hao-rizon.com`（应为 129.204.31.88）；再 `sudo caddy validate` + `journalctl -u caddy` |
| 插件 Check 报 CORS | 重跑 `./scripts/init.sh`；确认移动端 Obsidian 版本较新 |
| iOS/Android 连不上 | 必须 HTTPS + 有效证书；确认域名解析生效、Caddy 已为 sync 域名签发证书 |
| 大附件同步失败 | 确认 init.sh 已执行（4GB 请求体 / 50MB 单文档上限） |
| 证书申请失败 | `sync.hao-rizon.com` 未解析到本机 / 80 端口被占或未放行 |
| 两台设备同时改同一文件 | LiveSync 会自动合并；冲突严重时看插件 "Conflicts" 面板手动取舍 |
| 重启服务器后同步断了 | `docker compose ps` 确认容器自启；`systemctl status caddy` 确认边缘存活 |

---

## 文件说明

| 路径 | 作用 |
|---|---|
| `docker-compose.yml` | CouchDB 单容器编排（项目名固定 `obsidian-sync`） |
| `deploy/sync-site-block.caddy` | 加入 hao-rizon 边缘的站点块（说明；源文件在 hao-rizon-dashboard 仓库） |
| `scripts/bootstrap-server.sh` | 装 Docker + 镜像加速 + git（一次性，幂等） |
| `scripts/init.sh` | CouchDB 初始化（官方 provision.ts 的 curl 移植，幂等） |
| `scripts/backup.sh` | 冷备份 + 保留策略 + 可选 rclone 异地 |
| `.env.example` | 环境变量模板（复制为 `.env` 使用） |
