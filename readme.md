# PandaVault

私有局域网媒体资产管理系统。给老婆用的视频素材网盘。

## 功能

- **iOS App** — 自动同步相册、浏览、搜索、视频播放
- **AI 语义搜索** — 输入"猫"、"海边"搜图片/视频（CLIP 向量检索）
- **多卷存储** — 支持多块硬盘，满了自动切换
- **目录扫描** — 已有文件直接导入，不移动文件
- **分片上传** — 50MB 大分片，支持断点续传
- **去重** — SHA256 哈希去重 + 视频尺寸/时长去重

## 架构

```
iOS App ←→ Rust API (Axum) ←→ PostgreSQL + pgvector
                ↕                     ↕
         文件系统 (raw/)        AI Service (CLIP)
```

| 组件 | 技术 | 说明 |
|------|------|------|
| 后端 | Rust + Axum + sqlx | API、上传、转码任务队列 |
| 数据库 | PostgreSQL + pgvector | 元数据 + 向量索引 |
| AI 服务 | Python + CLIP | 图文向量化、语义搜索 |
| iOS App | SwiftUI | 相册同步、浏览、播放 |
| 存储 | 本地文件系统 | 支持多卷、外接硬盘 |

## 快速启动

### 依赖

- Rust 1.80+
- PostgreSQL 15+ (带 pgvector 扩展)
- ffmpeg + ffprobe
- Python 3.10+ (AI 服务)

### 启动后端

```bash
cd backend

# 设置环境变量
export STORAGE_ROOT="/path/to/storage"
export DATABASE_URL="postgres://user@localhost:5432/mediadb"
export AI_SERVICE_URL="http://127.0.0.1:8000"
export FFMPEG_BIN="/opt/homebrew/bin/ffmpeg"
export FFPROBE_BIN="/opt/homebrew/bin/ffprobe"

cargo run --release
```

### 多卷存储

```bash
# 添加新硬盘
curl -X POST http://localhost:8080/api/volumes \
  -H "Content-Type: application/json" \
  -d '{"label": "外接硬盘", "base_path": "/mnt/disk2", "priority": 10}'

# 扫描已有文件
curl -X POST http://localhost:8080/api/scan \
  -H "Content-Type: application/json" \
  -d '{"volume_id": "xxx-xxx"}'

# 查看进度
curl http://localhost:8080/api/scan/{session_id}
```

### iOS App

Xcode 打开 `ios-app/PandaVault.xcodeproj`，build 到手机。App 通过 Bonjour 自动发现局域网内的后端服务。

## API

| 方法 | 路径 | 说明 |
|------|------|------|
| GET | /api/health | 健康检查 |
| POST | /api/upload | 上传文件 |
| POST | /api/upload/init | 分片上传初始化 |
| GET | /api/assets | 资产列表 |
| GET | /api/assets/:id | 资产详情 |
| GET | /api/timeline | 时间轴 |
| POST | /api/search/semantic | AI 语义搜索 |
| POST | /api/search/image | 以图搜图 |
| GET/POST | /api/folders | 文件夹管理 |
| GET/POST | /api/volumes | 存储卷管理 |
| POST | /api/scan | 触发目录扫描 |

## 目录结构

```
backend/
  src/
    main.rs          # 启动、mDNS 广播
    api.rs           # HTTP 路由和处理器
    media.rs         # 文件入库、去重、缩略图
    jobs.rs          # 后台转码 + embedding worker
    volume.rs        # 多卷存储管理
    scan.rs          # 目录扫描
    folder.rs        # 文件夹 CRUD
    chunked_upload.rs # 分片上传
    ai.rs            # AI 服务客户端
  migrations/        # SQL 迁移

ios-app/
  PandaVault/
    App/             # 入口、AppState
    Models/          # 数据模型
    Services/        # API、同步、上传
    Views/           # UI 页面
    ViewModels/      # 视图模型
```
