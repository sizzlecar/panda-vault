#!/bin/bash
# PandaVault 后端启动脚本

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STORAGE="${STORAGE_ROOT:-$SCRIPT_DIR/../media_storage}"

export STORAGE_ROOT="$STORAGE"
export RAW_DIR="$STORAGE/raw"
export PROXIES_DIR="$STORAGE/proxies"
export TEMP_DIR="$STORAGE/.temp"
export ALBUMS_DIR="$STORAGE/raw/albums"
export INBOX_DIR="$STORAGE/raw/inbox"
export TRASH_DIR="$STORAGE/raw/.trash"

export DATABASE_URL="${DATABASE_URL:-postgres://user@localhost:5432/mediadb}"
export FFMPEG_BIN="${FFMPEG_BIN:-ffmpeg}"
export FFPROBE_BIN="${FFPROBE_BIN:-ffprobe}"
export BIND_ADDR="${BIND_ADDR:-0.0.0.0:8080}"
export AI_SERVICE_URL="${AI_SERVICE_URL:-http://127.0.0.1:8000}"
export RUST_LOG="${RUST_LOG:-info,panda_vault_backend=debug}"

cd "$SCRIPT_DIR"
exec cargo run --release
