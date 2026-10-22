# obsidian-sync-hub

自建 Obsidian 同步中枢（替代官方 Sync）的服务端配置仓库。
客户端插件用开源的 **[Self-hosted LiveSync](https://github.com/vrtmrz/obsidian-livesync)**，服务端 = CouchDB + Caddy(HTTPS)，实时同步、版本历史、端到端加密，全部数据在自己服务器上。

```
┌────────────┐   ┌────────────┐   ┌────────────┐
│ Windows    │   │ 手机(iOS/  │   │ 其他设备…  │   ← Obsidian + LiveSync 插件
└─────┬──────┘   └─────┬──────┘   └─────┬──────┘
      └────────────┬───┴────────────┬───┘
                   ▼  HTTPS (443)   ▼
            ┌──────────────────────────┐
            │  Caddy（自动 TLS 证书）  │  ← 你的云服务器
            │    └→ CouchDB :5984      │
            │         数据卷（加密前的 │
            │         密文存在这里）   │
            └──────────────────────────┘
```

- **同步方式**：各设备 ↔ 服务器中枢，实时（也可设为定时/开关文件时）
- **加密**：插件端 E2EE（AES，密码只在设备上），服务器只见密文
- **版本历史**：插件内置，可恢复历史版本、找回删除的文件

---

## 一、服务器一次性部署

> 前置：域名 A 记录已解析到服务器 IP；安全组/防火墙放行 **80、443**（TCP）和 **443**（UDP，HTTP/3 可选）。

### 1. 安装 Docker

```bash
sudo bash scripts/bootstrap-server.sh
```

（Debian/Ubuntu。脚本装 Docker Engine + compose 插件 + git。）

### 2. 获取本仓库

```bash
cd /opt
sudo git clone <本仓库地址> obsidian-sync-hub
cd obsidian-sync-hub
```

### 3. 配置环境变量

```bash
cp .env.example .env
nano .env      # 填 SYNC_DOMAIN / ACME_EMAIL / COUCHDB_USER / COUCHDB_PASSWORD
```

### 4. 启动服务

```bash
docker compose up -d
docker compose ps        # 两个容器都应为 running/healthy
```

首次收到请求时 Caddy 自动向 Let's Encrypt 申请证书，稍等几秒。

### 5. 初始化 CouchDB

```bash
./scripts/init.sh
```

脚本幂等（可反复执行）。它按 LiveSync 官方 provision 逻辑完成：单节点集群、强制认证、CORS（Obsidian 三端来源）、请求体 4GB / 单文档 50MB（放行大附件）、创建数据库。输出全 `OK` 即成功。

验证：

```bash
curl http://127.0.0.1:5984            # 应要求 Basic 认证（401）
curl https://你的域名/                 # 同上（走 HTTPS）
```

### 6. 定时备份（必做！）

自建中枢的数据只在这一台机器上，务必：

```bash
crontab -e
# 每天 4:00 冷备份，本地留 14 份；装了 rclone 再配 RCLONE_REMOTE 异地保存
0 4 * * * cd /opt/obsidian-sync-hub && ./scripts/backup.sh >> /var/log/obsidian-sync-backup.log 2>&1
```

---

## 二、Obsidian 端接入

### 第一台设备

1. 设置 → 第三方插件 → 社区插件市场 → 安装 **Self-hosted LiveSync** 并启用
2. 运行 Setup Wizard：服务端类型选 **CouchDB**
   - URI：`https://你的域名`
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
| 改了本仓库配置 | 服务器 `git pull && docker compose up -d` |
| 看日志 | `docker compose logs -f couchdb` / `logs -f caddy` |
| 管理界面 | 服务器本机开 `http://127.0.0.1:5984/_utils`（Fauxton，需管理员账号） |
| 升级 CouchDB | `docker compose pull && docker compose up -d`（先跑一次备份） |
| 恢复数据 | `docker compose stop couchdb` → 解压 tar 到数据卷 → `start`（见 backup.sh 头部注释） |

### 国内网络提示

- 拉镜像慢/失败：配置 Docker 镜像加速器（`/etc/docker/daemon.json` 的 `registry-mirrors`），或换 `couchdb:3.5` 的可用镜像源
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
| 插件 Check 报 CORS | 重跑 `./scripts/init.sh`；确认移动端 Obsidian 版本较新 |
| iOS/Android 连不上 | 必须 HTTPS + 有效证书（本方案 Caddy 自动满足）；确认域名解析、安全组 443 |
| 大附件同步失败 | 确认 init.sh 已执行（4GB 请求体 / 50MB 单文档上限） |
| 证书申请失败 | 域名未解析到本机 / 80 端口被占或未放行 |
| 两台设备同时改同一文件 | LiveSync 会自动合并；冲突严重时看插件 "Conflicts" 面板手动取舍 |

---

## 文件说明

| 路径 | 作用 |
|---|---|
| `docker-compose.yml` | CouchDB + Caddy 两容器编排（项目名固定 `obsidian-sync`） |
| `Caddyfile` | HTTPS 反代；证书自动申请/续期 |
| `scripts/bootstrap-server.sh` | 新服务器装 Docker + git（一次性） |
| `scripts/init.sh` | CouchDB 初始化（官方 provision.ts 的 curl 移植，幂等） |
| `scripts/backup.sh` | 冷备份 + 保留策略 + 可选 rclone 异地 |
| `.env.example` | 环境变量模板（复制为 `.env` 使用） |
