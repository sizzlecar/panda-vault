use axum::{
    extract::{Multipart, Path, Query, State},
    http::StatusCode,
    response::{IntoResponse, Response},
    routing::{get, post},
    Json, Router,
};
use chrono::{NaiveDate, NaiveDateTime};
use serde::{Deserialize, Serialize};
use sqlx::PgPool;
use uuid::Uuid;

use crate::{ai, db::AppState, folder, jobs, media, sync};
use axum::routing::{delete, put};

pub fn routes(state: AppState) -> Router {
    let proxies_dir = state.cfg.proxies_dir.clone();
    Router::new()
        .route("/api/health", get(health))
        .route("/api/upload", post(upload))
        .route("/api/assets/check-duplicate", post(check_duplicate))
        .route("/api/upload/init", post(crate::chunked_upload::init_upload))
        .route("/api/upload/:id", axum::routing::head(crate::chunked_upload::query_offset)
            .patch(crate::chunked_upload::upload_chunk)
            .get(crate::chunked_upload::query_offset))
        .route("/api/upload/:id/complete", post(crate::chunked_upload::complete_upload))
        .route("/api/assets", get(list_assets))
        // batch-delete 必须在 :id 之前，否则会被当作 id 参数
        .route("/api/assets/batch-delete", post(batch_delete_assets))
        .route("/api/assets/unassigned", get(list_unassigned_assets))
        .route(
            "/api/assets/:id",
            get(get_asset).put(update_asset).delete(delete_asset),
        )
        .route("/api/assets/:id/download", get(download_asset))
        .route("/api/timeline", get(timeline))
        // 第三阶段：语义搜索
        .route("/api/search/semantic", post(semantic_search))
        .route("/api/search/image", post(image_search))
        .route("/api/ai/health", get(ai_health))
        // 重试失败的 embedding 任务
        .route("/api/ai/retry-failed", post(retry_failed_embeddings))
        // 任务状态查询和修复
        .route("/api/jobs/status", get(jobs_status))
        .route("/api/jobs/fix-missing", post(fix_missing_embedding_jobs))
        // 同步任务
        .route("/api/sync/sessions", get(list_sync_sessions))
        .route("/api/sync/sessions", post(create_sync_session))
        .route("/api/sync/sessions/:id", get(get_sync_session))
        .route("/api/sync/sessions/:id/items", get(list_sync_items))
        .route("/api/sync/sessions/:id/retry", post(retry_sync_session))
        // 文件夹
        .route("/api/folders", get(list_folders))
        .route("/api/folders", post(create_folder))
        .route("/api/folders/:id", get(get_folder))
        .route("/api/folders/:id", put(update_folder))
        .route("/api/folders/:id", delete(delete_folder))
        .route("/api/folders/:id/assets", get(list_folder_assets))
        .route("/api/folders/:id/assets/:asset_id", post(add_asset_to_folder))
        .route("/api/folders/:id/assets/:asset_id", delete(remove_asset_from_folder))
        // 回收站
        .route("/api/assets/trash", get(list_trash))
        .route("/api/assets/restore", post(restore_assets))
        .route("/api/assets/trash/empty", post(empty_trash))
        // 存储卷管理
        .route("/api/volumes", get(list_volumes).post(create_volume))
        .route("/api/volumes/:id", get(get_volume_detail))
        // 目录扫描
        .route("/api/scan", post(start_scan))
        .route("/api/scan/sessions", get(list_scan_sessions_api))
        .route("/api/scan/:id", get(get_scan_session))
        // 客户端日志上报
        .route("/api/client-logs", post(crate::client_logs::ingest).get(crate::client_logs::browse))
        .nest_service(
            "/proxies",
            tower_http::services::ServeDir::new(proxies_dir).append_index_html_on_directories(false),
        )
        .nest_service(
            "/raw",
            tower_http::services::ServeDir::new(state.cfg.raw_dir.clone()).append_index_html_on_directories(false),
        )
        .with_state(state)
}

async fn health() -> impl IntoResponse {
    (StatusCode::OK, "ok")
}

#[derive(Serialize)]
pub struct ApiError {
    pub error: String,
}

pub fn json_err(status: StatusCode, msg: impl Into<String>) -> (StatusCode, Json<ApiError>) {
    (status, Json(ApiError { error: msg.into() }))
}

#[derive(Serialize)]
pub struct AssetDto {
    pub id: Uuid,
    pub filename: String,
    pub file_path: String,
    pub proxy_path: Option<String>,
    pub thumb_path: Option<String>,
    pub file_hash: String,
    pub size_bytes: i64,
    #[serde(serialize_with = "crate::timestamp::serialize_opt")]
    pub shoot_at: Option<NaiveDateTime>,
    #[serde(serialize_with = "crate::timestamp::serialize_opt")]
    pub created_at: Option<NaiveDateTime>,
    pub duration_sec: Option<i32>,
    pub width: Option<i32>,
    pub height: Option<i32>,
}


impl AssetDto {
    pub fn from_row(r: AssetRow) -> Self {
        Self {
            id: r.id,
            filename: r.filename,
            file_path: r.file_path,
            proxy_path: r.proxy_path,
            thumb_path: r.thumb_path,
            file_hash: r.file_hash,
            size_bytes: r.size_bytes,
            shoot_at: r.shoot_at,
            created_at: r.created_at,
            duration_sec: r.duration_sec,
            width: r.width,
            height: r.height,
        }
    }
}

#[derive(sqlx::FromRow)]
pub struct AssetRow {
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
    volume_id: Option<Uuid>,
}

// 一期：流式上传 -> 落盘 -> SHA256 去重 -> 缩略图 -> 入库
// 二期：入库后自动 enqueue 转码任务（后台 worker 处理）
async fn upload(
    State(state): State<AppState>,
    mut multipart: Multipart,
) -> Response {
    let mut device_id: Option<String> = None;
    let mut session_id: Option<Uuid> = None;
    let mut folder_id: Option<Uuid> = None;
    let mut shoot_at: Option<NaiveDateTime> = None;
    let mut file_data: Option<(String, bytes::Bytes)> = None;

    // 解析 multipart 字段
    while let Ok(Some(field)) = multipart.next_field().await {
        match field.name() {
            Some("file") => {
                let orig_name = field
                    .file_name()
                    .map(|s| s.to_string())
                    .unwrap_or_else(|| "upload.bin".to_string());
                match field.bytes().await {
                    Ok(bytes) => file_data = Some((orig_name, bytes)),
                    Err(e) => return json_err(StatusCode::BAD_REQUEST, format!("读取文件失败: {e}")).into_response(),
                }
            }
            Some("device_id") => {
                if let Ok(text) = field.text().await {
                    if !text.is_empty() {
                        device_id = Some(text);
                    }
                }
            }
            Some("session_id") => {
                if let Ok(text) = field.text().await {
                    if let Ok(id) = Uuid::parse_str(text.trim()) {
                        session_id = Some(id);
                    }
                }
            }
            Some("folder_id") => {
                if let Ok(text) = field.text().await {
                    if let Ok(id) = Uuid::parse_str(text.trim()) {
                        folder_id = Some(id);
                    }
                }
            }
            Some("shoot_at") => {
                if let Ok(text) = field.text().await {
                    if let Ok(ts) = text.trim().parse::<f64>() {
                        shoot_at = chrono::DateTime::from_timestamp(ts as i64, ((ts.fract()) * 1e9) as u32)
                            .map(|dt| dt.naive_utc());
                    }
                }
            }
            _ => {}
        }
    }

    let Some((orig_name, bytes)) = file_data else {
        return json_err(StatusCode::BAD_REQUEST, "缺少文件字段 file").into_response();
    };

    // 若绑定了同步会话，先标记为 uploading（用 bytes.len 作为 file_size 辅助匹配）
    if let Some(sid) = session_id {
        let _ = sync::update_item_status_by_file(
            &state.pool,
            sid,
            &orig_name,
            Some(bytes.len() as i64),
            "uploading",
            None,
            None,
        )
        .await;
    }

    let res = match media::ingest_upload_bytes(&state, bytes, &orig_name, device_id.as_deref(), folder_id, shoot_at).await {
        Ok(v) => v,
        Err(e) => {
            if let Some(sid) = session_id {
                let _ = sync::update_item_status_by_file(
                    &state.pool,
                    sid,
                    &orig_name,
                    None,
                    "failed",
                    None,
                    Some(&e.to_string()),
                )
                .await;
            }
            tracing::error!("上传失败 [{}]: {:#}", orig_name, e);
            return json_err(StatusCode::INTERNAL_SERVER_ERROR, e.to_string()).into_response();
        }
    };

    // 去重命中时：只添加文件夹关联（不移动文件），允许同一资产出现在多个文件夹
    if let Some(fid) = folder_id {
        if res.deduped {
            // 如果之前还没关联到该文件夹，才 +size
            let already: Option<(i64,)> = sqlx::query_as(
                "SELECT 1 FROM asset_folders WHERE folder_id = $1 AND asset_id = $2"
            )
            .bind(fid)
            .bind(res.asset.id)
            .fetch_optional(&state.pool)
            .await
            .unwrap_or(None);

            let _ = sqlx::query(
                "INSERT INTO asset_folders (folder_id, asset_id, added_by) VALUES ($1, $2, $3) ON CONFLICT DO NOTHING"
            )
            .bind(fid)
            .bind(res.asset.id)
            .bind(device_id.as_deref())
            .execute(&state.pool)
            .await;

            if already.is_none() {
                let _ = crate::folder::adjust_folder_ancestors(
                    &state.pool, Some(fid), res.asset.size_bytes, 1
                ).await;
            }
        }
    }

    // 更新同步项目状态
    if let Some(sid) = session_id {
        let status = if res.deduped { "skipped" } else { "succeeded" };
        let _ = sync::update_item_status_by_file(
            &state.pool,
            sid,
            &orig_name,
            None,
            status,
            Some(res.asset.id),
            None,
        )
        .await;
    }

    (StatusCode::OK, Json(res)).into_response()
}

#[derive(Deserialize)]
struct ListQuery {
    q: Option<String>,
    limit: Option<i64>,
    offset: Option<i64>,
    /// 按月筛选，格式 "2026-04"，匹配 COALESCE(shoot_at, created_at) 所在月份
    month: Option<String>,
}

/// 快速检查文件是否已存在（用 size + head_hash + tail_hash 三元组）
async fn check_duplicate(
    State(state): State<AppState>,
    Json(req): Json<CheckDuplicateRequest>,
) -> Response {
    let row: Option<(Uuid,)> = sqlx::query_as(
        "SELECT id FROM assets WHERE size_bytes = $1 AND head_hash = $2 AND tail_hash = $3 AND is_deleted = FALSE LIMIT 1",
    )
    .bind(req.size)
    .bind(&req.head_hash)
    .bind(&req.tail_hash)
    .fetch_optional(&state.pool)
    .await
    .unwrap_or(None);

    let (exists, asset_id) = match row {
        Some((id,)) => (true, Some(id)),
        None => (false, None),
    };

    (StatusCode::OK, Json(CheckDuplicateResponse { exists, asset_id })).into_response()
}

#[derive(Deserialize)]
struct CheckDuplicateRequest {
    size: i64,
    head_hash: String,
    tail_hash: String,
}

#[derive(Serialize)]
struct CheckDuplicateResponse {
    exists: bool,
    asset_id: Option<Uuid>,
}

async fn list_assets(
    State(state): State<AppState>,
    Query(q): Query<ListQuery>,
) -> Response {
    let limit = q.limit.unwrap_or(50).clamp(1, 500);
    let offset = q.offset.unwrap_or(0).max(0);

    // 解析 month 参数 "2026-04" → 月初和月末日期
    let month_range: Option<(NaiveDate, NaiveDate)> = q.month.as_ref().and_then(|m| {
        let parts: Vec<&str> = m.split('-').collect();
        if parts.len() != 2 { return None; }
        let y: i32 = parts[0].parse().ok()?;
        let m: u32 = parts[1].parse().ok()?;
        let start = NaiveDate::from_ymd_opt(y, m, 1)?;
        // 下个月 1 号（作为开区间上界）
        let end = if m == 12 {
            NaiveDate::from_ymd_opt(y + 1, 1, 1)?
        } else {
            NaiveDate::from_ymd_opt(y, m + 1, 1)?
        };
        Some((start, end))
    });

    let rows_res = match (&q.q, month_range) {
        // 文本搜索
        (Some(term), _) if !term.trim().is_empty() => {
            let like = format!("%{}%", term.trim());
            sqlx::query_as::<_, AssetRow>(
                r#"
                SELECT id, filename, file_path, proxy_path, thumb_path, file_hash, size_bytes,
                       shoot_at, created_at, duration_sec, width, height, volume_id
                FROM assets
                WHERE is_deleted = FALSE
                  AND (filename ILIKE $1 OR file_path ILIKE $1)
                ORDER BY COALESCE(shoot_at, created_at) DESC NULLS LAST
                LIMIT $2 OFFSET $3
                "#,
            )
            .bind(like)
            .bind(limit)
            .bind(offset)
            .fetch_all(&state.pool)
            .await
        }
        // 按月筛选
        (_, Some((month_start, month_end))) => {
            sqlx::query_as::<_, AssetRow>(
                r#"
                SELECT id, filename, file_path, proxy_path, thumb_path, file_hash, size_bytes,
                       shoot_at, created_at, duration_sec, width, height, volume_id
                FROM assets
                WHERE is_deleted = FALSE
                  AND COALESCE(shoot_at, created_at)::date >= $1
                  AND COALESCE(shoot_at, created_at)::date < $2
                ORDER BY COALESCE(shoot_at, created_at) DESC NULLS LAST
                LIMIT $3 OFFSET $4
                "#,
            )
            .bind(month_start)
            .bind(month_end)
            .bind(limit)
            .bind(offset)
            .fetch_all(&state.pool)
            .await
        }
        // 默认：全部
        _ => {
            sqlx::query_as::<_, AssetRow>(
                r#"
                SELECT id, filename, file_path, proxy_path, thumb_path, file_hash, size_bytes,
                       shoot_at, created_at, duration_sec, width, height, volume_id
                FROM assets
                WHERE is_deleted = FALSE
                ORDER BY COALESCE(shoot_at, created_at) DESC NULLS LAST
                LIMIT $1 OFFSET $2
                "#,
            )
            .bind(limit)
            .bind(offset)
            .fetch_all(&state.pool)
            .await
        }
    };
    let rows: Vec<AssetRow> = match rows_res {
        Ok(v) => v,
        Err(e) => return json_err(StatusCode::INTERNAL_SERVER_ERROR, e.to_string()).into_response(),
    };

    let out: Vec<AssetDto> = rows.into_iter().map(AssetDto::from_row).collect();
    (StatusCode::OK, Json(out)).into_response()
}

async fn list_unassigned_assets(
    State(state): State<AppState>,
    Query(q): Query<ListQuery>,
) -> Response {
    let limit = q.limit.unwrap_or(50).clamp(1, 200);
    let offset = q.offset.unwrap_or(0).max(0);

    let rows_res = match q.q {
        Some(term) if !term.trim().is_empty() => {
            let like = format!("%{}%", term.trim());
            sqlx::query_as::<_, AssetRow>(
                r#"
                SELECT a.id, a.filename, a.file_path, a.proxy_path, a.thumb_path, a.file_hash, a.size_bytes,
                       a.shoot_at, a.created_at, a.duration_sec, a.width, a.height, a.volume_id
                FROM assets a
                WHERE a.is_deleted = FALSE
                  AND NOT EXISTS (SELECT 1 FROM asset_folders af WHERE af.asset_id = a.id)
                  AND (a.filename ILIKE $1 OR a.file_path ILIKE $1)
                ORDER BY COALESCE(a.shoot_at, a.created_at) DESC NULLS LAST
                LIMIT $2 OFFSET $3
                "#,
            )
            .bind(like)
            .bind(limit)
            .bind(offset)
            .fetch_all(&state.pool)
            .await
        }
        _ => {
            sqlx::query_as::<_, AssetRow>(
                r#"
                SELECT a.id, a.filename, a.file_path, a.proxy_path, a.thumb_path, a.file_hash, a.size_bytes,
                       a.shoot_at, a.created_at, a.duration_sec, a.width, a.height, a.volume_id
                FROM assets a
                WHERE a.is_deleted = FALSE
                  AND NOT EXISTS (SELECT 1 FROM asset_folders af WHERE af.asset_id = a.id)
                ORDER BY COALESCE(a.shoot_at, a.created_at) DESC NULLS LAST
                LIMIT $1 OFFSET $2
                "#,
            )
            .bind(limit)
            .bind(offset)
            .fetch_all(&state.pool)
            .await
        }
    };

    let rows: Vec<AssetRow> = match rows_res {
        Ok(v) => v,
        Err(e) => return json_err(StatusCode::INTERNAL_SERVER_ERROR, e.to_string()).into_response(),
    };

    let out: Vec<AssetDto> = rows.into_iter().map(AssetDto::from_row).collect();
    (StatusCode::OK, Json(out)).into_response()
}

async fn get_asset(State(state): State<AppState>, Path(id): Path<Uuid>) -> Response {
    let row: Option<AssetRow> = match sqlx::query_as::<_, AssetRow>(
        r#"
        SELECT id, filename, file_path, proxy_path, thumb_path, file_hash, size_bytes,
               shoot_at, created_at, duration_sec, width, height, volume_id
        FROM assets
        WHERE id = $1 AND is_deleted = FALSE
        "#,
    )
    .bind(id)
    .fetch_optional(&state.pool)
    .await
    {
        Ok(v) => v,
        Err(e) => return json_err(StatusCode::INTERNAL_SERVER_ERROR, e.to_string()).into_response(),
    };

    match row {
        Some(r) => (StatusCode::OK, Json(AssetDto::from_row(r))).into_response(),
        None => json_err(StatusCode::NOT_FOUND, "asset 不存在").into_response(),
    }
}

async fn download_asset(State(state): State<AppState>, Path(id): Path<Uuid>) -> Response {
    let row: Option<AssetRow> = match sqlx::query_as::<_, AssetRow>(
        "SELECT id, filename, file_path, proxy_path, thumb_path, file_hash, size_bytes,
                shoot_at, created_at, duration_sec, width, height, volume_id
         FROM assets WHERE id = $1 AND is_deleted = FALSE",
    )
    .bind(id)
    .fetch_optional(&state.pool)
    .await
    {
        Ok(v) => v,
        Err(e) => return json_err(StatusCode::INTERNAL_SERVER_ERROR, format!("查询失败: {e}")).into_response(),
    };

    let Some(asset) = row else {
        return json_err(StatusCode::NOT_FOUND, "asset 不存在").into_response();
    };

    let abs_path = match state.volumes.resolve_asset_path(&asset.file_path, asset.volume_id).await {
        Ok(p) => p,
        Err(e) => return json_err(StatusCode::INTERNAL_SERVER_ERROR, format!("解析路径失败: {e}")).into_response(),
    };
    if !abs_path.exists() {
        return json_err(StatusCode::NOT_FOUND, "文件不存在").into_response();
    }

    // 读取文件，流式返回
    match tokio::fs::read(&abs_path).await {
        Ok(data) => {
            let content_type = mime_guess::from_path(&abs_path)
                .first_or_octet_stream()
                .to_string();
            match Response::builder()
                .status(StatusCode::OK)
                .header(axum::http::header::CONTENT_TYPE, content_type)
                .header(
                    axum::http::header::CONTENT_DISPOSITION,
                    format!("attachment; filename=\"{}\"", asset.filename),
                )
                .header(axum::http::header::CONTENT_LENGTH, data.len())
                .body(axum::body::Body::from(data))
            {
                Ok(resp) => resp,
                Err(e) => json_err(StatusCode::INTERNAL_SERVER_ERROR, format!("构建响应失败: {e}")).into_response(),
            }
        }
        Err(e) => json_err(StatusCode::INTERNAL_SERVER_ERROR, format!("读取文件失败: {e}")).into_response(),
    }
}

#[derive(Deserialize)]
struct UpdateAssetRequest {
    filename: Option<String>,
}

async fn update_asset(
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
    Json(req): Json<UpdateAssetRequest>,
) -> Response {
    let Some(filename) = req.filename.map(|s| s.trim().to_string()) else {
        return json_err(StatusCode::BAD_REQUEST, "缺少字段 filename").into_response();
    };
    if filename.is_empty() {
        return json_err(StatusCode::BAD_REQUEST, "filename 不能为空").into_response();
    }

    let updated = sqlx::query_as::<_, AssetRow>(
        r#"
        UPDATE assets
        SET filename = $2
        WHERE id = $1 AND is_deleted = FALSE
        RETURNING id, filename, file_path, proxy_path, thumb_path, file_hash, size_bytes,
                  shoot_at, created_at, duration_sec, width, height, volume_id
        "#,
    )
    .bind(id)
    .bind(filename)
    .fetch_optional(&state.pool)
    .await;

    match updated {
        Ok(Some(row)) => (StatusCode::OK, Json(AssetDto::from_row(row))).into_response(),
        Ok(None) => json_err(StatusCode::NOT_FOUND, "资产不存在").into_response(),
        Err(e) => json_err(StatusCode::INTERNAL_SERVER_ERROR, e.to_string()).into_response(),
    }
}

#[derive(Serialize)]
struct TimelineDay {
    day: NaiveDate,
    count: i64,
}

async fn timeline(State(state): State<AppState>) -> Response {
    let rows = match sqlx::query_as::<_, (NaiveDate, i64)>(
        r#"
        SELECT (date_trunc('day', COALESCE(shoot_at, created_at)))::date AS day,
               COUNT(*)::bigint AS count
        FROM assets
        WHERE is_deleted = FALSE
        GROUP BY day
        ORDER BY day DESC
        LIMIT 3650
        "#,
    )
    .fetch_all(&state.pool)
    .await
    {
        Ok(v) => v,
        Err(e) => return json_err(StatusCode::INTERNAL_SERVER_ERROR, e.to_string()).into_response(),
    };

    let out: Vec<TimelineDay> = rows
        .into_iter()
        .map(|(day, count)| TimelineDay { day, count })
        .collect();

    (StatusCode::OK, Json(out)).into_response()
}

// 供 ingest_upload 调用：插入资产与 job
pub async fn insert_asset_and_job(pool: &PgPool, asset: &media::NewAsset) -> anyhow::Result<()> {
    sqlx::query(
        r#"
        INSERT INTO assets (id, filename, file_path, proxy_path, thumb_path, file_hash, size_bytes, shoot_at, duration_sec, width, height, uploaded_by, head_hash, tail_hash)
        VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14)
        "#,
    )
    .bind(asset.id)
    .bind(&asset.filename)
    .bind(&asset.file_path)
    .bind(&asset.proxy_path)
    .bind(&asset.thumb_path)
    .bind(&asset.file_hash)
    .bind(asset.size_bytes)
    .bind(asset.shoot_at)
    .bind(asset.duration_sec)
    .bind(asset.width)
    .bind(asset.height)
    .bind(&asset.uploaded_by)
    .bind(&asset.head_hash)
    .bind(&asset.tail_hash)
    .execute(pool)
    .await?;

    jobs::enqueue_transcode_job(pool, asset.id).await?;
    Ok(())
}

// ============ 第三阶段：语义搜索 ============

#[derive(Deserialize)]
struct SemanticSearchQuery {
    text: String,
    limit: Option<i64>,
    /// 可选：限定在某个文件夹及其所有子文件夹内搜索
    folder_id: Option<Uuid>,
}

#[derive(Serialize)]
struct SemanticSearchResponse {
    results: Vec<SemanticSearchItem>,
}

#[derive(Serialize)]
struct SemanticSearchItem {
    asset: AssetDto,
    similarity: f64,
}

/// AI 健康检查
async fn ai_health(State(state): State<AppState>) -> Response {
    let Some(ref client) = state.ai_client else {
        return json_err(StatusCode::SERVICE_UNAVAILABLE, "AI 服务未配置").into_response();
    };

    match client.health().await {
        Ok(true) => (StatusCode::OK, Json(serde_json::json!({"status": "ok"}))).into_response(),
        Ok(false) => json_err(StatusCode::SERVICE_UNAVAILABLE, "AI 服务不可用").into_response(),
        Err(e) => json_err(StatusCode::SERVICE_UNAVAILABLE, format!("AI 服务错误: {e}")).into_response(),
    }
}

/// 重试失败的 embedding 任务
async fn retry_failed_embeddings(State(state): State<AppState>) -> Response {
    let result = sqlx::query(
        r#"
        UPDATE embedding_jobs
        SET status = 'pending',
            started_at = NULL,
            finished_at = NULL,
            last_error = NULL
        WHERE status = 'failed'
        "#,
    )
    .execute(&state.pool)
    .await;

    match result {
        Ok(r) => {
            let count = r.rows_affected();
            tracing::info!("重置 {} 个失败的 embedding 任务", count);
            (
                StatusCode::OK,
                Json(serde_json::json!({
                    "message": format!("已重置 {} 个失败的任务，将自动重新处理", count),
                    "count": count
                })),
            )
                .into_response()
        }
        Err(e) => json_err(StatusCode::INTERNAL_SERVER_ERROR, e.to_string()).into_response(),
    }
}

/// 语义搜索：输入自然语言，返回最相似的资产
async fn semantic_search(
    State(state): State<AppState>,
    Json(query): Json<SemanticSearchQuery>,
) -> Response {
    let Some(ref client) = state.ai_client else {
        return json_err(StatusCode::SERVICE_UNAVAILABLE, "AI 服务未配置").into_response();
    };

    if query.text.trim().is_empty() {
        return json_err(StatusCode::BAD_REQUEST, "搜索文本不能为空").into_response();
    }

    // 1. 将文本转换为向量
    let embedding = match client.embed_text(&query.text).await {
        Ok(v) => v,
        // 上游 AI 服务错误：对外更合理的语义是 Bad Gateway
        Err(e) => return json_err(StatusCode::BAD_GATEWAY, format!("文本向量化失败: {e}")).into_response(),
    };

    // 2. 在数据库中搜索相似向量（可选限定到某文件夹子树）
    let limit = query.limit.unwrap_or(20).clamp(1, 100);
    let search_results = match ai::semantic_search(&state.pool, &embedding, limit, query.folder_id).await {
        Ok(v) => v,
        Err(e) => return json_err(StatusCode::INTERNAL_SERVER_ERROR, format!("搜索失败: {e}")).into_response(),
    };

    if search_results.is_empty() {
        return (StatusCode::OK, Json(SemanticSearchResponse { results: vec![] })).into_response();
    }

    // 3. 批量查询资产详情
    let asset_ids: Vec<Uuid> = search_results.iter().map(|r| r.asset_id).collect();
    let rows = match sqlx::query_as::<_, AssetRow>(
        r#"
        SELECT id, filename, file_path, proxy_path, thumb_path, file_hash, size_bytes,
               shoot_at, created_at, duration_sec, width, height, volume_id
        FROM assets
        WHERE id = ANY($1)
        "#,
    )
    .bind(&asset_ids)
    .fetch_all(&state.pool)
    .await
    {
        Ok(v) => v,
        Err(e) => return json_err(StatusCode::INTERNAL_SERVER_ERROR, e.to_string()).into_response(),
    };

    // 4. 组装结果（保持相似度排序）
    let asset_map: std::collections::HashMap<Uuid, AssetRow> = rows.into_iter().map(|r| (r.id, r)).collect();
    // 过滤低相似度结果，避免返回不相关内容
    let min_similarity = 0.35;
    let results: Vec<SemanticSearchItem> = search_results
        .into_iter()
        .filter(|sr| sr.similarity >= min_similarity)
        .filter_map(|sr| {
            asset_map.get(&sr.asset_id).map(|row| SemanticSearchItem {
                asset: AssetDto::from_row(AssetRow {
                    id: row.id,
                    filename: row.filename.clone(),
                    file_path: row.file_path.clone(),
                    proxy_path: row.proxy_path.clone(),
                    thumb_path: row.thumb_path.clone(),
                    file_hash: row.file_hash.clone(),
                    size_bytes: row.size_bytes,
                    shoot_at: row.shoot_at,
                    created_at: row.created_at,
                    duration_sec: row.duration_sec,
                    width: row.width,
                    height: row.height,
                    volume_id: row.volume_id,
                }),
                similarity: sr.similarity,
            })
        })
        .collect();

    (StatusCode::OK, Json(SemanticSearchResponse { results })).into_response()
}

/// 以图搜图：上传图片 → embedding → 搜索相似素材
async fn image_search(
    State(state): State<AppState>,
    mut multipart: Multipart,
) -> Response {
    let Some(ref client) = state.ai_client else {
        return json_err(StatusCode::SERVICE_UNAVAILABLE, "AI 服务未配置").into_response();
    };

    // 读取上传的图片
    let mut file_data: Option<bytes::Bytes> = None;
    while let Ok(Some(field)) = multipart.next_field().await {
        if field.name() == Some("file") {
            if let Ok(bytes) = field.bytes().await {
                file_data = Some(bytes);
            }
        }
    }

    let Some(data) = file_data else {
        return json_err(StatusCode::BAD_REQUEST, "缺少图片文件").into_response();
    };

    // 保存临时文件给 ferrum 读取
    let temp_path = state.cfg.temp_dir.join(format!("search_{}.jpg", uuid::Uuid::new_v4()));
    if let Err(e) = tokio::fs::write(&temp_path, &data).await {
        return json_err(StatusCode::INTERNAL_SERVER_ERROR, format!("保存临时文件失败: {e}")).into_response();
    }
    let temp_path_str = temp_path.to_string_lossy().to_string();

    // 获取图片 embedding
    let embedding = match client.embed_image_path(&temp_path_str).await {
        Ok(v) => v,
        Err(e) => {
            let _ = tokio::fs::remove_file(&temp_path).await;
            return json_err(StatusCode::BAD_GATEWAY, format!("图片向量化失败: {e}")).into_response();
        }
    };
    let _ = tokio::fs::remove_file(&temp_path).await;

    // 搜索相似
    let limit = 20i64;
    let min_similarity = 0.35;
    let search_results = match ai::semantic_search(&state.pool, &embedding, limit, None).await {
        Ok(v) => v,
        Err(e) => return json_err(StatusCode::INTERNAL_SERVER_ERROR, format!("搜索失败: {e}")).into_response(),
    };

    if search_results.is_empty() {
        return (StatusCode::OK, Json(SemanticSearchResponse { results: vec![] })).into_response();
    }

    let asset_ids: Vec<Uuid> = search_results.iter().map(|r| r.asset_id).collect();
    let rows = match sqlx::query_as::<_, AssetRow>(
        "SELECT id, filename, file_path, proxy_path, thumb_path, file_hash, size_bytes,
                shoot_at, created_at, duration_sec, width, height, volume_id
         FROM assets WHERE id = ANY($1)",
    )
    .bind(&asset_ids)
    .fetch_all(&state.pool)
    .await
    {
        Ok(v) => v,
        Err(e) => return json_err(StatusCode::INTERNAL_SERVER_ERROR, e.to_string()).into_response(),
    };

    let asset_map: std::collections::HashMap<Uuid, AssetRow> = rows.into_iter().map(|r| (r.id, r)).collect();
    let results: Vec<SemanticSearchItem> = search_results
        .into_iter()
        .filter(|sr| sr.similarity >= min_similarity)
        .filter_map(|sr| {
            asset_map.get(&sr.asset_id).map(|row| SemanticSearchItem {
                asset: AssetDto::from_row(AssetRow {
                    id: row.id,
                    filename: row.filename.clone(),
                    file_path: row.file_path.clone(),
                    proxy_path: row.proxy_path.clone(),
                    thumb_path: row.thumb_path.clone(),
                    file_hash: row.file_hash.clone(),
                    size_bytes: row.size_bytes,
                    shoot_at: row.shoot_at,
                    created_at: row.created_at,
                    duration_sec: row.duration_sec,
                    width: row.width,
                    height: row.height,
                    volume_id: row.volume_id,
                }),
                similarity: sr.similarity,
            })
        })
        .collect();

    (StatusCode::OK, Json(SemanticSearchResponse { results })).into_response()
}

/// 任务状态统计
#[derive(Serialize)]
struct JobsStatusResponse {
    total_assets: i64,
    transcode_pending: i64,
    transcode_running: i64,
    transcode_succeeded: i64,
    transcode_failed: i64,
    embedding_pending: i64,
    embedding_running: i64,
    embedding_succeeded: i64,
    embedding_failed: i64,
    assets_with_embedding: i64,
    // 诊断信息
    embedding_jobs_without_data: i64,  // 有 succeeded job 但没有实际 embedding 数据
}

async fn jobs_status(State(state): State<AppState>) -> Response {
    let stats: Result<JobsStatusResponse, _> = async {
        let total_assets: (i64,) = sqlx::query_as("SELECT COUNT(*) FROM assets WHERE is_deleted = FALSE")
            .fetch_one(&state.pool).await?;
        
        let transcode_stats: Vec<(String, i64)> = sqlx::query_as(
            "SELECT status::text, COUNT(*) FROM transcode_jobs GROUP BY status"
        ).fetch_all(&state.pool).await?;
        
        let embedding_stats: Vec<(String, i64)> = sqlx::query_as(
            "SELECT status::text, COUNT(*) FROM embedding_jobs GROUP BY status"
        ).fetch_all(&state.pool).await?;
        
        let assets_with_embedding: (i64,) = sqlx::query_as(
            "SELECT COUNT(*) FROM asset_embeddings"
        ).fetch_one(&state.pool).await?;
        
        // 有 succeeded job 但没有实际 embedding 数据的数量
        let jobs_without_data: (i64,) = sqlx::query_as(
            r#"
            SELECT COUNT(*) FROM embedding_jobs ej
            WHERE ej.status = 'succeeded'
            AND NOT EXISTS (SELECT 1 FROM asset_embeddings ae WHERE ae.asset_id = ej.asset_id)
            "#
        ).fetch_one(&state.pool).await?;
        
        let mut resp = JobsStatusResponse {
            total_assets: total_assets.0,
            transcode_pending: 0,
            transcode_running: 0,
            transcode_succeeded: 0,
            transcode_failed: 0,
            embedding_pending: 0,
            embedding_running: 0,
            embedding_succeeded: 0,
            embedding_failed: 0,
            assets_with_embedding: assets_with_embedding.0,
            embedding_jobs_without_data: jobs_without_data.0,
        };
        
        for (status, count) in transcode_stats {
            match status.as_str() {
                "pending" => resp.transcode_pending = count,
                "running" => resp.transcode_running = count,
                "succeeded" => resp.transcode_succeeded = count,
                "failed" => resp.transcode_failed = count,
                _ => {}
            }
        }
        
        for (status, count) in embedding_stats {
            match status.as_str() {
                "pending" => resp.embedding_pending = count,
                "running" => resp.embedding_running = count,
                "succeeded" => resp.embedding_succeeded = count,
                "failed" => resp.embedding_failed = count,
                _ => {}
            }
        }
        
        Ok::<_, sqlx::Error>(resp)
    }.await;
    
    match stats {
        Ok(s) => (StatusCode::OK, Json(s)).into_response(),
        Err(e) => json_err(StatusCode::INTERNAL_SERVER_ERROR, e.to_string()).into_response(),
    }
}

/// 修复缺失的 embedding 任务
async fn fix_missing_embedding_jobs(State(state): State<AppState>) -> Response {
    let result = jobs::fix_missing_embedding_jobs_api(&state.pool).await;
    match result {
        Ok(count) => (StatusCode::OK, Json(serde_json::json!({
            "count": count,
            "message": format!("已为 {} 个资产创建 embedding 任务", count)
        }))).into_response(),
        Err(e) => json_err(StatusCode::INTERNAL_SERVER_ERROR, e.to_string()).into_response(),
    }
}

// ============ 资产删除 ============

#[derive(Deserialize)]
struct DeleteAssetQuery {
    device_id: Option<String>,
}

async fn delete_asset(
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
    Query(query): Query<DeleteAssetQuery>,
) -> Response {
    // 先拿 size 和归属文件夹，以便更新 total_bytes
    let size_row: Option<(i64,)> = sqlx::query_as(
        "SELECT size_bytes FROM assets WHERE id = $1 AND is_deleted = FALSE"
    )
    .bind(id)
    .fetch_optional(&state.pool)
    .await
    .unwrap_or(None);
    let folder_ids = crate::folder::folders_of_asset(&state.pool, id).await.unwrap_or_default();

    let result = sqlx::query(
        r#"
        UPDATE assets
        SET is_deleted = TRUE, deleted_at = NOW(), deleted_by = $2
        WHERE id = $1
        "#,
    )
    .bind(id)
    .bind(&query.device_id)
    .execute(&state.pool)
    .await;

    match result {
        Ok(r) if r.rows_affected() > 0 => {
            if let Some((size,)) = size_row {
                for fid in folder_ids {
                    let _ = crate::folder::adjust_folder_ancestors(&state.pool, Some(fid), -size, -1).await;
                }
            }
            (StatusCode::OK, Json(serde_json::json!({"deleted": true}))).into_response()
        }
        Ok(_) => json_err(StatusCode::NOT_FOUND, "资产不存在").into_response(),
        Err(e) => json_err(StatusCode::INTERNAL_SERVER_ERROR, e.to_string()).into_response(),
    }
}

#[derive(Deserialize)]
struct BatchDeleteRequest {
    ids: Vec<Uuid>,
    device_id: Option<String>,
}

async fn batch_delete_assets(
    State(state): State<AppState>,
    Json(req): Json<BatchDeleteRequest>,
) -> Response {
    if req.ids.is_empty() {
        return json_err(StatusCode::BAD_REQUEST, "ids 不能为空").into_response();
    }

    // 先拿每个待删资产的 size 和所属 folder，用于更新 total_bytes
    let pairs: Vec<(Uuid, i64)> = sqlx::query_as(
        "SELECT a.id, a.size_bytes FROM assets a WHERE a.id = ANY($1) AND a.is_deleted = FALSE"
    )
    .bind(&req.ids)
    .fetch_all(&state.pool)
    .await
    .unwrap_or_default();

    let asset_folders_map: Vec<(Uuid, Uuid)> = sqlx::query_as(
        "SELECT asset_id, folder_id FROM asset_folders WHERE asset_id = ANY($1)"
    )
    .bind(&req.ids)
    .fetch_all(&state.pool)
    .await
    .unwrap_or_default();

    let result = sqlx::query(
        r#"
        UPDATE assets
        SET is_deleted = TRUE, deleted_at = NOW(), deleted_by = $2
        WHERE id = ANY($1) AND is_deleted = FALSE
        "#,
    )
    .bind(&req.ids)
    .bind(&req.device_id)
    .execute(&state.pool)
    .await;

    match result {
        Ok(r) => {
            // 扣减每个被删资产在其所属文件夹（含祖先）的 total_bytes
            use std::collections::HashMap;
            let size_map: HashMap<Uuid, i64> = pairs.into_iter().collect();
            for (aid, fid) in asset_folders_map {
                if let Some(size) = size_map.get(&aid) {
                    let _ = crate::folder::adjust_folder_ancestors(&state.pool, Some(fid), -*size, -1).await;
                }
            }
            (StatusCode::OK, Json(serde_json::json!({
                "deleted": r.rows_affected(),
                "requested": req.ids.len()
            }))).into_response()
        }
        Err(e) => json_err(StatusCode::INTERNAL_SERVER_ERROR, e.to_string()).into_response(),
    }
}

// ============ 回收站 ============

#[derive(Deserialize)]
struct TrashQuery {
    limit: Option<i64>,
    offset: Option<i64>,
}

/// GET /api/assets/trash — 列出已删除资产
async fn list_trash(
    State(state): State<AppState>,
    Query(q): Query<TrashQuery>,
) -> Response {
    let limit = q.limit.unwrap_or(200).clamp(1, 500);
    let offset = q.offset.unwrap_or(0).max(0);

    let rows = sqlx::query_as::<_, TrashRow>(
        r#"
        SELECT id, filename, file_path, proxy_path, thumb_path, file_hash, size_bytes,
               shoot_at, created_at, duration_sec, width, height, deleted_at
        FROM assets
        WHERE is_deleted = TRUE
        ORDER BY deleted_at DESC
        LIMIT $1 OFFSET $2
        "#,
    )
    .bind(limit)
    .bind(offset)
    .fetch_all(&state.pool)
    .await;

    match rows {
        Ok(rows) => {
            let items: Vec<_> = rows.into_iter().map(|r| serde_json::json!({
                "id": r.id,
                "filename": r.filename,
                "file_path": r.file_path,
                "proxy_path": r.proxy_path,
                "thumb_path": r.thumb_path,
                "file_hash": r.file_hash,
                "size_bytes": r.size_bytes,
                "shoot_at": r.shoot_at.map(|d| d.and_utc().timestamp() as f64),
                "created_at": r.created_at.map(|d| d.and_utc().timestamp() as f64),
                "duration_sec": r.duration_sec,
                "width": r.width,
                "height": r.height,
                "deleted_at": r.deleted_at.map(|d| d.and_utc().timestamp() as f64),
            })).collect();
            (StatusCode::OK, Json(items)).into_response()
        }
        Err(e) => json_err(StatusCode::INTERNAL_SERVER_ERROR, e.to_string()).into_response(),
    }
}

#[derive(sqlx::FromRow)]
struct TrashRow {
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
    deleted_at: Option<NaiveDateTime>,
}

/// POST /api/assets/restore — 恢复已删除资产
async fn restore_assets(
    State(state): State<AppState>,
    Json(req): Json<BatchDeleteRequest>,
) -> Response {
    if req.ids.is_empty() {
        return json_err(StatusCode::BAD_REQUEST, "ids 不能为空").into_response();
    }
    let result = sqlx::query(
        "UPDATE assets SET is_deleted = FALSE, deleted_at = NULL, deleted_by = NULL WHERE id = ANY($1) AND is_deleted = TRUE",
    )
    .bind(&req.ids)
    .execute(&state.pool)
    .await;

    match result {
        Ok(r) => (StatusCode::OK, Json(serde_json::json!({
            "restored": r.rows_affected()
        }))).into_response(),
        Err(e) => json_err(StatusCode::INTERNAL_SERVER_ERROR, e.to_string()).into_response(),
    }
}

/// POST /api/assets/trash/empty — 永久删除（清理文件 + DB 记录）
async fn empty_trash(
    State(state): State<AppState>,
    Json(req): Json<EmptyTrashRequest>,
) -> Response {
    // 获取要删除的资产
    let rows: Vec<TrashFileRow> = if req.ids.is_empty() {
        // 不传 ids → 删除所有已过期（7天）的
        sqlx::query_as(
            r#"SELECT id, file_path, proxy_path, thumb_path, volume_id
               FROM assets WHERE is_deleted = TRUE AND deleted_at < NOW() - INTERVAL '7 days'"#,
        )
        .fetch_all(&state.pool)
        .await
        .unwrap_or_default()
    } else {
        sqlx::query_as(
            "SELECT id, file_path, proxy_path, thumb_path, volume_id FROM assets WHERE id = ANY($1) AND is_deleted = TRUE",
        )
        .bind(&req.ids)
        .fetch_all(&state.pool)
        .await
        .unwrap_or_default()
    };

    if rows.is_empty() {
        return (StatusCode::OK, Json(serde_json::json!({"deleted": 0}))).into_response();
    }

    let ids: Vec<Uuid> = rows.iter().map(|r| r.id).collect();

    // 删除磁盘文件
    for row in &rows {
        let raw_abs = state.volumes.resolve_asset_path(&row.file_path, row.volume_id).await
            .unwrap_or_else(|_| state.cfg.resolve_under_root(&row.file_path));
        let _ = tokio::fs::remove_file(&raw_abs).await;
        if let Some(ref p) = row.proxy_path {
            let _ = tokio::fs::remove_file(state.cfg.resolve_under_root(p)).await;
        }
        if let Some(ref p) = row.thumb_path {
            let _ = tokio::fs::remove_file(state.cfg.resolve_under_root(p)).await;
        }
    }

    // 级联删除 DB 记录
    let _ = sqlx::query("DELETE FROM asset_embeddings WHERE asset_id = ANY($1)").bind(&ids).execute(&state.pool).await;
    let _ = sqlx::query("DELETE FROM embedding_jobs WHERE asset_id = ANY($1)").bind(&ids).execute(&state.pool).await;
    let _ = sqlx::query("DELETE FROM transcode_jobs WHERE asset_id = ANY($1)").bind(&ids).execute(&state.pool).await;
    let _ = sqlx::query("DELETE FROM asset_folders WHERE asset_id = ANY($1)").bind(&ids).execute(&state.pool).await;
    let result = sqlx::query("DELETE FROM assets WHERE id = ANY($1)").bind(&ids).execute(&state.pool).await;

    match result {
        Ok(r) => (StatusCode::OK, Json(serde_json::json!({"deleted": r.rows_affected()}))).into_response(),
        Err(e) => json_err(StatusCode::INTERNAL_SERVER_ERROR, e.to_string()).into_response(),
    }
}

#[derive(Deserialize)]
struct EmptyTrashRequest {
    #[serde(default)]
    ids: Vec<Uuid>,
}

#[derive(sqlx::FromRow)]
struct TrashFileRow {
    id: Uuid,
    file_path: String,
    proxy_path: Option<String>,
    thumb_path: Option<String>,
    volume_id: Option<Uuid>,
}

// ============ 同步任务 ============

#[derive(Deserialize)]
struct ListSessionsQuery {
    device_id: Option<String>,
    limit: Option<i64>,
    offset: Option<i64>,
}

async fn list_sync_sessions(
    State(state): State<AppState>,
    Query(query): Query<ListSessionsQuery>,
) -> Response {
    let limit = query.limit.unwrap_or(20).clamp(1, 100);
    let offset = query.offset.unwrap_or(0);
    
    match sync::list_sessions(&state.pool, query.device_id.as_deref(), limit, offset).await {
        Ok(sessions) => (StatusCode::OK, Json(sessions)).into_response(),
        Err(e) => json_err(StatusCode::INTERNAL_SERVER_ERROR, e.to_string()).into_response(),
    }
}

async fn create_sync_session(
    State(state): State<AppState>,
    Json(req): Json<sync::CreateSessionRequest>,
) -> Response {
    match sync::create_session(&state.pool, req).await {
        Ok(session) => (StatusCode::CREATED, Json(session)).into_response(),
        Err(e) => json_err(StatusCode::INTERNAL_SERVER_ERROR, e.to_string()).into_response(),
    }
}

async fn get_sync_session(
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
) -> Response {
    match sync::get_session(&state.pool, id).await {
        Ok(session) => (StatusCode::OK, Json(session)).into_response(),
        Err(e) => json_err(StatusCode::NOT_FOUND, e.to_string()).into_response(),
    }
}

async fn list_sync_items(
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
) -> Response {
    match sync::list_session_items(&state.pool, id).await {
        Ok(items) => (StatusCode::OK, Json(items)).into_response(),
        Err(e) => json_err(StatusCode::INTERNAL_SERVER_ERROR, e.to_string()).into_response(),
    }
}

async fn retry_sync_session(
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
) -> Response {
    match sync::retry_failed_items(&state.pool, id).await {
        Ok(count) => (StatusCode::OK, Json(serde_json::json!({
            "retried": count,
            "message": format!("已重置 {} 个失败的项目", count)
        }))).into_response(),
        Err(e) => json_err(StatusCode::INTERNAL_SERVER_ERROR, e.to_string()).into_response(),
    }
}

// ============ 文件夹 ============

#[derive(Deserialize)]
struct ListFoldersQuery {
    parent_id: Option<Uuid>,
}

// 兼容：`total_bytes IS NULL` 视为"旧数据尚未算过"，首次访问时异步跑一次全量 recompute
// 用原子标记去重，避免并发时反复 spawn
static RECOMPUTE_IN_PROGRESS: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

async fn list_folders(
    State(state): State<AppState>,
    Query(query): Query<ListFoldersQuery>,
) -> Response {
    match folder::list_folders(&state.pool, query.parent_id).await {
        Ok(folders) => {
            // 懒触发：有任一 NULL（bytes 或 count）且当前没有其他 recompute 在跑，就 spawn 一次
            let has_null = folders.iter().any(|f| f.total_bytes.is_none() || f.asset_count.is_none());
            if has_null {
                use std::sync::atomic::Ordering;
                if RECOMPUTE_IN_PROGRESS
                    .compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst)
                    .is_ok()
                {
                    let pool = state.pool.clone();
                    tokio::spawn(async move {
                        match folder::recompute_all_folder_sizes(&pool).await {
                            Ok(n) => tracing::info!("folder.total_bytes 异步校准: 更新 {} 行", n),
                            Err(e) => tracing::warn!("folder.total_bytes 校准失败: {e}"),
                        }
                        RECOMPUTE_IN_PROGRESS.store(false, Ordering::SeqCst);
                    });
                }
            }
            (StatusCode::OK, Json(folders)).into_response()
        }
        Err(e) => json_err(StatusCode::INTERNAL_SERVER_ERROR, e.to_string()).into_response(),
    }
}

async fn create_folder(
    State(state): State<AppState>,
    Json(req): Json<folder::CreateFolderRequest>,
) -> Response {
    match folder::create_folder(&state.pool, &state.cfg, req).await {
        Ok(f) => (StatusCode::CREATED, Json(f)).into_response(),
        Err(e) => {
            let msg = e.to_string();
            let status = if msg.contains("同名文件夹已存在") {
                StatusCode::CONFLICT
            } else {
                StatusCode::INTERNAL_SERVER_ERROR
            };
            json_err(status, msg).into_response()
        }
    }
}

async fn get_folder(
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
) -> Response {
    match folder::get_folder(&state.pool, id).await {
        Ok(f) => (StatusCode::OK, Json(f)).into_response(),
        Err(e) => json_err(StatusCode::NOT_FOUND, e.to_string()).into_response(),
    }
}

async fn update_folder(
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
    Json(req): Json<folder::UpdateFolderRequest>,
) -> Response {
    match folder::update_folder(&state.pool, id, req).await {
        Ok(f) => (StatusCode::OK, Json(f)).into_response(),
        Err(e) => json_err(StatusCode::INTERNAL_SERVER_ERROR, e.to_string()).into_response(),
    }
}

async fn delete_folder(
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
) -> Response {
    match folder::delete_folder(&state.pool, id).await {
        Ok(()) => (StatusCode::OK, Json(serde_json::json!({"deleted": true}))).into_response(),
        Err(e) => json_err(StatusCode::INTERNAL_SERVER_ERROR, e.to_string()).into_response(),
    }
}

#[derive(Deserialize)]
struct ListFolderAssetsQuery {
    limit: Option<i64>,
    offset: Option<i64>,
    q: Option<String>,
}

async fn list_folder_assets(
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
    Query(query): Query<ListFolderAssetsQuery>,
) -> Response {
    let limit = query.limit.unwrap_or(50).clamp(1, 200);
    let offset = query.offset.unwrap_or(0);

    match folder::list_folder_assets(&state.pool, id, query.q.as_deref(), limit, offset).await {
        Ok(assets) => (StatusCode::OK, Json(assets)).into_response(),
        Err(e) => json_err(StatusCode::INTERNAL_SERVER_ERROR, e.to_string()).into_response(),
    }
}

#[derive(Deserialize)]
struct AddAssetQuery {
    device_id: Option<String>,
}

async fn add_asset_to_folder(
    State(state): State<AppState>,
    Path((folder_id, asset_id)): Path<(Uuid, Uuid)>,
    Query(query): Query<AddAssetQuery>,
) -> Response {
    match folder::add_asset_to_folder(&state.pool, &state.cfg, folder_id, asset_id, query.device_id.as_deref()).await {
        Ok(()) => (StatusCode::OK, Json(serde_json::json!({"added": true}))).into_response(),
        Err(e) => json_err(StatusCode::INTERNAL_SERVER_ERROR, e.to_string()).into_response(),
    }
}

async fn remove_asset_from_folder(
    State(state): State<AppState>,
    Path((folder_id, asset_id)): Path<(Uuid, Uuid)>,
) -> Response {
    match folder::remove_asset_from_folder(&state.pool, &state.cfg, folder_id, asset_id).await {
        Ok(()) => (StatusCode::OK, Json(serde_json::json!({"removed": true}))).into_response(),
        Err(e) => json_err(StatusCode::INTERNAL_SERVER_ERROR, e.to_string()).into_response(),
    }
}

// ============ 存储卷管理 ============

#[derive(Serialize)]
struct VolumeWithUsage {
    #[serde(flatten)]
    volume: crate::volume::StorageVolume,
    /// 该卷下未删除资产的字节数总和（DB 里登记的值，秒级返回）
    used_by_assets: i64,
    /// 该卷下未删除资产的数量
    asset_count: i64,
}

async fn list_volumes(State(state): State<AppState>) -> Response {
    let vols = match state.volumes.all_volumes().await {
        Ok(v) => v,
        Err(e) => return json_err(StatusCode::INTERNAL_SERVER_ERROR, e.to_string()).into_response(),
    };

    // 一次 query 拿到每个卷的 sum/count，避免 N+1
    let usage: Vec<(Option<Uuid>, i64, i64)> = sqlx::query_as(
        "SELECT volume_id, COALESCE(SUM(size_bytes), 0)::BIGINT, COUNT(*)::BIGINT
         FROM assets
         WHERE is_deleted = FALSE
         GROUP BY volume_id"
    )
    .fetch_all(&state.pool)
    .await
    .unwrap_or_default();

    let usage_map: std::collections::HashMap<Uuid, (i64, i64)> = usage
        .into_iter()
        .filter_map(|(id, bytes, count)| id.map(|i| (i, (bytes, count))))
        .collect();

    let enriched: Vec<VolumeWithUsage> = vols.into_iter().map(|v| {
        let (used, count) = usage_map.get(&v.id).cloned().unwrap_or((0, 0));
        VolumeWithUsage { volume: v, used_by_assets: used, asset_count: count }
    }).collect();

    (StatusCode::OK, Json(enriched)).into_response()
}

#[derive(Deserialize)]
struct CreateVolumeRequest {
    label: String,
    base_path: String,
    priority: Option<i32>,
    min_free_bytes: Option<i64>,
}

async fn create_volume(
    State(state): State<AppState>,
    Json(req): Json<CreateVolumeRequest>,
) -> Response {
    match crate::volume::add_volume(
        &state.pool,
        &req.label,
        &req.base_path,
        req.priority.unwrap_or(0),
        req.min_free_bytes.unwrap_or(5 * 1024 * 1024 * 1024),
    )
    .await
    {
        Ok(vol) => (StatusCode::OK, Json(vol)).into_response(),
        Err(e) => json_err(StatusCode::INTERNAL_SERVER_ERROR, e.to_string()).into_response(),
    }
}

async fn get_volume_detail(
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
) -> Response {
    match state.volumes.get_volume(id).await {
        Ok(vol) => (StatusCode::OK, Json(vol)).into_response(),
        Err(e) => json_err(StatusCode::NOT_FOUND, e.to_string()).into_response(),
    }
}

// ============ 目录扫描 ============

#[derive(Deserialize)]
struct StartScanRequest {
    volume_id: Uuid,
    scan_path: Option<String>,
}

async fn start_scan(
    State(state): State<AppState>,
    Json(req): Json<StartScanRequest>,
) -> Response {
    match crate::scan::start_scan(state, req.volume_id, req.scan_path).await {
        Ok(session_id) => (
            StatusCode::ACCEPTED,
            Json(serde_json::json!({"session_id": session_id})),
        )
            .into_response(),
        Err(e) => json_err(StatusCode::BAD_REQUEST, e.to_string()).into_response(),
    }
}

async fn get_scan_session(
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
) -> Response {
    match crate::scan::get_session(&state.pool, id).await {
        Ok(Some(s)) => (StatusCode::OK, Json(s)).into_response(),
        Ok(None) => json_err(StatusCode::NOT_FOUND, "扫描会话不存在").into_response(),
        Err(e) => json_err(StatusCode::INTERNAL_SERVER_ERROR, e.to_string()).into_response(),
    }
}

async fn list_scan_sessions_api(State(state): State<AppState>) -> Response {
    match crate::scan::list_sessions(&state.pool).await {
        Ok(sessions) => (StatusCode::OK, Json(sessions)).into_response(),
        Err(e) => json_err(StatusCode::INTERNAL_SERVER_ERROR, e.to_string()).into_response(),
    }
}
