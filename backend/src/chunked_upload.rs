use axum::{
    body::Bytes,
    extract::{Path, State},
    http::StatusCode,
    response::{IntoResponse, Response},
    Json,
};
use serde::{Deserialize, Serialize};
use sqlx::PgPool;
use uuid::Uuid;

use crate::{api::json_err, db::AppState, media};

const DEFAULT_CHUNK_SIZE: i32 = 50 * 1024 * 1024; // 50MB — iPhone 内存友好

// ============ Request / Response ============

#[derive(Deserialize)]
pub struct InitRequest {
    pub filename: String,
    pub file_size: i64,
    pub shoot_at: Option<f64>,
}

#[derive(Serialize)]
pub struct InitResponse {
    pub upload_id: Uuid,
    pub chunk_size: i32,
}

#[derive(Serialize)]
pub struct OffsetResponse {
    pub upload_id: Uuid,
    pub offset: i64,
    pub total_size: i64,
}

#[derive(Serialize)]
pub struct CompleteResponse {
    pub asset_id: Uuid,
    pub duplicate: bool,
}

// ============ DB Row ============

#[derive(sqlx::FromRow)]
struct UploadSession {
    id: Uuid,
    filename: String,
    file_size: i64,
    chunk_size: i32,
    uploaded_bytes: i64,
    status: String,
    shoot_at: Option<chrono::NaiveDateTime>,
}

// ============ Handlers ============

/// POST /api/upload/init — 创建上传会话
pub async fn init_upload(
    State(state): State<AppState>,
    Json(req): Json<InitRequest>,
) -> Response {
    if req.filename.is_empty() || req.file_size <= 0 {
        return json_err(StatusCode::BAD_REQUEST, "filename 和 file_size 必填").into_response();
    }

    let session_id = Uuid::new_v4();

    // 创建临时文件
    let temp_path = state.cfg.temp_dir.join(format!("{}.part", session_id));
    if let Err(e) = tokio::fs::File::create(&temp_path).await {
        return json_err(StatusCode::INTERNAL_SERVER_ERROR, format!("创建临时文件失败: {e}")).into_response();
    }

    let shoot_at = req.shoot_at.and_then(|ts| {
        chrono::DateTime::from_timestamp(ts as i64, ((ts.fract()) * 1e9) as u32)
            .map(|dt| dt.naive_utc())
    });

    match sqlx::query(
        "INSERT INTO upload_sessions (id, filename, file_size, chunk_size, shoot_at) VALUES ($1, $2, $3, $4, $5)",
    )
    .bind(session_id)
    .bind(&req.filename)
    .bind(req.file_size)
    .bind(DEFAULT_CHUNK_SIZE)
    .bind(shoot_at)
    .execute(&state.pool)
    .await
    {
        Ok(_) => (StatusCode::OK, Json(InitResponse {
            upload_id: session_id,
            chunk_size: DEFAULT_CHUNK_SIZE,
        })).into_response(),
        Err(e) => json_err(StatusCode::INTERNAL_SERVER_ERROR, format!("创建会话失败: {e}")).into_response(),
    }
}

/// HEAD /api/upload/:id — 查询已上传字节数（断点续传）
pub async fn query_offset(
    State(state): State<AppState>,
    Path(upload_id): Path<Uuid>,
) -> Response {
    match get_session(&state.pool, upload_id).await {
        Ok(Some(s)) => (StatusCode::OK, Json(OffsetResponse {
            upload_id: s.id,
            offset: s.uploaded_bytes,
            total_size: s.file_size,
        })).into_response(),
        Ok(None) => json_err(StatusCode::NOT_FOUND, "上传会话不存在").into_response(),
        Err(e) => json_err(StatusCode::INTERNAL_SERVER_ERROR, e.to_string()).into_response(),
    }
}

/// PATCH /api/upload/:id — 追加分片
pub async fn upload_chunk(
    State(state): State<AppState>,
    Path(upload_id): Path<Uuid>,
    body: Bytes,
) -> Response {
    let session = match get_session(&state.pool, upload_id).await {
        Ok(Some(s)) => s,
        Ok(None) => return json_err(StatusCode::NOT_FOUND, "上传会话不存在").into_response(),
        Err(e) => return json_err(StatusCode::INTERNAL_SERVER_ERROR, e.to_string()).into_response(),
    };

    if session.status != "uploading" {
        return json_err(StatusCode::CONFLICT, "上传已完成或已过期").into_response();
    }

    // 追加写入临时文件
    let temp_path = state.cfg.temp_dir.join(format!("{}.part", upload_id));
    use tokio::io::AsyncWriteExt;
    let mut file = match tokio::fs::OpenOptions::new().append(true).open(&temp_path).await {
        Ok(f) => f,
        Err(e) => return json_err(StatusCode::INTERNAL_SERVER_ERROR, format!("打开临时文件失败: {e}")).into_response(),
    };

    if let Err(e) = file.write_all(&body).await {
        return json_err(StatusCode::INTERNAL_SERVER_ERROR, format!("写入分片失败: {e}")).into_response();
    }

    let chunk_len = body.len() as i64;

    // 校验：不允许超过 file_size
    if session.uploaded_bytes + chunk_len > session.file_size {
        return json_err(
            StatusCode::BAD_REQUEST,
            format!(
                "分片超出文件大小: uploaded={} + chunk={} > total={}",
                session.uploaded_bytes, chunk_len, session.file_size
            ),
        )
        .into_response();
    }

    // 原子更新 uploaded_bytes，避免并发竞态
    let new_offset: i64 = match sqlx::query_scalar::<_, i64>(
        "UPDATE upload_sessions SET uploaded_bytes = uploaded_bytes + $2, updated_at = NOW() WHERE id = $1 RETURNING uploaded_bytes",
    )
    .bind(upload_id)
    .bind(chunk_len)
    .fetch_one(&state.pool)
    .await
    {
        Ok(v) => v,
        Err(e) => return json_err(StatusCode::INTERNAL_SERVER_ERROR, format!("更新进度失败: {e}")).into_response(),
    };

    (StatusCode::OK, Json(OffsetResponse {
        upload_id,
        offset: new_offset,
        total_size: session.file_size,
    })).into_response()
}

/// POST /api/upload/:id/complete — 完成上传，触发入库
/// 大文件不读进内存：流式算 hash，直接 rename 到目标位置
pub async fn complete_upload(
    State(state): State<AppState>,
    Path(upload_id): Path<Uuid>,
) -> Response {
    let session = match get_session(&state.pool, upload_id).await {
        Ok(Some(s)) => s,
        Ok(None) => return json_err(StatusCode::NOT_FOUND, "上传会话不存在").into_response(),
        Err(e) => return json_err(StatusCode::INTERNAL_SERVER_ERROR, e.to_string()).into_response(),
    };

    if session.status != "uploading" {
        return json_err(StatusCode::CONFLICT, "上传已完成或已过期").into_response();
    }

    tracing::info!("分片上传 complete 开始: {} ({})", session.filename, upload_id);

    let temp_path = state.cfg.temp_dir.join(format!("{}.part", upload_id));

    // 先 rename 到目标位置（瞬间完成），hash 和去重放后台
    let safe_name = media::sanitize_filename_pub(&session.filename);
    let asset_id = Uuid::new_v4();
    let now = chrono::Utc::now();
    let (yyyy, mm) = (chrono::Datelike::year(&now), chrono::Datelike::month(&now));
    let raw_rel = format!("/raw/inbox/{:04}/{:02}/{}_{}", yyyy, mm, asset_id, safe_name);
    let raw_abs = state.cfg.resolve_under_root(&raw_rel);
    crate::config::Config::ensure_parent(&raw_abs).unwrap_or_default();

    if let Err(e) = tokio::fs::rename(&temp_path, &raw_abs).await {
        tracing::warn!("rename 失败，尝试 copy: {e}");
        if let Err(e2) = tokio::fs::copy(&temp_path, &raw_abs).await {
            return json_err(StatusCode::INTERNAL_SERVER_ERROR, format!("文件落盘失败: {e2}")).into_response();
        }
        let _ = tokio::fs::remove_file(&temp_path).await;
    }

    // 先用占位 hash 入库（后台 transcode job 会补算真实 hash）
    let placeholder_hash = format!("pending_{}", asset_id);
    let file_size = session.file_size;

    let new_asset = media::NewAsset {
        id: asset_id,
        filename: safe_name.clone(),
        file_path: raw_rel.clone(),
        proxy_path: None,
        thumb_path: None,
        file_hash: placeholder_hash,
        size_bytes: file_size,
        shoot_at: session.shoot_at,
        duration_sec: None,
        width: None,
        height: None,
        uploaded_by: None,
        head_hash: None,
        tail_hash: None,
    };

    if let Err(e) = crate::api::insert_asset_and_job(&state.pool, &new_asset).await {
        tracing::error!("分片上传入库失败 [{}]: {:#}", safe_name, e);
        return json_err(StatusCode::INTERNAL_SERVER_ERROR, e.to_string()).into_response();
    }

    let _ = sqlx::query("UPDATE upload_sessions SET status = 'completed', updated_at = NOW() WHERE id = $1")
        .bind(upload_id).execute(&state.pool).await;

    tracing::info!("分片上传入库成功: {} ({} MB)", safe_name, file_size / 1024 / 1024);

    // 后台算真实 hash + 首尾指纹（不阻塞响应）
    let pool = state.pool.clone();
    let raw_abs_bg = raw_abs.clone();
    tokio::spawn(async move {
        match stream_hash(&raw_abs_bg).await {
            Ok((real_hash, _)) => {
                // 检查去重
                let dup: Option<(Uuid,)> = sqlx::query_as(
                    "SELECT id FROM assets WHERE file_hash = $1 AND id != $2 AND is_deleted = FALSE LIMIT 1"
                )
                .bind(&real_hash)
                .bind(asset_id)
                .fetch_optional(&pool)
                .await
                .unwrap_or(None);

                if let Some((dup_id,)) = dup {
                    // 去重：删除刚入库的，保留旧的
                    tracing::info!("后台去重命中: {} -> 已有 {}", asset_id, dup_id);
                    let _ = sqlx::query("UPDATE assets SET is_deleted = TRUE WHERE id = $1")
                        .bind(asset_id).execute(&pool).await;
                    let _ = tokio::fs::remove_file(&raw_abs_bg).await;
                } else {
                    // 更新真实 hash + 首尾指纹
                    let ht = tokio::task::spawn_blocking({
                        let p = raw_abs_bg.clone();
                        move || media::compute_head_tail_hash_from_file(&p)
                    }).await;
                    let (head_hash, tail_hash) = match ht {
                        Ok(Ok(v)) => v,
                        _ => (String::new(), String::new()),
                    };

                    let _ = sqlx::query(
                        "UPDATE assets SET file_hash = $2, head_hash = $3, tail_hash = $4 WHERE id = $1"
                    )
                    .bind(asset_id).bind(&real_hash).bind(&head_hash).bind(&tail_hash)
                    .execute(&pool).await;
                }
            }
            Err(e) => tracing::warn!("后台 hash 失败 [{}]: {}", asset_id, e),
        }
    });

    (StatusCode::OK, Json(CompleteResponse {
        asset_id,
        duplicate: false,
    })).into_response()
}

/// 流式计算文件 SHA256（同步 I/O + 1MB buffer，避免 async 开销）
async fn stream_hash(path: &std::path::Path) -> anyhow::Result<(String, u64)> {
    let path = path.to_owned();
    tokio::task::spawn_blocking(move || {
        use sha2::{Digest, Sha256};
        use std::io::Read;
        let mut file = std::fs::File::open(&path)?;
        let mut hasher = Sha256::new();
        let mut buf = vec![0u8; 1024 * 1024]; // 1MB buffer
        let mut total: u64 = 0;
        loop {
            let n = file.read(&mut buf)?;
            if n == 0 { break; }
            hasher.update(&buf[..n]);
            total += n as u64;
        }
        Ok((hex::encode(hasher.finalize()), total))
    })
    .await?
}

// ============ Helpers ============

async fn get_session(pool: &PgPool, id: Uuid) -> anyhow::Result<Option<UploadSession>> {
    let row = sqlx::query_as::<_, UploadSession>(
        "SELECT id, filename, file_size, chunk_size, uploaded_bytes, status, shoot_at FROM upload_sessions WHERE id = $1",
    )
    .bind(id)
    .fetch_optional(pool)
    .await?;
    Ok(row)
}
