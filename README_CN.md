# PandaVault

[English](README.md)

私有局域网媒体资产管理系统 — 自托管媒体网盘，带 iOS App、AI 语义搜索、多硬盘存储池。

## 功能

- **iOS App** — 自动同步相册、浏览、搜索、视频播放
- **AI 语义搜索** — 输入"猫"、"海边"直接搜图片/视频（CLIP 向量检索）
- **以图搜图** — 拍一张照片，找出相似的素材
- **多卷存储** — 支持多块硬盘组成存储池，盘满自动切换下一块
- **目录扫描** — 已有文件和文件夹结构直接导入 DB，不移动文件
- **分片上传** — 50MB 大分片，支持断点续传，4GB+ 大文件无压力
- **智能去重** — SHA256 哈希去重 + 视频尺寸/时长去重
- **增量同步** — 只扫描上次同步后新增的照片，秒级完成

## 架构

```
┌─────────┐     HTTP/mDNS     ┌──────────────┐     SQL      ┌─────────────────┐
│ iOS App │ ←───────────────→ │  Rust API    │ ←──────────→ │  PostgreSQL     │
│ SwiftUI │                   │  (Axum)      │              │  + pgvector     │
└─────────┘                   └──────┬───────┘              └─────────────────┘
                                     │
                              ┌──────┴───────┐
                              │              │
                    ┌─────────▼──┐    ┌──────▼──────┐
                    │ 文件系统    │    │ AI Service  │
                    │ (多卷存储)  │    │ (CLIP)      │
                    └────────────┘    └─────────────┘
```

| 组件 | 技术栈 | 说明 |
|------|--------|------|
| 后端 | Rust + Axum + sqlx | API、上传、转码任务队列、多卷管理 |
| 数据库 | PostgreSQL 15 + pgvector | 元数据存储 + 向量相似度检索 |
| AI 服务 | [ferrum-infer-rs](https://github.com/sizzlecar/ferrum-infer-rs.git) | CLIP 模型推理，文本/图片向量化 |
| iOS App | SwiftUI + AVKit | 相册自动同步、浏览、视频播放 |
| 存储 | 本地文件系统 | 多卷存储池，支持外接硬盘热扩容 |

## 快速启动

### 依赖

- Rust 1.80+
- PostgreSQL 15+（需安装 [pgvector](https://github.com/pgvector/pgvector) 扩展）
- ffmpeg + ffprobe

### 1. 启动 AI 服务

```bash
git clone https://github.com/sizzlecar/ferrum-infer-rs.git
cd ferrum-infer-rs
# 按照 ferrum-infer-rs 的 README 启动 CLIP 推理服务
# 默认监听 0.0.0.0:8000
```

### 2. 启动后端

```bash
cd backend

export STORAGE_ROOT="/path/to/storage"
export DATABASE_URL="postgres://user@localhost:5432/mediadb"
export AI_SERVICE_URL="http://127.0.0.1:8000"
export FFMPEG_BIN="ffmpeg"
export FFPROBE_BIN="ffprobe"

cargo run --release
# 服务监听 0.0.0.0:8080，自动通过 Bonjour/mDNS 广播
```

### 3. iOS App

Xcode 打开 `ios-app/PandaVault.xcodeproj`，build 到 iPhone。App 通过 Bonjour 自动发现局域网内的后端服务。

## 多卷存储

支持多块硬盘/目录组成存储池，写入时自动选择有空间的卷。

```bash
# 添加新硬盘
curl -X POST http://localhost:8080/api/volumes \
  -H "Content-Type: application/json" \
  -d '{"label": "外接硬盘2", "base_path": "/mnt/disk2", "priority": 10}'

# 扫描已有文件（不移动文件，只建立 DB 索引）
curl -X POST http://localhost:8080/api/scan \
  -H "Content-Type: application/json" \
  -d '{"volume_id": "xxx-xxx"}'

# 查看扫描进度
curl http://localhost:8080/api/scan/{session_id}
```

盘满了？插新盘，加一条卷配置，自动往新盘写。

## API 一览

| 方法 | 路径 | 说明 |
|------|------|------|
| GET | `/api/health` | 健康检查 |
| POST | `/api/upload` | 上传文件（multipart） |
| POST | `/api/upload/init` | 分片上传初始化 |
| PATCH | `/api/upload/:id` | 追加分片 |
| POST | `/api/upload/:id/complete` | 完成分片上传 |
| GET | `/api/assets` | 资产列表（支持文件名搜索） |
| GET | `/api/assets/:id` | 资产详情 |
| DELETE | `/api/assets/:id` | 删除资产 |
| GET | `/api/timeline` | 按月时间轴聚合 |
| POST | `/api/search/semantic` | AI 语义搜索 |
| POST | `/api/search/image` | 以图搜图 |
| GET/POST | `/api/folders` | 文件夹列表/创建 |
| GET | `/api/folders/:id/assets` | 文件夹内资产 |
| GET/POST | `/api/volumes` | 存储卷列表/添加 |
| POST | `/api/scan` | 触发目录扫描 |
| GET | `/api/scan/:id` | 扫描进度 |

## 目录结构

```
backend/
  src/
    main.rs            # 启动、mDNS 广播、后台任务
    api.rs             # HTTP 路由和处理器
    media.rs           # 文件入库、SHA256 去重、缩略图
    jobs.rs            # 后台 worker（转码、元数据提取、embedding）
    volume.rs          # 多卷存储管理
    scan.rs            # 目录扫描引擎
    folder.rs          # 文件夹 CRUD + 文件移动
    chunked_upload.rs  # 分片上传（大文件）
    ai.rs              # AI 服务客户端（CLIP embedding）
  migrations/          # PostgreSQL 迁移脚本

ios-app/PandaVault/
    App/               # 入口、AppState、ContentView
    Models/            # Asset、Folder、UploadSession
    Services/          # APIService、SyncEngine、UploadManager
    Views/             # Gallery、Detail、Settings、Upload
    ViewModels/        # GalleryViewModel
```

## 贡献

欢迎提 Issue 和 Pull Request。

## 许可证

[MIT](LICENSE)
