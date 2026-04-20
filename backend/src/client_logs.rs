//! 客户端日志上报：iOS / 其他终端把本地日志批量 POST 给后端，存 PG，7 天保留

use axum::{
    extract::{Query, State},
    http::StatusCode,
    response::{IntoResponse, Response},
    Json,
};
use serde::{Deserialize, Serialize};
use sqlx::PgPool;

use crate::{api::json_err, db::AppState};

// ============ Request ============

#[derive(Deserialize)]
pub struct IngestRequest {
    pub device_id: Option<String>,
    pub device_name: Option<String>,
    pub app_version: Option<String>,
    pub entries: Vec<LogEntryIn>,
}

#[derive(Deserialize)]
pub struct LogEntryIn {
    /// 客户端时间戳（unix epoch 秒，可带小数）
    pub ts: f64,
    pub level: String,
    pub category: String,
    pub location: Option<String>,
    pub message: String,
    pub metadata: Option<serde_json::Value>,
}

#[derive(Serialize)]
pub struct IngestResponse {
    pub accepted: usize,
}

// ============ Handler ============

/// POST /api/client-logs — 批量上报客户端日志
pub async fn ingest(
    State(state): State<AppState>,
    Json(req): Json<IngestRequest>,
) -> Response {
    if req.entries.is_empty() {
        return (StatusCode::OK, Json(IngestResponse { accepted: 0 })).into_response();
    }
    if req.entries.len() > 1000 {
        return json_err(StatusCode::BAD_REQUEST, "单次最多 1000 条").into_response();
    }

    // 用 unnest + insert，单次往返完成批量写入
    let mut client_ts: Vec<chrono::NaiveDateTime> = Vec::with_capacity(req.entries.len());
    let mut levels: Vec<String> = Vec::with_capacity(req.entries.len());
    let mut categories: Vec<String> = Vec::with_capacity(req.entries.len());
    let mut locations: Vec<Option<String>> = Vec::with_capacity(req.entries.len());
    let mut messages: Vec<String> = Vec::with_capacity(req.entries.len());
    let mut metadatas: Vec<Option<serde_json::Value>> = Vec::with_capacity(req.entries.len());

    for e in &req.entries {
        let secs = e.ts as i64;
        let nanos = ((e.ts.fract().abs()) * 1e9) as u32;
        let ts = chrono::DateTime::from_timestamp(secs, nanos)
            .map(|dt| dt.naive_utc())
            .unwrap_or_else(|| chrono::Utc::now().naive_utc());

        client_ts.push(ts);
        levels.push(e.level.clone());
        categories.push(e.category.clone());
        locations.push(e.location.clone());
        messages.push(e.message.clone());
        metadatas.push(e.metadata.clone());
    }

    let device_id = req.device_id.as_deref();
    let device_name = req.device_name.as_deref();
    let app_version = req.app_version.as_deref();

    let result = sqlx::query(
        r#"
        INSERT INTO client_logs (
            client_ts, device_id, device_name, app_version,
            level, category, location, message, metadata
        )
        SELECT
            ts, $1, $2, $3, lvl, cat, loc, msg, meta
        FROM UNNEST(
            $4::TIMESTAMP[],
            $5::TEXT[],
            $6::TEXT[],
            $7::TEXT[],
            $8::TEXT[],
            $9::JSONB[]
        ) AS t(ts, lvl, cat, loc, msg, meta)
        "#,
    )
    .bind(device_id)
    .bind(device_name)
    .bind(app_version)
    .bind(&client_ts)
    .bind(&levels)
    .bind(&categories)
    .bind(&locations)
    .bind(&messages)
    .bind(&metadatas)
    .execute(&state.pool)
    .await;

    match result {
        Ok(_) => (StatusCode::OK, Json(IngestResponse { accepted: req.entries.len() })).into_response(),
        Err(e) => json_err(StatusCode::INTERNAL_SERVER_ERROR, format!("写入日志失败: {e}")).into_response(),
    }
}

// ============ Browse / Stats（可选，给开发者排查用） ============

#[derive(Deserialize)]
pub struct BrowseQuery {
    pub limit: Option<i64>,
    pub category: Option<String>,
    pub level: Option<String>,
    pub device_id: Option<String>,
    pub since_minutes: Option<i64>,
}

#[derive(Serialize, sqlx::FromRow)]
pub struct LogRow {
    pub id: i64,
    pub received_at: chrono::NaiveDateTime,
    pub client_ts: chrono::NaiveDateTime,
    pub device_id: Option<String>,
    pub device_name: Option<String>,
    pub app_version: Option<String>,
    pub level: String,
    pub category: String,
    pub location: Option<String>,
    pub message: String,
}

/// GET /api/client-logs?limit=N&category=Upload&since_minutes=60
pub async fn browse(
    State(state): State<AppState>,
    Query(q): Query<BrowseQuery>,
) -> Response {
    let limit = q.limit.unwrap_or(200).clamp(1, 2000);
    let since = q.since_minutes.unwrap_or(60).max(1);

    let rows = sqlx::query_as::<_, LogRow>(
        r#"
        SELECT id, received_at, client_ts, device_id, device_name, app_version,
               level, category, location, message
        FROM client_logs
        WHERE received_at >= NOW() - ($1 || ' minutes')::INTERVAL
          AND ($2::TEXT IS NULL OR category = $2)
          AND ($3::TEXT IS NULL OR level = $3)
          AND ($4::TEXT IS NULL OR device_id = $4)
        ORDER BY received_at DESC
        LIMIT $5
        "#,
    )
    .bind(since.to_string())
    .bind(q.category.as_deref())
    .bind(q.level.as_deref())
    .bind(q.device_id.as_deref())
    .bind(limit)
    .fetch_all(&state.pool)
    .await;

    match rows {
        Ok(rows) => (StatusCode::OK, Json(rows)).into_response(),
        Err(e) => json_err(StatusCode::INTERNAL_SERVER_ERROR, e.to_string()).into_response(),
    }
}

// ============ Cleanup task（在 main.rs spawn） ============

/// 删除 7 天前的客户端日志
pub async fn cleanup_expired(pool: &PgPool) -> anyhow::Result<u64> {
    let res = sqlx::query("DELETE FROM client_logs WHERE received_at < NOW() - INTERVAL '7 days'")
        .execute(pool)
        .await?;
    Ok(res.rows_affected())
}
