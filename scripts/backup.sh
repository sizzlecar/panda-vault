#!/bin/bash
# ============================================================
# HomeMediaCloud 冷备份脚本
# 
# 功能：将 raw 目录增量同步到备份硬盘
# 使用：./backup.sh [备份目标路径]
# 
# 建议：
#   1. 配合 cron 定时执行：0 3 * * * /path/to/backup.sh /mnt/backup_disk
#   2. 备份硬盘建议使用 ext4 格式
# ============================================================

set -e

# 默认配置
SOURCE_DIR="${SOURCE_DIR:-/mnt/media_storage/raw}"
BACKUP_DIR="${1:-/mnt/backup_disk/media_backup}"
LOG_DIR="${LOG_DIR:-/var/log/homemedia}"
LOG_FILE="$LOG_DIR/backup_$(date +%Y%m%d_%H%M%S).log"

# 颜色
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log() {
    echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1" | tee -a "$LOG_FILE"
}

warn() {
    echo -e "${YELLOW}[$(date '+%Y-%m-%d %H:%M:%S')] WARN:${NC} $1" | tee -a "$LOG_FILE"
}

error() {
    echo -e "${RED}[$(date '+%Y-%m-%d %H:%M:%S')] ERROR:${NC} $1" | tee -a "$LOG_FILE"
    exit 1
}

# 检查参数
if [ -z "$1" ]; then
    echo "用法: $0 <备份目标路径>"
    echo ""
    echo "示例:"
    echo "  $0 /mnt/backup_disk/media_backup"
    echo "  SOURCE_DIR=/data/raw $0 /mnt/backup_disk"
    echo ""
    echo "环境变量:"
    echo "  SOURCE_DIR  - 源目录 (默认: /mnt/media_storage/raw)"
    echo "  LOG_DIR     - 日志目录 (默认: /var/log/homemedia)"
    exit 1
fi

# 创建日志目录
mkdir -p "$LOG_DIR" 2>/dev/null || true

log "========== 开始备份 =========="
log "源目录: $SOURCE_DIR"
log "目标目录: $BACKUP_DIR"

# 检查源目录
if [ ! -d "$SOURCE_DIR" ]; then
    error "源目录不存在: $SOURCE_DIR"
fi

# 检查/创建目标目录
if [ ! -d "$BACKUP_DIR" ]; then
    log "创建备份目录: $BACKUP_DIR"
    mkdir -p "$BACKUP_DIR" || error "无法创建备份目录"
fi

# 检查目标磁盘空间
SOURCE_SIZE=$(du -sb "$SOURCE_DIR" 2>/dev/null | cut -f1)
BACKUP_AVAIL=$(df -B1 "$BACKUP_DIR" 2>/dev/null | tail -1 | awk '{print $4}')

if [ -n "$SOURCE_SIZE" ] && [ -n "$BACKUP_AVAIL" ]; then
    log "源目录大小: $(numfmt --to=iec-i --suffix=B $SOURCE_SIZE 2>/dev/null || echo $SOURCE_SIZE)"
    log "目标可用空间: $(numfmt --to=iec-i --suffix=B $BACKUP_AVAIL 2>/dev/null || echo $BACKUP_AVAIL)"
fi

# 执行 rsync 增量同步
log "开始 rsync 同步..."
rsync -av --progress --delete \
    --exclude='.DS_Store' \
    --exclude='Thumbs.db' \
    --exclude='.temp' \
    --exclude='*.tmp' \
    "$SOURCE_DIR/" "$BACKUP_DIR/" 2>&1 | tee -a "$LOG_FILE"

RSYNC_EXIT=${PIPESTATUS[0]}

if [ $RSYNC_EXIT -eq 0 ]; then
    log "========== 备份完成 =========="
    
    # 统计
    BACKUP_SIZE=$(du -sh "$BACKUP_DIR" 2>/dev/null | cut -f1)
    FILE_COUNT=$(find "$BACKUP_DIR" -type f 2>/dev/null | wc -l)
    log "备份总大小: $BACKUP_SIZE"
    log "文件总数: $FILE_COUNT"
    
    # 记录最后备份时间
    date > "$BACKUP_DIR/.last_backup"
    
elif [ $RSYNC_EXIT -eq 24 ]; then
    warn "备份完成，但有部分文件在同步过程中被修改"
else
    error "rsync 失败，退出码: $RSYNC_EXIT"
fi

# 清理旧日志（保留最近 30 个）
if [ -d "$LOG_DIR" ]; then
    ls -t "$LOG_DIR"/backup_*.log 2>/dev/null | tail -n +31 | xargs rm -f 2>/dev/null || true
fi

log "日志已保存: $LOG_FILE"

