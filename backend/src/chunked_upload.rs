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

const DEFAULT_CHUNK_SIZE: i32 = 5 * 1024 * 1024; // 5MB

// ============ Request / Response ============

#[derive(Deserialize)]
pub struct InitRequest {
    pub filename: String,
    pub file_size: i64,
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

    match sqlx::query(
        "INSERT INTO upload_sessions (id, filename, file_size, chunk_size) VALUES ($1, $2, $3, $4)",
    )
    .bind(session_id)
    .bind(&req.filename)
    .bind(req.file_size)
    .bind(DEFAULT_CHUNK_SIZE)
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

    let temp_path = state.cfg.temp_dir.join(format!("{}.part", upload_id));

    // 读取文件计算 hash 并入库
    let data = match tokio::fs::read(&temp_path).await {
        Ok(d) => d,
        Err(e) => return json_err(StatusCode::INTERNAL_SERVER_ERROR, format!("读取临时文件失败: {e}")).into_response(),
    };

    // 标记完成
    let _ = sqlx::query("UPDATE upload_sessions SET status = 'completed', updated_at = NOW() WHERE id = $1")
        .bind(upload_id)
        .execute(&state.pool)
        .await;

    // 删除临时文件
    let _ = tokio::fs::remove_file(&temp_path).await;

    // 走正常入库流程
    let bytes = axum::body::Bytes::from(data);
    match media::ingest_upload_bytes(&state, bytes, &session.filename, None, None).await {
        Ok(res) => (StatusCode::OK, Json(CompleteResponse {
            asset_id: res.asset.id,
            duplicate: res.deduped,
        })).into_response(),
        Err(e) => {
            tracing::error!("分片上传入库失败 [{}]: {:#}", session.filename, e);
            json_err(StatusCode::INTERNAL_SERVER_ERROR, e.to_string()).into_response()
        }
    }
}

// ============ Helpers ============

async fn get_session(pool: &PgPool, id: Uuid) -> anyhow::Result<Option<UploadSession>> {
    let row = sqlx::query_as::<_, UploadSession>(
        "SELECT id, filename, file_size, chunk_size, uploaded_bytes, status FROM upload_sessions WHERE id = $1",
    )
    .bind(id)
    .fetch_optional(pool)
    .await?;
    Ok(row)
}
