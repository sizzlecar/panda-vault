//! 目录扫描：扫描现有文件导入 DB

use chrono::NaiveDateTime;
use serde::Serialize;
use sha2::{Digest, Sha256};
use sqlx::PgPool;
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use tokio::io::AsyncReadExt;
use uuid::Uuid;
use walkdir::WalkDir;

use crate::db::AppState;
use crate::volume::{self, StorageVolume};
use crate::{api, jobs, media};

/// 扫描会话（DB 行）
#[derive(Debug, Clone, Serialize, sqlx::FromRow)]
pub struct ScanSession {
    pub id: Uuid,
    pub volume_id: Uuid,
    pub scan_path: String,
    pub status: String,
    pub total_files: i32,
    pub processed_files: i32,
    pub new_assets: i32,
    pub skipped_files: i32,
    pub error_count: i32,
    pub started_at: Option<NaiveDateTime>,
    pub finished_at: Option<NaiveDateTime>,
    pub created_at: NaiveDateTime,
    pub last_error: Option<String>,
}

/// 支持的媒体文件扩展名
const MEDIA_EXTENSIONS: &[&str] = &[
    "jpg", "jpeg", "png", "heic", "heif", "webp", "gif", "bmp", "tiff", "tif",
    "mp4", "mov", "m4v", "avi", "mkv", "webm", "3gp",
];

/// 启动扫描（异步后台执行，立即返回 session_id）
pub async fn start_scan(
    state: AppState,
    volume_id: Uuid,
    scan_path: Option<String>,
) -> anyhow::Result<Uuid> {
    let vol = state.volumes.get_volume(volume_id).await?;
    let scan_path = scan_path.unwrap_or_else(|| "raw/albums".to_string());

    // 检查是否有正在运行的扫描
    let running: Option<(Uuid,)> = sqlx::query_as(
        "SELECT id FROM scan_sessions WHERE volume_id = $1 AND status = 'running' LIMIT 1",
    )
    .bind(volume_id)
    .fetch_optional(&state.pool)
    .await?;
    if let Some((id,)) = running {
        anyhow::bail!("卷 '{}' 已有扫描任务正在运行: {}", vol.label, id);
    }

    // 创建会话
    let session_id = Uuid::new_v4();
    sqlx::query(
        "INSERT INTO scan_sessions (id, volume_id, scan_path, status) VALUES ($1, $2, $3, 'pending')",
    )
    .bind(session_id)
    .bind(volume_id)
    .bind(&scan_path)
    .execute(&state.pool)
    .await?;

    // 后台执行
    tokio::spawn(async move {
        if let Err(e) = run_scan(state, session_id, vol, scan_path).await {
            tracing::error!("扫描失败 [{}]: {:#}", session_id, e);
        }
    });

    Ok(session_id)
}

/// 获取扫描会话
pub async fn get_session(pool: &PgPool, id: Uuid) -> anyhow::Result<Option<ScanSession>> {
    let row = sqlx::query_as::<_, ScanSession>(
        "SELECT * FROM scan_sessions WHERE id = $1",
    )
    .bind(id)
    .fetch_optional(pool)
    .await?;
    Ok(row)
}

/// 列出扫描会话
pub async fn list_sessions(pool: &PgPool) -> anyhow::Result<Vec<ScanSession>> {
    let rows = sqlx::query_as::<_, ScanSession>(
        "SELECT * FROM scan_sessions ORDER BY created_at DESC LIMIT 20",
    )
    .fetch_all(pool)
    .await?;
    Ok(rows)
}

/// 核心扫描逻辑
async fn run_scan(
    state: AppState,
    session_id: Uuid,
    vol: StorageVolume,
    scan_path: String,
) -> anyhow::Result<()> {
    // 标记开始
    sqlx::query("UPDATE scan_sessions SET status = 'running', started_at = NOW() WHERE id = $1")
        .bind(session_id)
        .execute(&state.pool)
        .await?;

    let base_dir = PathBuf::from(&vol.base_path).join(&scan_path);
    if !base_dir.exists() {
        let err = format!("扫描路径不存在: {}", base_dir.display());
        mark_failed(&state.pool, session_id, &err).await;
        anyhow::bail!("{}", err);
    }

    // 第一遍：计数
    let mut total = 0i32;
    for entry in WalkDir::new(&base_dir).follow_links(true).into_iter().filter_map(|e| e.ok()) {
        if entry.file_type().is_file() && is_media_file(entry.path()) {
            total += 1;
        }
    }
    sqlx::query("UPDATE scan_sessions SET total_files = $2 WHERE id = $1")
        .bind(session_id)
        .bind(total)
        .execute(&state.pool)
        .await?;
    tracing::info!("扫描 [{}]: 发现 {} 个媒体文件", session_id, total);

    // 第二遍：处理
    let mut processed = 0i32;
    let mut new_count = 0i32;
    let mut skipped = 0i32;
    let mut errors = 0i32;
    let mut folder_cache: HashMap<String, Uuid> = HashMap::new();

    // albums 的根路径，用于计算相对路径
    let albums_base = PathBuf::from(&vol.base_path).join("raw/albums");

    for entry in WalkDir::new(&base_dir).follow_links(true).into_iter().filter_map(|e| e.ok()) {
        if !entry.file_type().is_file() || !is_media_file(entry.path()) {
            continue;
        }

        let file_path = entry.path();
        match process_one_file(
            &state,
            &vol,
            file_path,
            &albums_base,
            &mut folder_cache,
        )
        .await
        {
            Ok(true) => new_count += 1,
            Ok(false) => skipped += 1,
            Err(e) => {
                tracing::warn!("扫描文件失败 [{}]: {}", file_path.display(), e);
                errors += 1;
                sqlx::query("UPDATE scan_sessions SET last_error = $2 WHERE id = $1")
                    .bind(session_id)
                    .bind(format!("{}: {}", file_path.display(), e))
                    .execute(&state.pool)
                    .await?;
            }
        }

        processed += 1;
        if processed % 10 == 0 {
            sqlx::query(
                "UPDATE scan_sessions SET processed_files=$2, new_assets=$3, skipped_files=$4, error_count=$5 WHERE id=$1"
            )
            .bind(session_id).bind(processed).bind(new_count).bind(skipped).bind(errors)
            .execute(&state.pool).await?;
        }
    }

    // 最终更新
    sqlx::query(
        "UPDATE scan_sessions SET status='completed', processed_files=$2, new_assets=$3, skipped_files=$4, error_count=$5, finished_at=NOW() WHERE id=$1"
    )
    .bind(session_id).bind(processed).bind(new_count).bind(skipped).bind(errors)
    .execute(&state.pool).await?;

    tracing::info!(
        "扫描完成 [{}]: {} 处理, {} 新增, {} 跳过, {} 失败",
        session_id, processed, new_count, skipped, errors
    );
    Ok(())
}

/// 处理单个文件，返回 true=新增, false=跳过
async fn process_one_file(
    state: &AppState,
    vol: &StorageVolume,
    abs_path: &Path,
    albums_base: &Path,
    folder_cache: &mut HashMap<String, Uuid>,
) -> anyhow::Result<bool> {
    // 计算 file_path（卷内相对路径）
    let vol_base = PathBuf::from(&vol.base_path);
    let rel_path = abs_path.strip_prefix(&vol_base)?;
    let file_path = format!("/{}", rel_path.to_string_lossy().replace('\\', "/"));

    // 幂等检查：file_path + volume_id 已存在则跳过
    let existing: Option<(Uuid,)> = sqlx::query_as(
        "SELECT id FROM assets WHERE file_path = $1 AND volume_id = $2 LIMIT 1",
    )
    .bind(&file_path)
    .bind(vol.id)
    .fetch_optional(&state.pool)
    .await?;
    if existing.is_some() {
        return Ok(false);
    }

    // 流式计算 SHA256
    let (file_hash, file_size) = hash_file_streaming(abs_path).await?;

    // 哈希去重
    let hash_dup: Option<(Uuid,)> = sqlx::query_as(
        "SELECT id FROM assets WHERE file_hash = $1 LIMIT 1",
    )
    .bind(&file_hash)
    .fetch_optional(&state.pool)
    .await?;
    if hash_dup.is_some() {
        return Ok(false);
    }

    let filename = abs_path
        .file_name()
        .map(|s| s.to_string_lossy().to_string())
        .unwrap_or_else(|| "unknown".to_string());

    // 提取元数据（shoot_at, duration, dimensions）
    let probe_info = media::probe(&state.cfg, abs_path).await.ok();
    let shoot_at = probe_info.as_ref().and_then(|p| p.shoot_at);

    // 没有 EXIF 时用文件修改时间
    let shoot_at = shoot_at.or_else(|| {
        std::fs::metadata(abs_path)
            .ok()
            .and_then(|m| m.modified().ok())
            .map(|t| {
                let dt: chrono::DateTime<chrono::Utc> = t.into();
                dt.naive_utc()
            })
    });

    // 生成缩略图
    let asset_id = Uuid::new_v4();
    let now = chrono::Utc::now();
    let (yyyy, mm) = (
        chrono::Datelike::year(&now),
        chrono::Datelike::month(&now),
    );
    let thumb_rel = format!("/proxies/{:04}/{:02}/{}_thumb.jpg", yyyy, mm, asset_id);
    let thumb_abs = volume::resolve_path(vol, &thumb_rel);
    crate::config::Config::ensure_parent(&thumb_abs)?;
    let thumb_path = match media::try_generate_thumbnail(&state.cfg, abs_path, &thumb_abs).await {
        Ok(()) => Some(thumb_rel),
        Err(e) => {
            tracing::warn!("缩略图生成失败 [{}]: {}", filename, e);
            None
        }
    };

    // 入库
    let new_asset = media::NewAsset {
        id: asset_id,
        filename: filename.clone(),
        file_path: file_path.clone(),
        proxy_path: None,
        thumb_path,
        file_hash,
        size_bytes: file_size as i64,
        shoot_at,
        duration_sec: probe_info.as_ref().and_then(|p| p.duration_sec),
        width: probe_info.as_ref().and_then(|p| p.width),
        height: probe_info.as_ref().and_then(|p| p.height),
        uploaded_by: Some("scan".to_string()),
    };

    api::insert_asset_and_job(&state.pool, &new_asset).await?;

    // 设置 volume_id
    sqlx::query("UPDATE assets SET volume_id = $2 WHERE id = $1")
        .bind(asset_id)
        .bind(vol.id)
        .execute(&state.pool)
        .await?;

    // 关联文件夹
    if let Ok(rel_to_albums) = abs_path.parent().unwrap_or(abs_path).strip_prefix(albums_base) {
        let dir_str = rel_to_albums.to_string_lossy().replace('\\', "/");
        if !dir_str.is_empty() {
            let folder_id = ensure_folder_chain(&state.pool, &dir_str, folder_cache).await?;
            sqlx::query(
                "INSERT INTO asset_folders (folder_id, asset_id, added_by) VALUES ($1, $2, 'scan') ON CONFLICT DO NOTHING"
            )
            .bind(folder_id)
            .bind(asset_id)
            .execute(&state.pool)
            .await?;
        }
    }

    Ok(true)
}

/// 确保文件夹链存在：如 "旅行/2024三亚" → 创建 "旅行" + "旅行/2024三亚"，返回叶子文件夹 ID
async fn ensure_folder_chain(
    pool: &PgPool,
    dir_path: &str,
    cache: &mut HashMap<String, Uuid>,
) -> anyhow::Result<Uuid> {
    let parts: Vec<&str> = dir_path.split('/').filter(|s| !s.is_empty()).collect();
    let mut parent_id: Option<Uuid> = None;
    let mut accumulated = String::new();

    for part in &parts {
        if !accumulated.is_empty() {
            accumulated.push('/');
        }
        accumulated.push_str(part);

        if let Some(&cached_id) = cache.get(&accumulated) {
            parent_id = Some(cached_id);
            continue;
        }

        let fs_name = crate::config::Config::sanitize_fs_name(part);

        // 先查后插：同一 parent + fs_name 不重复
        let existing: Option<(Uuid,)> = if let Some(pid) = parent_id {
            sqlx::query_as("SELECT id FROM folders WHERE parent_id = $1 AND fs_name = $2 AND is_deleted = FALSE")
                .bind(pid).bind(&fs_name).fetch_optional(pool).await?
        } else {
            sqlx::query_as("SELECT id FROM folders WHERE parent_id IS NULL AND fs_name = $1 AND is_deleted = FALSE")
                .bind(&fs_name).fetch_optional(pool).await?
        };

        let row_id = if let Some((id,)) = existing {
            id
        } else {
            let folder_id = Uuid::new_v4();
            sqlx::query(
                "INSERT INTO folders (id, name, fs_name, fs_path, parent_id) VALUES ($1, $2, $3, $4, $5)"
            )
            .bind(folder_id).bind(*part).bind(&fs_name).bind(&accumulated).bind(parent_id)
            .execute(pool).await?;
            folder_id
        };

        cache.insert(accumulated.clone(), row_id);
        parent_id = Some(row_id);
    }

    parent_id.ok_or_else(|| anyhow::anyhow!("空路径"))
}

/// 流式 SHA256（64KB chunk，不把文件读进内存）
async fn hash_file_streaming(path: &Path) -> anyhow::Result<(String, u64)> {
    let mut file = tokio::fs::File::open(path).await?;
    let mut hasher = Sha256::new();
    let mut buf = vec![0u8; 65536];
    let mut total: u64 = 0;
    loop {
        let n = file.read(&mut buf).await?;
        if n == 0 {
            break;
        }
        hasher.update(&buf[..n]);
        total += n as u64;
    }
    Ok((hex::encode(hasher.finalize()), total))
}

fn is_media_file(path: &Path) -> bool {
    // 跳过 macOS 资源分叉文件 ._ 和 .DS_Store
    if let Some(name) = path.file_name().and_then(|n| n.to_str()) {
        if name.starts_with("._") || name == ".DS_Store" {
            return false;
        }
    }
    path.extension()
        .and_then(|e| e.to_str())
        .map(|e| MEDIA_EXTENSIONS.contains(&e.to_ascii_lowercase().as_str()))
        .unwrap_or(false)
}

async fn mark_failed(pool: &PgPool, session_id: Uuid, error: &str) {
    let _ = sqlx::query(
        "UPDATE scan_sessions SET status='failed', last_error=$2, finished_at=NOW() WHERE id=$1",
    )
    .bind(session_id)
    .bind(error)
    .execute(pool)
    .await;
}
