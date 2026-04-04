use bytes::Bytes;
use chrono::{Datelike, NaiveDateTime, Utc};
use sha2::{Digest, Sha256};
use sqlx::PgPool;
use tokio::io::AsyncWriteExt;
use uuid::Uuid;

use crate::{api, config::Config, db::AppState};

#[derive(Debug, Clone)]
pub struct NewAsset {
    pub id: Uuid,
    pub filename: String,
    pub file_path: String,
    pub proxy_path: Option<String>,
    pub thumb_path: Option<String>,
    pub file_hash: String,
    pub size_bytes: i64,
    pub shoot_at: Option<NaiveDateTime>,
    pub duration_sec: Option<i32>,
    pub width: Option<i32>,
    pub height: Option<i32>,
    pub uploaded_by: Option<String>,
}

#[derive(sqlx::FromRow)]
struct DedupRow {
    id: Uuid,
    filename: String,
    file_path: String,
    proxy_path: Option<String>,
    thumb_path: Option<String>,
    file_hash: String,
    size_bytes: i64,
    shoot_at: Option<NaiveDateTime>,
    created_at: Option<NaiveDateTime>,
    duration_sec: Option<i32>,
    width: Option<i32>,
    height: Option<i32>,
    is_deleted: bool,
}

#[derive(serde::Serialize)]
pub struct IngestResult {
    pub deduped: bool,
    pub asset: crate::api::AssetDto,
}

/// 从字节数据上传（用于已读取的 multipart 数据）
/// folder_id: 如果指定，直接落盘到 albums/<folder_fs_path>/ 下；否则落到 inbox/YYYY/MM/
pub async fn ingest_upload_bytes(
    state: &AppState, 
    data: Bytes, 
    orig_name: &str, 
    device_id: Option<&str>,
    folder_id: Option<Uuid>,
) -> anyhow::Result<IngestResult> {
    let now = Utc::now();
    let (yyyy, mm) = (now.year(), now.month());

    let safe_name = sanitize_filename(orig_name);
    let asset_id = Uuid::new_v4();

    // 根据 folder_id 决定落盘路径
    let (raw_rel, folder_fs_path) = if let Some(fid) = folder_id {
        // 查询文件夹的 fs_path
        let folder_path: Option<(Option<String>,)> = sqlx::query_as(
            "SELECT fs_path FROM folders WHERE id = $1 AND is_deleted = FALSE"
        )
        .bind(fid)
        .fetch_optional(&state.pool)
        .await?;
        
        match folder_path.and_then(|r| r.0) {
            Some(fs_path) => {
                let rel = format!("/raw/albums/{}/{}_{}", fs_path, asset_id, safe_name);
                (rel, Some(fs_path))
            }
            None => {
                // 文件夹不存在或无 fs_path，降级到 inbox
                tracing::warn!("文件夹 {} 不存在或无 fs_path，降级到 inbox", fid);
                let rel = format!("/raw/inbox/{:04}/{:02}/{}_{}", yyyy, mm, asset_id, safe_name);
                (rel, None)
            }
        }
    } else {
        // 无 folder_id，落到 inbox
        let rel = format!("/raw/inbox/{:04}/{:02}/{}_{}", yyyy, mm, asset_id, safe_name);
        (rel, None)
    };
    
    let raw_abs = state.cfg.resolve_under_root(&raw_rel);
    Config::ensure_parent(&raw_abs)?;

    let temp_abs = state
        .cfg
        .temp_dir
        .join(format!("{}.part", asset_id));

    let mut f = tokio::fs::File::create(&temp_abs).await?;
    let mut hasher = Sha256::new();
    
    hasher.update(&data);
    f.write_all(&data).await?;
    let size = data.len() as u64;
    f.flush().await?;

    let file_hash = hex::encode(hasher.finalize());

    // 1. 首先尝试 SHA256 哈希去重（对图片有效）
    if let Some(existing) = find_by_hash(&state.pool, &file_hash).await? {
        // 如果匹配记录已被软删除，恢复它
        if existing.is_deleted {
            sqlx::query("UPDATE assets SET is_deleted = FALSE WHERE id = $1")
                .bind(existing.id)
                .execute(&state.pool)
                .await?;
        }
        // 去重命中：清理临时文件
        let _ = tokio::fs::remove_file(&temp_abs).await;
        return Ok(IngestResult {
            deduped: true,
            asset: crate::api::AssetDto {
                id: existing.id,
                filename: existing.filename,
                file_path: existing.file_path,
                proxy_path: existing.proxy_path,
                thumb_path: existing.thumb_path,
                file_hash: existing.file_hash,
                size_bytes: existing.size_bytes,
                shoot_at: existing.shoot_at,
                created_at: existing.created_at,
                duration_sec: existing.duration_sec,
                width: existing.width,
                height: existing.height,
            },
        });
    }

    // 2. 对于视频文件，使用"文件大小+时长+分辨率"进行额外去重
    //    因为 iOS 每次导出视频会重新封装，SHA256 会变，但内容相同
    let ext = safe_name
        .rsplit('.')
        .next()
        .unwrap_or("")
        .to_ascii_lowercase();
    let is_video = matches!(ext.as_str(), "mp4" | "mov" | "avi" | "mkv" | "webm" | "m4v");

    if is_video {
        // 用 ffprobe 提取视频信息进行去重检查
        if let Ok(probe_info) = probe(&state.cfg, &temp_abs).await {
            if let Some(existing) = find_video_duplicate(
                &state.pool,
                size as i64,
                probe_info.duration_sec,
                probe_info.width,
                probe_info.height,
            )
            .await?
            {
                // 视频去重命中
                let _ = tokio::fs::remove_file(&temp_abs).await;
                tracing::info!(
                    "视频去重命中: size={}, dur={:?}, {}x{:?} -> existing={}",
                    size,
                    probe_info.duration_sec,
                    probe_info.width.unwrap_or(0),
                    probe_info.height,
                    existing.id
                );
                return Ok(IngestResult {
                    deduped: true,
                    asset: crate::api::AssetDto {
                        id: existing.id,
                        filename: existing.filename,
                        file_path: existing.file_path,
                        proxy_path: existing.proxy_path,
                        thumb_path: existing.thumb_path,
                        file_hash: existing.file_hash,
                        size_bytes: existing.size_bytes,
                        shoot_at: existing.shoot_at,
                        created_at: existing.created_at,
                        duration_sec: existing.duration_sec,
                        width: existing.width,
                        height: existing.height,
                    },
                });
            }
        }
    }

    // 落盘：rename 优先；跨设备则 copy
    if let Err(e) = tokio::fs::rename(&temp_abs, &raw_abs).await {
        tracing::warn!("rename 失败，将尝试 copy: {e}");
        tokio::fs::copy(&temp_abs, &raw_abs).await?;
        tokio::fs::remove_file(&temp_abs).await?;
    }

    // 同步生成一张缩略图（一期要求）
    let thumb_rel = format!("/proxies/{:04}/{:02}/{}_thumb.jpg", yyyy, mm, asset_id);
    let thumb_abs = state.cfg.resolve_under_root(&thumb_rel);
    Config::ensure_parent(&thumb_abs)?;
    let thumb_ok = crate::media::try_generate_thumbnail(&state.cfg, &raw_abs, &thumb_abs).await;
    if let Err(ref e) = thumb_ok {
        tracing::warn!(
            "缩略图生成失败（将继续上传但无预览图）: raw={}, thumb={}, err={}",
            raw_abs.display(),
            thumb_abs.display(),
            e
        );
    }
    let thumb_path = thumb_ok.ok().map(|_| thumb_rel.clone());

    let new_asset = NewAsset {
        id: asset_id,
        filename: safe_name,
        file_path: raw_rel,
        proxy_path: None,
        thumb_path,
        file_hash,
        size_bytes: size as i64,
        shoot_at: None,
        duration_sec: None,
        width: None,
        height: None,
        uploaded_by: device_id.map(|s| s.to_string()),
    };

    api::insert_asset_and_job(&state.pool, &new_asset).await?;

    // 如果指定了 folder_id 且成功解析到 fs_path，插入 asset_folders 关联
    if let Some(fid) = folder_id {
        if folder_fs_path.is_some() {
            sqlx::query(
                "INSERT INTO asset_folders (folder_id, asset_id, added_by) VALUES ($1, $2, $3) ON CONFLICT DO NOTHING"
            )
            .bind(fid)
            .bind(asset_id)
            .bind(device_id)
            .execute(&state.pool)
            .await?;
        }
    }

    let row = match find_by_id(&state.pool, asset_id).await? {
        Some(r) => r,
        None => anyhow::bail!("插入成功但未查询到 asset: id={asset_id}"),
    };
    Ok(IngestResult {
        deduped: false,
        asset: crate::api::AssetDto::from_row(row),
    })
}

fn sanitize_filename(name: &str) -> String {
    let mut out = String::with_capacity(name.len().min(180));
    for c in name.chars().take(180) {
        let ok = c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-' | ' ' | '(' | ')' );
        out.push(if ok { c } else { '_' });
    }
    let out = out.trim().trim_matches('.').to_string();
    if out.is_empty() { "upload.bin".to_string() } else { out }
}

async fn find_by_hash(pool: &PgPool, file_hash: &str) -> anyhow::Result<Option<DedupRow>> {
    let row = sqlx::query_as::<_, DedupRow>(
        r#"
        SELECT id, filename, file_path, proxy_path, thumb_path, file_hash, size_bytes,
               shoot_at, created_at, duration_sec, width, height, is_deleted
        FROM assets
        WHERE file_hash = $1
        LIMIT 1
        "#,
    )
    .bind(file_hash)
    .fetch_optional(pool)
    .await?;
    Ok(row)
}

/// 视频去重：通过文件大小+时长+分辨率判断是否重复
/// iOS 每次导出视频会修改元数据，导致 SHA256 不同，但内容相同
async fn find_video_duplicate(
    pool: &PgPool,
    size_bytes: i64,
    duration_sec: Option<i32>,
    width: Option<i32>,
    height: Option<i32>,
) -> anyhow::Result<Option<DedupRow>> {
    // 只有当 duration/width/height 都存在时才进行视频去重
    let Some(dur) = duration_sec else { return Ok(None) };
    let Some(w) = width else { return Ok(None) };
    let Some(h) = height else { return Ok(None) };

    let row = sqlx::query_as::<_, DedupRow>(
        r#"
        SELECT id, filename, file_path, proxy_path, thumb_path, file_hash, size_bytes,
               shoot_at, created_at, duration_sec, width, height, is_deleted
        FROM assets
        WHERE size_bytes = $1
          AND duration_sec = $2
          AND width = $3
          AND height = $4
          AND is_deleted = FALSE
        LIMIT 1
        "#,
    )
    .bind(size_bytes)
    .bind(dur)
    .bind(w)
    .bind(h)
    .fetch_optional(pool)
    .await?;
    Ok(row)
}

async fn find_by_id(pool: &PgPool, id: Uuid) -> anyhow::Result<Option<crate::api::AssetRow>> {
    let row = sqlx::query_as::<_, crate::api::AssetRow>(
        r#"
        SELECT id, filename, file_path, proxy_path, thumb_path, file_hash, size_bytes,
               shoot_at, created_at, duration_sec, width, height
        FROM assets
        WHERE id = $1
        "#,
    )
    .bind(id)
    .fetch_optional(pool)
    .await?;
    Ok(row)
}

pub async fn try_generate_thumbnail(cfg: &Config, input: &std::path::Path, output: &std::path::Path) -> anyhow::Result<()> {
    // 视频缩略图用 -ss 抽一帧；图片缩略图不能用 -ss（会跳过唯一帧，导致输出缺失）
    let ext = input
        .extension()
        .and_then(|s| s.to_str())
        .unwrap_or("")
        .to_ascii_lowercase();
    let is_video = matches!(ext.as_str(), "mp4" | "mov" | "avi" | "mkv" | "webm" | "m4v");

    let mut cmd = tokio::process::Command::new(&cfg.ffmpeg_bin);
    cmd.arg("-y")
        .arg("-hide_banner")
        .arg("-loglevel")
        .arg("error")
        // 某些素材（尤其是 MJPEG/YUV 相关）会报：
        // Non full-range YUV is non-standard, set strict_std_compliance to at most unofficial
        .arg("-strict")
        .arg("-2");

    if is_video {
        cmd.arg("-ss").arg("00:00:01");
    }

    cmd.arg("-i")
        .arg(input)
        .arg("-frames:v")
        .arg("1")
        // 缩略图下采样 + 强制像素格式，提升兼容性 & 减小体积
        .arg("-vf")
        .arg("scale=512:-2:flags=bicubic,format=yuvj420p")
        .arg("-q:v")
        .arg("2")
        .arg(output);

    let status = cmd.status().await?;

    if !status.success() {
        anyhow::bail!("ffmpeg 缩略图生成失败: exit={status}");
    }

    // 双重校验：ffmpeg 偶尔可能 exit=0 但未生成文件（尤其是图片输入 + -ss 之类的场景）
    let meta = tokio::fs::metadata(output).await?;
    if meta.len() == 0 {
        anyhow::bail!("ffmpeg 缩略图生成失败: 输出文件为空: {}", output.display());
    }
    Ok(())
}

#[derive(Debug, Clone)]
pub struct ProbeInfo {
    pub shoot_at: Option<NaiveDateTime>,
    pub duration_sec: Option<i32>,
    pub width: Option<i32>,
    pub height: Option<i32>,
}

pub async fn probe(cfg: &Config, input: &std::path::Path) -> anyhow::Result<ProbeInfo> {
    let out = tokio::process::Command::new(&cfg.ffprobe_bin)
        .arg("-v")
        .arg("quiet")
        .arg("-print_format")
        .arg("json")
        .arg("-show_format")
        .arg("-show_streams")
        .arg(input)
        .output()
        .await?;

    if !out.status.success() {
        anyhow::bail!("ffprobe 失败: exit={}", out.status);
    }

    let v: serde_json::Value = serde_json::from_slice(&out.stdout)?;
    let mut shoot_at: Option<NaiveDateTime> = None;
    let mut duration_sec: Option<i32> = None;
    let mut width: Option<i32> = None;
    let mut height: Option<i32> = None;

    if let Some(d) = v.pointer("/format/duration").and_then(|x| x.as_str()) {
        if let Ok(f) = d.parse::<f64>() {
            duration_sec = Some(f.round().clamp(0.0, i32::MAX as f64) as i32);
        }
    }

    if let Some(tags) = v.pointer("/format/tags") {
        shoot_at = parse_creation_time(tags);
    }

    if let Some(streams) = v.get("streams").and_then(|s| s.as_array()) {
        for s in streams {
            if s.get("codec_type").and_then(|x| x.as_str()) == Some("video") {
                width = s.get("width").and_then(|x| x.as_i64()).map(|x| x as i32);
                height = s.get("height").and_then(|x| x.as_i64()).map(|x| x as i32);
                if shoot_at.is_none() {
                    if let Some(tags) = s.get("tags") {
                        shoot_at = parse_creation_time(tags);
                    }
                }
                break;
            }
        }
    }

    Ok(ProbeInfo {
        shoot_at,
        duration_sec,
        width,
        height,
    })
}

fn parse_creation_time(tags: &serde_json::Value) -> Option<NaiveDateTime> {
    // ffprobe 常见字段：creation_time / com.apple.quicktime.creationdate 等
    let candidates = ["creation_time", "com.apple.quicktime.creationdate"];
    for k in candidates {
        if let Some(s) = tags.get(k).and_then(|x| x.as_str()) {
            if let Ok(dt) = chrono::DateTime::parse_from_rfc3339(s) {
                return Some(dt.naive_utc());
            }
            // 有些是 "2025-01-01 12:34:56" 这类
            if let Ok(dt) = NaiveDateTime::parse_from_str(s, "%Y-%m-%d %H:%M:%S") {
                return Some(dt);
            }
        }
    }
    None
}


