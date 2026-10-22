#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 冷备份：暂停 CouchDB → 打包数据卷 → 恢复服务 → （可选）推送到异地。
#
# 自建中枢的唯一数据副本在服务器上，务必定时跑本脚本并异地保存。
# 用法（服务器上、仓库根目录）：
#   ./scripts/backup.sh                  # 备份到 ./backups/
#   RCLONE_REMOTE=offsite:obsidian-backups ./scripts/backup.sh   # 同时 rclone 推送异地
#
# 建议 crontab（每天凌晨 4 点）：
#   0 4 * * * cd /opt/obsidian-sync-hub && RCLONE_REMOTE=offsite:obsidian-backups ./scripts/backup.sh >> /var/log/obsidian-sync-backup.log 2>&1
# ---------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

BACKUP_DIR="${BACKUP_DIR:-./backups}"
STAMP="$(date +%Y%m%d-%H%M%S)"
ARCHIVE="$BACKUP_DIR/couchdb-data-$STAMP.tar.gz"
KEEP="${KEEP:-14}"   # 本地保留最近 N 份

mkdir -p "$BACKUP_DIR"

echo "== 暂停 CouchDB（保证数据一致性） =="
docker compose stop couchdb

echo "== 打包数据卷 -> $ARCHIVE =="
# 卷名 = <compose项目名>_<卷键>；项目名在 docker-compose.yml 里固定为 obsidian-sync
DATA_VOLUME="obsidian-sync_couchdb-data"
if ! docker volume inspect "$DATA_VOLUME" >/dev/null 2>&1; then
  echo "ERROR: 找不到数据卷 $DATA_VOLUME（是否还没执行 docker compose up -d？）" >&2
  docker compose start couchdb
  exit 1
fi
docker run --rm \
  -v "$DATA_VOLUME":/data:ro \
  -v "$(pwd)/$BACKUP_DIR":/backup \
  alpine tar czf "/backup/$(basename "$ARCHIVE")" -C /data .

echo "== 恢复 CouchDB =="
docker compose start couchdb

if [[ -n "${RCLONE_REMOTE:-}" ]]; then
  if command -v rclone >/dev/null 2>&1; then
    echo "== rclone 推送异地：$RCLONE_REMOTE =="
    rclone copy "$ARCHIVE" "$RCLONE_REMOTE/"
  else
    echo "WARN: 未安装 rclone，跳过异地推送" >&2
  fi
fi

echo "== 清理旧备份（保留最近 $KEEP 份） =="
ls -1t "$BACKUP_DIR"/couchdb-data-*.tar.gz 2>/dev/null | tail -n +$((KEEP + 1)) | xargs -r rm -f

echo
echo "完成：$ARCHIVE"
du -h "$ARCHIVE"
