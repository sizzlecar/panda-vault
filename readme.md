---

# HomeMediaCloud 项目开发文档

**版本:** v1.0
**项目负责人:** (你的名字)
**核心用户:** 妻子 (自媒体创作者)
**项目目标:** 构建一个私有局域网媒体资产管理系统，实现“手机端无感备份/预览”与“电脑端直接非线性剪辑”。

---

## 1. 架构总览 (Architecture)

## 0. 当前仓库实现状态（已完成一期 + 二期）

本仓库已按本文档落地了 **一期(MVP)** 与 **二期(体验升级)** 的最小可运行实现：

- **一期**：`POST /api/upload` 流式落盘到 `/raw/YYYY/MM`、SHA256 去重、同步生成一张缩略图、写入 PostgreSQL。
- **二期**：上传后自动写入 `transcode_jobs`，后台 worker 轮询队列，执行 `ffprobe` 提取拍摄时间/分辨率/时长并回填，再 `ffmpeg` 生成 720p H.264 proxy；通过 `/proxies/...` 支持 **HTTP Range** 预览。

### 快速启动（Docker Compose）

1. 在宿主机准备硬盘挂载点（示例）：`/mnt/media_storage`，并确保存在子目录：
   - `/mnt/media_storage/raw`
   - `/mnt/media_storage/proxies`
   - `/mnt/media_storage/.temp`
2. 启动：

```bash
cd /Users/chejinxuan/rust_ws/panda-vault
docker-compose up -d --build
```

3. 打开上传页：浏览器访问 `http://<宿主机IP>:8080/`

### 已实现接口一览

- **健康检查**：`GET /api/health`
- **上传**：`POST /api/upload`（multipart，字段名 `file`）
- **资产列表/搜索**：`GET /api/assets?q=xxx&limit=50&offset=0`
- **资产详情**：`GET /api/assets/:id`
- **时间轴聚合**：`GET /api/timeline`
- **Proxy 预览（Range）**：`GET /proxies/...`

### 1.1 设计原则
1.  **Web First:** 优先开发响应式 Web 端，降低初期开发成本，全平台兼容。
2.  **No-S3 (文件系统优先):** 放弃对象存储，直接使用文件系统 (Native File System)，确保 SMB 协议能以零损耗性能访问原始文件。
3.  **单节点 Docker:** 采用轻量化部署方案，适配“笔记本 + 移动硬盘”的硬件环境。

### 1.2 物理与逻辑架构
*   **宿主机 (Host):** 运行 Linux (Ubuntu/Debian 推荐) 或 Windows 的笔记本/MiniPC。
*   **存储层:** 外接 USB 3.0+ 大容量硬盘。
    *   *格式:* 推荐 **Ext4** (Linux)；若必须兼容 Windows 直插则用 NTFS (需容忍性能折损)。
*   **服务层 (Docker):**
    *   `Backend`: Rust API + 业务逻辑。
    *   `DB`: PostgreSQL (元数据)。
*   **共享层 (Host Native):**
    *   `Samba`: 运行在宿主机 OS 上，提供 SMB 文件共享服务。

---

## 2. 目录与存储规划

**硬盘挂载点:** `/mnt/media_storage`

| 目录路径 | 权限 | 用途说明 |
| :--- | :--- | :--- |
| `/mnt/media_storage/raw/` | **SMB 读写** | 存放 4K 原始素材，按 `YYYY/MM` 归档。剪辑软件直接读取此处。 |
| `/mnt/media_storage/proxies/` | **仅 Web 读** | 存放转码后的 720p 预览文件 (H.264/WebP)，供 Web/App 流畅播放。 |
| `/mnt/media_storage/.temp/` | 后端读写 | 文件上传时的临时缓存区，校验完成后移动至 raw。 |
| `/mnt/media_storage/postgres/`| DB 读写 | 数据库持久化文件 (建议优先放内置 SSD，若空间不够才放此处)。 |

---

## 3. 基础设施配置 (Infrastructure)

### 3.1 Docker Compose (`docker-compose.yml`)

```yaml
version: '3.8'

services:
  # 后端服务
  app:
    image: homemedia-backend:latest
    container_name: media_server_app
    restart: unless-stopped
    ports:
      - "8080:8080"
    volumes:
      # [关键] 透传宿主机硬盘，实现与 SMB 共享同一物理文件
      - /mnt/media_storage:/data
    environment:
      - STORAGE_ROOT=/data
      - DATABASE_URL=postgres://user:pass@db:5432/mediadb
    depends_on:
      - db

  # 数据库服务
  db:
    image: postgres:15-alpine
    container_name: media_server_db
    restart: unless-stopped
    environment:
      POSTGRES_USER: user
      POSTGRES_PASSWORD: pass
      POSTGRES_DB: mediadb
    volumes:
      - ./postgres_data:/var/lib/postgresql/data
    ports:
      - "5432:5432"

  # (二期可选) 搜索引擎
  # meilisearch: ...
```

### 3.2 Samba 配置 (`/etc/samba/smb.conf`)
*注意：此配置需应用在宿主机，而非容器内。*

```ini
[global]
   workgroup = WORKGROUP
   server string = Media NAS
   security = user
   
   # [关键] 针对 macOS/iOS 的性能优化 (必配)
   vfs objects = catia fruit streams_xattr
   fruit:metadata = stream
   fruit:model = MacSamba
   fruit:posix_rename = yes 
   fruit:veto_appledouble = no
   fruit:wipe_intentionally_left_blank_rfork = yes 
   fruit:delete_empty_adfiles = yes

[RawMaterials]
   path = /mnt/media_storage/raw
   browseable = yes
   writable = yes
   # 确保 Docker 用户和 SMB 用户能操作同一文件
   create mask = 0664
   directory mask = 0775
   valid users = your_username
```

#### macOS（无 Linux 机器时的推荐做法：使用系统自带 SMB 文件共享）

如果你只有 macOS（无 Linux 宿主机），建议直接启用系统 SMB 共享来测试：

1. 打开 **系统设置** → **通用** → **共享** → 打开 **文件共享**。
2. 点进 **文件共享**，在“共享文件夹”里添加你的目录（示例）：
   - 项目内测试：`/Users/chejinxuan/rust_ws/panda-vault/media_storage/raw`
   - 或者直接共享整个：`/Users/chejinxuan/rust_ws/panda-vault/media_storage`
3. 点击 **选项…** 勾选你的用户的 **SMB 共享**，并设置访问权限（读写）。
4. 连接测试：
   - 本机 Finder：**前往** → **连接服务器** → 输入 `smb://localhost`
   - 其它设备：输入 `smb://<你的mac局域网IP>`（Windows 用 `\\<IP>\共享名`）

> 提示：如果你后面还想用 Docker 起 Samba 容器占用 445 端口，通常需要先关闭 macOS 的“文件共享”，否则会端口冲突。

#### 使用 Docker 运行 SMB（跨 macOS / Windows 的“尽量统一”方案）

如果你希望尽量忽略宿主机差异、用同一份配置快速验证 SMB 流程，可以用仓库提供的 `docker-compose.smb.yml` 启动一个 Samba 容器。

**注意：** 为避免与系统 SMB（445 端口）冲突，默认使用 **宿主机 1445 端口** 映射到容器 445。

启动：

```bash
# 指定 SMB 共享根目录（示例：共享 ./media_storage/raw）
SMB_SHARE_ROOT=./media_storage/raw \
SMB_USER=pandavault SMB_PASS=pandavault \
docker compose -f docker-compose.smb.yml up -d
```

连接（需要显式端口）：
- macOS Finder：`smb://localhost:1445/RawMaterials`
- Windows（CMD）：`net use \\127.0.0.1@1445\RawMaterials /user:pandavault pandavault`

> 如果你能关掉宿主机的 SMB 服务（macOS 文件共享 / Windows 文件共享）并确保 445 未被占用，也可以把 `docker-compose.smb.yml` 里的端口改成 `445:445`，客户端就不需要写端口了。

**性能提示（你现在觉得“很卡”的主要原因）：**
- Docker Desktop 的 **bind mount（把宿主机目录映射进容器）** 在 macOS/Windows 上性能通常不如原生文件系统；SMB 再叠一层协议会更明显。
- Finder 在浏览/打开图片时会额外触发 **缩略图/预览/元数据扫描**，体感会更卡。

**推荐：** 如果你目标是“日常剪辑/大量媒体浏览”，在 macOS 上优先用系统自带 **文件共享（SMB）**（上一节），通常会比“Docker 里跑 Samba + bind mount”流畅很多。

**如果你仍要继续用 Docker SMB 做功能验证：**
- Finder → 查看 → 显示查看选项（或按 `⌘J`），尽量关闭 **图标预览/缩略图** 相关选项（不同 macOS 版本名字略有差异）。
- 尽量用“列表视图”而不是大图标网格视图浏览共享目录。

---

## 4. 数据库设计 (Database Schema)

```sql
CREATE TABLE assets (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    filename TEXT NOT NULL,
    
    -- 物理路径
    file_path TEXT NOT NULL,        -- e.g., /raw/2025/01/video.mov
    proxy_path TEXT,                -- e.g., /proxies/2025/01/video_720p.mp4
    
    -- 查重指纹
    file_hash VARCHAR(64) NOT NULL, -- SHA256
    size_bytes BIGINT NOT NULL,
    
    -- 核心元数据 (二期重点)
    shoot_at TIMESTAMP,             -- 拍摄时间 (从 Exif 提取)
    created_at TIMESTAMP DEFAULT NOW(), -- 上传时间
    duration_sec INTEGER,           -- 视频时长
    width INTEGER,
    height INTEGER,
    
    -- 软删除标记
    is_deleted BOOLEAN DEFAULT FALSE
);

-- 加速查重与时间轴查询
CREATE UNIQUE INDEX idx_assets_hash ON assets(file_hash);
CREATE INDEX idx_assets_shoot_at ON assets(shoot_at DESC);
```

---

## 5. 功能开发规划 (Roadmap)

### 第一阶段：MVP (可用性验证)
**目标：** 跑通“上传 -> 存储 -> 电脑剪辑”闭环。

1.  **后端 (Rust):**
    *   实现流式上传接口 (`POST /upload`)，直接写入磁盘，避免内存溢出。
    *   实现简单的 SHA256 计算（或快速 Hash：头尾 1MB + Size）用于去重。
    *   集成 FFmpeg：上传成功后，同步调用命令行生成一张缩略图。
2.  **前端 (Web):**
    *   实现多文件选择上传 UI。
    *   集成 `Screen Wake Lock API`，上传时保持手机屏幕常亮。
3.  **交付物：** 一个能用的局域网网页，老婆上传视频，你能在电脑 SMB 文件夹里看到。

### 第二阶段：体验升级 (好用性)
**目标：** 解决“文件多了找不到”和“预览卡顿”问题。

1.  **转码流水线:**
    *   构建异步任务队列 (Task Queue)，上传后后台生成 720p H.264 预览流。
    *   前端播放器支持 HTTP Range 请求，实现拖拽进度条。
2.  **元数据管理:**
    *   引入 `kamadak-exif` 或解析 FFmpeg 输出，提取**拍摄日期**。
    *   Web 端实现**“时光轴”视图** (Timeline)，按日期聚合视频。
3.  **搜索增强:**
    *   实现基于 SQL 的文件名/日期搜索。

### 第三阶段：智能化与移动端 (完美形态)
**目标：** 自动化与 AI 赋能。

1.  **AI 语义搜索:**
    *   集成 CLIP 模型 (通过 Rust `candle` 库或 Python 服务)。
    *   建立向量索引，支持输入“猫”、“海边”直接搜视频。
2.  **原生 App (Flutter/RN):**
    *   *仅当 Web 端体验（如不能后台上传）无法忍受时开发。*
    *   实现：后台静默上传、相册增量同步、一键下载回相册。
3.  **冷备份:**
    *   编写 Shell 脚本，定期将 `raw` 目录 rsync 到第二块硬盘。

---

## 6. 避坑指南 (Caveats)

1.  **USB 供电:** 笔记本 USB 接口供电可能不足，导致移动硬盘高负载（转码时）掉盘。**务必使用带独立供电的 USB Hub 或硬盘盒。**
2.  **iOS 传大文件:** 使用 Web 端上传时，Safari 可能会因为内存限制刷新页面。建议前端实现**分片上传 (Chunk Upload)**。
3.  **剪辑权限:** 如果发现电脑上无法修改/删除 SMB 里的文件，检查宿主机文件夹的 `chmod` 权限，确保 Samba 用户有写权限。
4.  **iOS SMB 缓存:** iOS "文件" App 浏览 SMB 有时会缓存缩略图导致刷新慢，这是 iOS 机制问题，无法通过后端完全解决，推荐使用 **Infuse** App 浏览。

---

## 7. 维护与操作

### 启动服务
```bash
# 在项目根目录
docker-compose up -d
```

### 备份数据库
```bash
docker exec -t media_server_db pg_dumpall -c -U user > dump_`date +%d-%m-%Y"_"%H_%M_%S`.sql
```

### 紧急恢复 (硬盘损坏场景)
1.  更换新硬盘，挂载至 `/mnt/media_storage`。
2.  从冷备份硬盘恢复 `raw` 目录数据。
3.  `proxies` 目录丢失也没关系，可编写脚本让后端重新扫描 `raw` 目录并触发转码任务。

---

## 8. 第三阶段实现状态 ✅

### 8.1 AI 语义搜索

**已实现功能：**
- ✅ PostgreSQL + pgvector 向量索引（512 维 CLIP 向量）
- ✅ Python CLIP 服务（基于 `openai/clip-vit-base-patch32`）
- ✅ 自动 embedding 生成（转码完成后自动入队）
- ✅ 语义搜索 API（`POST /api/search/semantic`）

**架构：**
```
用户输入 "海边日落"
    ↓
Rust API → Python AI 服务（文本→向量）
    ↓
pgvector 余弦相似度搜索
    ↓
返回最相似的资产列表
```

**API 接口：**
```bash
# 语义搜索
curl -X POST http://localhost:8080/api/search/semantic \
  -H "Content-Type: application/json" \
  -d '{"text": "猫", "limit": 20}'

# AI 服务健康检查
curl http://localhost:8080/api/ai/health
```

### 8.2 Flutter 移动端 App

**目录：** `mobile/`

**已实现功能：**
- ✅ 相册浏览（瀑布流布局）
- ✅ 语义搜索 / 文件名搜索切换
- ✅ 多文件上传（从文件选择器/相册）
- ✅ 相册增量同步（后台静默）
- ✅ 视频预览播放（Chewie）
- ✅ 图片双指缩放
- ✅ 深色/浅色主题
- ✅ 服务器连接配置

**运行：**
```bash
cd mobile
flutter pub get
flutter run
```

### 8.3 冷备份脚本

**脚本：** `scripts/backup.sh`

**使用：**
```bash
# 手动执行
./scripts/backup.sh /mnt/backup_disk/media_backup

# 定时任务（每天凌晨 3 点）
# crontab -e
0 3 * * * /path/to/panda-vault/scripts/backup.sh /mnt/backup_disk/media_backup
```

**功能：**
- rsync 增量同步（只传输变化部分）
- 自动跳过临时文件（.DS_Store, Thumbs.db 等）
- 日志记录（保留最近 30 次）
- 磁盘空间检查

---

## 9. 完整启动（含 AI 服务）

```bash
# 启动所有服务（后端 + 数据库 + AI）
./start.sh --storage-root ./media_storage

# 或手动
docker-compose up -d --build
```

**服务端口：**
| 服务 | 端口 | 说明 |
|------|------|------|
| Rust API | 8080 | 主后端服务 |
| AI Service | 8000 | CLIP 向量服务 |
| PostgreSQL | 5432 | 数据库（含 pgvector） |

**首次启动注意：**
- AI 服务会在首次构建时下载 CLIP 模型（约 600MB），需要网络访问
- 模型会缓存到 `./ai_cache` 目录，后续启动无需重新下载