#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 云服务器一次性初始化（Debian / Ubuntu）
#   - 安装 Docker Engine + compose 插件（官方便捷脚本）
#   - 安装 git（如缺失）
# 用法：在全新服务器上执行
#   sudo bash scripts/bootstrap-server.sh
# ---------------------------------------------------------------------------
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "请用 sudo 运行：sudo bash $0" >&2
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

if ! command -v git >/dev/null 2>&1; then
  echo "== 安装 git =="
  apt-get update -qq && apt-get install -y -qq git
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "== 安装 Docker Engine（官方 apt 源；get.docker.com 在国内常被重置） =="
  apt-get update -qq && apt-get install -y -qq ca-certificates curl gnupg
  install -m 0755 -d /etc/apt/keyrings
  # apt 源链式选择：腾讯云镜像 → 阿里云镜像 → 官方（国内直连间歇性 RST，不赌单点）
  DOCKER_APT_BASE=""
  for base in \
    "https://mirrors.cloud.tencent.com/docker-ce/linux/ubuntu" \
    "https://mirrors.aliyun.com/docker-ce/linux/ubuntu" \
    "https://download.docker.com/linux/ubuntu"; do
    echo "   试 $base ..."
    if curl -fsSL --connect-timeout 8 --retry 2 "$base/gpg" -o /tmp/docker-gpg.$$ 2>/dev/null; then
      DOCKER_APT_BASE="$base"
      break
    fi
  done
  [[ -n "$DOCKER_APT_BASE" ]] || { echo "ERROR: 三个 Docker apt 源都不可达" >&2; exit 1; }
  echo "   使用 apt 源：$DOCKER_APT_BASE"
  if [[ ! -f /etc/apt/keyrings/docker.gpg ]]; then
    gpg --dearmor -o /etc/apt/keyrings/docker.gpg /tmp/docker-gpg.$$
    chmod a+r /etc/apt/keyrings/docker.gpg
  fi
  rm -f /tmp/docker-gpg.$$
  ARCH="$(dpkg --print-architecture)"
  CODENAME="$(. /etc/os-release && echo "$VERSION_CODENAME")"
  echo "deb [arch=$ARCH signed-by=/etc/apt/keyrings/docker.gpg] $DOCKER_APT_BASE $CODENAME stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -qq
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
else
  echo "== Docker 已安装，跳过 =="
fi

# Docker Hub 加速（腾讯云内网镜像优先，daocloud 兜底）；已有 daemon.json 则不动
if [[ ! -f /etc/docker/daemon.json ]]; then
  echo "== 配置 Docker 镜像加速 =="
  mkdir -p /etc/docker
  cat > /etc/docker/daemon.json <<'EOF'
{
  "registry-mirrors": [
    "https://mirror.ccs.tencentyun.com",
    "https://docker.m.daocloud.io"
  ]
}
EOF
  systemctl restart docker
fi

# 让调用者（sudo 用户）免 sudo 用 docker（重新登录后生效；当前会话可用 sudo docker）
if [[ -n "${SUDO_USER:-}" ]] && id "$SUDO_USER" >/dev/null 2>&1; then
  usermod -aG docker "$SUDO_USER"
  echo "（已把 $SUDO_USER 加入 docker 组）"
fi

if ! docker compose version >/dev/null 2>&1; then
  echo "== 安装 docker compose 插件 =="
  apt-get update -qq && apt-get install -y -qq docker-compose-plugin
fi

echo
docker --version
docker compose version
echo
echo "服务器初始化完成。接下来：git clone 本仓库 → 填 .env → docker compose up -d"
