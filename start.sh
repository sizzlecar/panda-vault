#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

STORAGE_ROOT="${STORAGE_ROOT:-}"
MODE="up"
SHOW_LOGS="0"
NO_BUILDKIT="0"
PREPULL="1"

usage() {
  cat <<'EOF'
用法：
  ./start.sh [--storage-root /path] [--logs] [--down] [--no-buildkit] [--no-prepull]

说明：
  - 默认 storage root：自动选择（优先 /mnt/media_storage；否则使用项目目录 ./media_storage）
  - --down：停止并移除容器（保留数据卷）
  - --logs：启动后自动 tail 日志
  - --no-buildkit：禁用 BuildKit（用于排查代理/网络导致的构建拉取失败）
  - --no-prepull：跳过预拉镜像（默认会先 docker pull 基础镜像/DB，走更稳定的 pull 链路）

示例：
  ./start.sh
  ./start.sh --storage-root /mnt/media_storage --logs
  ./start.sh --down
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --storage-root)
      STORAGE_ROOT="$2"
      shift 2
      ;;
    --down)
      MODE="down"
      shift
      ;;
    --logs)
      SHOW_LOGS="1"
      shift
      ;;
    --no-buildkit)
      NO_BUILDKIT="1"
      shift
      ;;
    --no-prepull)
      PREPULL="0"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "未知参数: $1"
      usage
      exit 2
      ;;
  esac
done

cd "$ROOT_DIR"

if command -v docker >/dev/null 2>&1; then
  :
else
  echo "未找到 docker，请先安装 Docker Desktop / docker engine"
  exit 1
fi

if docker compose version >/dev/null 2>&1; then
  DC="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
  DC="docker-compose"
else
  echo "未找到 docker compose（docker compose 或 docker-compose）"
  exit 1
fi

if [[ "$MODE" == "down" ]]; then
  echo "停止服务..."
  HOST_STORAGE_ROOT="${STORAGE_ROOT:-}" $DC down
  echo "完成"
  exit 0
fi

choose_default_storage_root() {
  # 用户显式设置则直接使用
  if [[ -n "${STORAGE_ROOT:-}" ]]; then
    echo "$STORAGE_ROOT"
    return 0
  fi

  # 兼容文档默认：Linux 常见 /mnt/media_storage
  local linux_default="/mnt/media_storage"
  if mkdir -p "$linux_default" >/dev/null 2>&1; then
    echo "$linux_default"
    return 0
  fi

  # macOS / Windows：用项目目录，跨平台最稳
  echo "$ROOT_DIR/media_storage"
}

STORAGE_ROOT="$(choose_default_storage_root)"

echo "准备存储目录: $STORAGE_ROOT"
if ! mkdir -p "$STORAGE_ROOT/raw" "$STORAGE_ROOT/proxies" "$STORAGE_ROOT/.temp"; then
  echo "创建目录失败：$STORAGE_ROOT"
  echo "你可以指定一个可写路径，例如："
  echo "  bash start.sh --storage-root \"$ROOT_DIR/media_storage\""
  exit 1
fi

echo "将宿主机目录挂载到容器 /data：$STORAGE_ROOT -> /data"

APP_UID="${APP_UID:-$(id -u)}"
APP_GID="${APP_GID:-$(id -g)}"
echo "容器写盘用户：APP_UID=$APP_UID APP_GID=$APP_GID（可通过环境变量覆盖）"

if [[ "$PREPULL" == "1" ]]; then
  echo "预拉镜像（可减少 build 过程中因网络抖动导致的失败）..."
  docker pull postgres:15-alpine || true
  docker pull rust:1.85-bookworm || true
fi

echo "启动服务（build + up -d）..."
if [[ "$NO_BUILDKIT" == "1" ]]; then
  echo "已禁用 BuildKit（用于排查构建拉取问题）"
  DOCKER_BUILDKIT=0 COMPOSE_DOCKER_CLI_BUILD=0 HOST_STORAGE_ROOT="$STORAGE_ROOT" APP_UID="$APP_UID" APP_GID="$APP_GID" $DC up -d --build
else
  HOST_STORAGE_ROOT="$STORAGE_ROOT" APP_UID="$APP_UID" APP_GID="$APP_GID" $DC up -d --build
fi

HOST_IP="$(ipconfig getifaddr en0 2>/dev/null || true)"
if [[ -z "$HOST_IP" ]]; then
  HOST_IP="127.0.0.1"
fi

echo ""
echo "已启动："
echo "  上传页:      http://$HOST_IP:8080/"
echo "  健康检查:    http://$HOST_IP:8080/api/health"
echo "  AI 服务:     http://$HOST_IP:8000/health"
echo "  语义搜索:    POST http://$HOST_IP:8080/api/search/semantic"
echo ""

if [[ "$SHOW_LOGS" == "1" ]]; then
  echo "tail 日志（Ctrl+C 退出）..."
  $DC logs -f --tail=200 app db ai
fi


