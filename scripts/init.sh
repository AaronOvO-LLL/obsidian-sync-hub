#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# CouchDB 初始化脚本（为 Obsidian "Self-hosted LiveSync" 插件准备服务端）
#
# 这是上游官方 provision.ts 的纯 curl 移植，配置项与官方逐条一致
# （来源：https://github.com/vrtmrz/obsidian-livesync utils/couchdb/provision.ts），
# 目的：服务器无需安装 Deno，一条命令完成初始化。
#
# 用法（在服务器上、仓库根目录执行）：
#   ./scripts/init.sh [CouchDB地址] [数据库名]
#   默认地址 http://127.0.0.1:5984，默认数据库 obsidian
#
# 脚本幂等，可重复执行。
# ---------------------------------------------------------------------------
set -euo pipefail

# 自动加载仓库根目录的 .env（COUCHDB_USER / COUCHDB_PASSWORD）
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SCRIPT_DIR/../.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/../.env"
  set +a
fi

HOST="${1:-http://127.0.0.1:5984}"
DB_NAME="${2:-obsidian}"
: "${COUCHDB_USER:?请在 .env 中设置 COUCHDB_USER}"
: "${COUCHDB_PASSWORD:?请在 .env 中设置 COUCHDB_PASSWORD}"

# Obsidian 桌面端 / iOS / Android 三个客户端来源（官方默认值）
ORIGINS="${ORIGINS:-app://obsidian.md,capacitor://localhost,http://localhost}"
RETRY_COUNT="${RETRY_COUNT:-12}"
RETRY_DELAY="${RETRY_DELAY:-5}"

if [[ ! "$DB_NAME" =~ ^[a-z][a-z0-9_\$\(\)+-]*$ ]]; then
  echo "ERROR: 数据库名须以小写字母开头，只能含小写字母/数字/_\$()+- ：$DB_NAME" >&2
  exit 1
fi

auth=(-u "$COUCHDB_USER:$COUCHDB_PASSWORD")

req() {
  # req <label> <method> <path> <json-body> [ok-statuses...]
  local label="$1" method="$2" path="$3" body="$4"; shift 4
  local want="$*" out code attempt
  for ((attempt = 1; attempt <= RETRY_COUNT; attempt++)); do
    out=$(curl -sS -w '\n%{http_code}' -X "$method" "${auth[@]}" \
      -H 'Content-Type: application/json' \
      -d "$body" "$HOST$path" 2>&1) || true
    code="${out##*$'\n'}"
    for s in $want; do
      if [[ "$code" == "$s" ]]; then
        # 400/409 仅在报文表明“已配置过”时才算成功（与上游 provision 一致）
        if [[ "$code" == "400" || "$code" == "409" ]] && \
           ! grep -qiE 'already|finished' <<<"$out"; then
          break
        fi
        echo "  OK   $label (HTTP $code)"
        return 0
      fi
    done
    # 4xx 视为配置错误，不再重试
    if [[ "$code" =~ ^4[0-9][0-9]$ ]]; then
      echo "  FAIL $label (HTTP $code): ${out%$'\n'*}" >&2
      return 1
    fi
    sleep "$RETRY_DELAY"
  done
  echo "  FAIL $label: 重试 $RETRY_COUNT 次仍失败 (最后 HTTP $code)" >&2
  return 1
}

cfg() {
  # cfg <label> <config-key> <json-value>
  req "$1" PUT "/_node/_local/_config/$2" "$3" 200
}

echo "== 1/3 单节点集群初始化 =="
req "enable_single_node" POST /_cluster_setup \
  '{"action":"enable_single_node","username":"'"$COUCHDB_USER"'","password":"'"$COUCHDB_PASSWORD"'","bind_address":"0.0.0.0","port":5984,"singlenode":true}' \
  200 201 202 400 409

echo "== 2/3 写入 LiveSync 所需配置（与官方 provision 一致） =="
cfg "require authenticated HTTP users"        chttpd/require_valid_user       '"true"'
cfg "require auth for authentication"         chttpd_auth/require_valid_user  '"true"'
cfg "HTTP authentication challenge"           httpd/WWW-Authenticate          '"Basic realm=\"couchdb\""'
cfg "enable HTTP CORS"                        httpd/enable_cors               '"true"'
cfg "enable clustered HTTP CORS"              chttpd/enable_cors              '"true"'
cfg "max HTTP request size (4GB, 大附件)"      chttpd/max_http_request_size    '"4294967296"'
cfg "max document size (50MB)"                couchdb/max_document_size       '"50000000"'
cfg "CORS credentials"                        cors/credentials                '"true"'
cfg "allowed CORS origins"                    cors/origins                    "$(printf '"%s"' "$ORIGINS")"

echo "== 3/3 创建数据库 [$DB_NAME] =="
req "create database" PUT "/$DB_NAME" '{}' 201 412

echo
echo "完成！CouchDB 已就绪：$HOST"
echo "下一步：在 Obsidian 安装 'Self-hosted LiveSync' 插件，向导中填 https://你的域名 与上面的账号密码。"
