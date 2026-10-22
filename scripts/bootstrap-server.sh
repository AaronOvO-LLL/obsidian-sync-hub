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
  echo "== 安装 Docker Engine（官方便捷脚本） =="
  echo "   如在国内服务器下载缓慢，可改用镜像源安装，见 README '国内网络提示'"
  apt-get update -qq && apt-get install -y -qq curl ca-certificates
  curl -fsSL https://get.docker.com | sh
  systemctl enable --now docker
else
  echo "== Docker 已安装，跳过 =="
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
