# PandaVault Windows 部署

## 快速开始

### 1. 安装依赖

运行 `install.bat`，会自动安装：
- PostgreSQL 17
- ffmpeg
- 创建数据库

pgvector 需要手动安装：从 https://github.com/pgvector/pgvector/releases 下载 Windows 版本。

### 2. 编译后端

在 Windows 上：
```powershell
# 安装 Rust
winget install Rustlang.Rustup

# 编译（离线模式，不需要连数据库）
cd backend
set SQLX_OFFLINE=true
cargo build --release
```

编译产物：`target\release\panda-vault-backend.exe`

把 `panda-vault-backend.exe` 复制到 `deploy\` 目录。

### 3. 启动 AI 服务 (ferrum)

```powershell
# ferrum 提供 CLIP embedding 服务
ferrum serve --model OFA-Sys/chinese-clip-vit-base-patch16 --port 8000
```

### 4. 启动后端

编辑 `start.bat` 中的路径配置，然后运行：
```
start.bat
```

### 5. 连接 iPhone

iPhone 和 Windows 在同一 WiFi 下，打开 PandaVault App 会自动发现服务器。

## 目录结构

```
D:\PandaVault\
├── storage\
│   ├── raw\           # 原始文件
│   │   ├── albums\    # 文件夹
│   │   ├── inbox\     # 未分类
│   │   └── .trash\    # 回收站
│   ├── proxies\       # 预览文件（720p + 缩略图）
│   └── .temp\         # 临时文件
├── panda-vault-backend.exe
├── start.bat
└── install.bat
```

## 端口

| 服务 | 端口 | 说明 |
|------|------|------|
| PandaVault API | 8080 | 主服务 |
| ferrum AI | 8000 | CLIP 推理 |
| PostgreSQL | 5432 | 数据库 |

## 防火墙

Windows 防火墙需要放行 8080 端口，iPhone 才能连接：
```powershell
netsh advfirewall firewall add rule name="PandaVault" dir=in action=allow protocol=TCP localport=8080
```
