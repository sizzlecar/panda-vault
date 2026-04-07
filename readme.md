# PandaVault

[中文文档](README_CN.md)

Private LAN media asset management system — a self-hosted media vault with iOS app, AI-powered search, and multi-disk storage pool.

## Features

- **iOS App** — Auto-sync photo library, browse, search, video playback
- **AI Semantic Search** — Search photos/videos by natural language (CLIP vector retrieval)
- **Reverse Image Search** — Find similar assets by uploading a photo
- **Multi-Volume Storage** — Multiple disks as a storage pool, auto-failover when full
- **Directory Scan** — Import existing files and folder structure into DB without moving files
- **Chunked Upload** — 50MB chunks with resume support, handles 4GB+ files
- **Smart Dedup** — SHA256 hash dedup + video size/duration dedup
- **Incremental Sync** — Only scans photos added since last sync

## Architecture

```
┌─────────┐     HTTP/mDNS     ┌──────────────┐     SQL      ┌─────────────────┐
│ iOS App │ ←───────────────→ │  Rust API    │ ←──────────→ │  PostgreSQL     │
│ SwiftUI │                   │  (Axum)      │              │  + pgvector     │
└─────────┘                   └──────┬───────┘              └─────────────────┘
                                     │
                              ┌──────┴───────┐
                              │              │
                    ┌─────────▼──┐    ┌──────▼──────┐
                    │ Filesystem │    │ AI Service  │
                    │ (volumes)  │    │ (CLIP)      │
                    └────────────┘    └─────────────┘
```

| Component | Stack | Description |
|-----------|-------|-------------|
| Backend | Rust + Axum + sqlx | API, upload, transcode job queue, volume management |
| Database | PostgreSQL 15 + pgvector | Metadata + vector similarity search |
| AI Service | [ferrum-infer-rs](https://github.com/sizzlecar/ferrum-infer-rs.git) | CLIP model inference for text/image vectorization |
| iOS App | SwiftUI + AVKit | Photo library sync, browsing, video playback |
| Storage | Local filesystem | Multi-volume storage pool with hot expansion |

## Quick Start

### Prerequisites

- Rust 1.80+
- PostgreSQL 15+ with [pgvector](https://github.com/pgvector/pgvector) extension
- ffmpeg + ffprobe

### 1. Start AI Service

```bash
git clone https://github.com/sizzlecar/ferrum-infer-rs.git
cd ferrum-infer-rs
# Follow ferrum-infer-rs README to start the CLIP inference server
# Listens on 0.0.0.0:8000 by default
```

### 2. Start Backend

```bash
cd backend

export STORAGE_ROOT="/path/to/storage"
export DATABASE_URL="postgres://user@localhost:5432/mediadb"
export AI_SERVICE_URL="http://127.0.0.1:8000"
export FFMPEG_BIN="ffmpeg"
export FFPROBE_BIN="ffprobe"

cargo run --release
# Listens on 0.0.0.0:8080, auto-broadcasts via Bonjour/mDNS
```

### 3. iOS App

Open `ios-app/PandaVault.xcodeproj` in Xcode, build to iPhone. The app auto-discovers the backend on the local network via Bonjour.

## Multi-Volume Storage

Multiple disks/directories form a storage pool. Writes automatically go to the highest-priority volume with available space.

```bash
# Add a new disk
curl -X POST http://localhost:8080/api/volumes \
  -H "Content-Type: application/json" \
  -d '{"label": "External Drive 2", "base_path": "/mnt/disk2", "priority": 10}'

# Scan existing files (indexes without moving)
curl -X POST http://localhost:8080/api/scan \
  -H "Content-Type: application/json" \
  -d '{"volume_id": "xxx-xxx"}'

# Check scan progress
curl http://localhost:8080/api/scan/{session_id}
```

Disk full? Plug in a new one, add a volume config, and new writes go there automatically.

## API Reference

| Method | Path | Description |
|--------|------|-------------|
| GET | `/api/health` | Health check |
| POST | `/api/upload` | Upload file (multipart) |
| POST | `/api/upload/init` | Initialize chunked upload |
| PATCH | `/api/upload/:id` | Append chunk |
| POST | `/api/upload/:id/complete` | Complete chunked upload |
| GET | `/api/assets` | List assets (supports filename search) |
| GET | `/api/assets/:id` | Asset detail |
| DELETE | `/api/assets/:id` | Delete asset |
| GET | `/api/timeline` | Monthly timeline aggregation |
| POST | `/api/search/semantic` | AI semantic search |
| POST | `/api/search/image` | Reverse image search |
| GET/POST | `/api/folders` | List/create folders |
| GET | `/api/folders/:id/assets` | Folder assets |
| GET/POST | `/api/volumes` | List/add storage volumes |
| POST | `/api/scan` | Trigger directory scan |
| GET | `/api/scan/:id` | Scan progress |

## Project Structure

```
backend/
  src/
    main.rs            # Entry, mDNS broadcast, background tasks
    api.rs             # HTTP routes and handlers
    media.rs           # File ingestion, SHA256 dedup, thumbnails
    jobs.rs            # Background worker (transcode, metadata, embedding)
    volume.rs          # Multi-volume storage manager
    scan.rs            # Directory scan engine
    folder.rs          # Folder CRUD + file move
    chunked_upload.rs  # Chunked upload (large files)
    ai.rs              # AI service client (CLIP embedding)
  migrations/          # PostgreSQL migration scripts

ios-app/PandaVault/
    App/               # Entry, AppState, ContentView
    Models/            # Asset, Folder, UploadSession
    Services/          # APIService, SyncEngine, UploadManager
    Views/             # Gallery, Detail, Settings, Upload
    ViewModels/        # GalleryViewModel
```

## Contributing

Contributions are welcome! Please open an issue or submit a pull request.

## License

[MIT](LICENSE)
