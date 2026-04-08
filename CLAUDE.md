# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

PandaVault is a self-hosted LAN media vault: Rust backend (Axum) + PostgreSQL/pgvector + iOS app (SwiftUI). It manages photos/videos with AI semantic search (CLIP), multi-volume storage, and chunked uploads.

## Build & Run

### Backend (Rust)

```bash
cd backend
cargo build                    # dev build
cargo build --release          # release build (thin LTO)
cargo run --release            # run server (listens 0.0.0.0:8080, auto-broadcasts mDNS)
cargo test                     # run all tests
cargo test test_name           # run a single test
```

Requires: Rust 1.85+, PostgreSQL 15+ with pgvector, ffmpeg/ffprobe.

Migrations run automatically on startup via `sqlx::migrate!("./migrations")` in `db.rs`.

### iOS App

```bash
cd ios-app
open PandaVault.xcodeproj      # open in Xcode and build
# Or command line:
xcodebuild -scheme PandaVault -destination 'platform=iOS Simulator,name=iPhone 15'
```

XcodeGen project (`project.yml`): Swift 5.9, iOS 17.0 deployment target.

### Docker

```bash
docker build -f backend/Dockerfile -t panda-vault .
```

### Environment Variables

Key backend env vars (see `config.rs` for full list):
- `DATABASE_URL` — Postgres connection string
- `STORAGE_ROOT` — base storage path (raw, proxies, temp dirs derived from this)
- `AI_SERVICE_URL` — optional CLIP inference service URL
- `FFMPEG_BIN` / `FFPROBE_BIN` — ffmpeg binary paths
- `BIND_ADDR` — listen address (default `0.0.0.0:8080`)
- `RUST_LOG` — logging level (e.g. `debug,panda_vault_backend=trace`)

## Architecture

```
iOS App (SwiftUI) ←— HTTP/mDNS —→ Rust API (Axum) ←— SQL —→ PostgreSQL + pgvector
                                       ↓
                              Filesystem (volumes) + AI Service (CLIP)
```

### Backend (`backend/src/`)

All routes are defined in `api.rs` via `routes()` function. The monolithic `api.rs` (~45KB) contains all HTTP handlers. Shared state is `AppState` in `db.rs` (pool, config, AI client, volumes).

Key data flow:
- **Upload** → `media.rs` (ingest, SHA256 dedup) → enqueue `transcode_jobs` + `embedding_jobs`
- **Background workers** in `jobs.rs` poll job tables, run ffmpeg transcoding and CLIP embedding
- **Volume selection** → `volume.rs` VolumeManager picks highest-priority disk with space
- **Semantic search** → `ai.rs` embeds query via CLIP, then pgvector cosine similarity

### iOS App (`ios-app/PandaVault/`)

Standard SwiftUI architecture: App → Models → Services → ViewModels → Views. Server auto-discovered via Bonjour (`_pandavault._tcp`). `APIService.swift` mirrors the backend REST API.

### Database

8 sequential migrations in `backend/migrations/`. Key tables: `assets`, `folders`, `storage_volumes`, `transcode_jobs`, `embedding_jobs`, `asset_embeddings` (pgvector 512-dim), `upload_sessions`, `scan_sessions`.

## Key Patterns

- **Error handling**: `anyhow::Result` internally, `json_err()` helper in `api.rs` for HTTP error responses
- **Path security**: `normalize_path()` in `config.rs` prevents directory traversal; `sanitize_filename()` strips illegal chars
- **Dedup**: SHA256 `file_hash` unique constraint for all files; videos additionally dedup by size+duration
- **mDNS**: macOS uses `dns-sd` CLI subprocess; other platforms use `mdns-sd` crate (conditional compilation via `cfg`)
- **Background tasks**: temp file cleanup (5 min), disk space refresh (60 sec), job workers (configurable poll interval)
- **Chunked upload**: 50MB chunks, `.part` temp files, resume via HEAD offset query
- **iOS sheets**: consolidated to avoid SwiftUI presentation conflicts (recent pattern fix)
