@echo off
chcp 65001 >nul
echo.
echo  ╔══════════════════════════════╗
echo  ║   PANDA VAULT 安装向导       ║
echo  ╚══════════════════════════════╝
echo.

:: ============ 1. PostgreSQL ============
echo [1/4] 检查 PostgreSQL...
where psql >nul 2>&1
if %errorlevel% neq 0 (
    echo   未找到 PostgreSQL，正在安装...
    winget install PostgreSQL.PostgreSQL.17 --accept-package-agreements --accept-source-agreements
    echo   请将 PostgreSQL bin 目录加入 PATH 后重新运行此脚本
    pause
    exit /b 1
) else (
    echo   PostgreSQL 已安装 ✓
)

:: ============ 2. pgvector ============
echo.
echo [2/4] 安装 pgvector 扩展...
echo   请从 https://github.com/pgvector/pgvector/releases 下载 Windows 版本
echo   将 vector.dll 放到 PostgreSQL 的 lib\ 目录
echo   将 vector.control 和 sql 文件放到 share\extension\ 目录
echo.
echo   然后运行:
echo     psql -U postgres -c "CREATE EXTENSION vector;"
echo.

:: ============ 3. ffmpeg ============
echo [3/4] 检查 ffmpeg...
where ffmpeg >nul 2>&1
if %errorlevel% neq 0 (
    echo   未找到 ffmpeg，正在安装...
    winget install Gyan.FFmpeg --accept-package-agreements --accept-source-agreements
    echo   安装完成后请重启终端
) else (
    echo   ffmpeg 已安装 ✓
)

:: ============ 4. 创建数据库 ============
echo.
echo [4/4] 创建数据库...
psql -U postgres -c "CREATE USER pandavault WITH PASSWORD 'pandavault' SUPERUSER;" 2>nul
psql -U postgres -c "CREATE DATABASE mediadb OWNER pandavault;" 2>nul
psql -U pandavault -d mediadb -c "CREATE EXTENSION IF NOT EXISTS vector;" 2>nul
echo   数据库创建完成 ✓

echo.
echo  ══════════════════════════════
echo   安装完成！运行 start.bat 启动服务
echo  ══════════════════════════════
pause
