//! 同步任务模块

use chrono::NaiveDateTime;
use serde::{Deserialize, Serialize};
use sqlx::PgPool;
use uuid::Uuid;

/// 同步会话
#[derive(Debug, Serialize, sqlx::FromRow)]
pub struct SyncSession {
    pub id: Uuid,
    pub device_id: String,
    pub device_name: Option<String>,
    pub source_type: String,
    pub total_count: i32,
    pub success_count: i32,
    pub failed_count: i32,
    pub skipped_count: i32,
    pub status: String,
    #[serde(serialize_with = "crate::timestamp::serialize_opt")]
    pub started_at: Option<NaiveDateTime>,
    #[serde(serialize_with = "crate::timestamp::serialize_opt")]
    pub finished_at: Option<NaiveDateTime>,
    #[serde(serialize_with = "crate::timestamp::serialize")]
    pub created_at: NaiveDateTime,
    pub error_message: Option<String>,
}

/// 同步项目
#[derive(Debug, Serialize, sqlx::FromRow)]
pub struct SyncItem {
    pub id: Uuid,
    pub session_id: Uuid,
    pub filename: String,
    pub file_size: Option<i64>,
    pub asset_id: Option<Uuid>,
    pub status: String,
    pub error_message: Option<String>,
    pub retry_count: i32,
    #[serde(serialize_with = "crate::timestamp::serialize")]
    pub created_at: NaiveDateTime,
    #[serde(serialize_with = "crate::timestamp::serialize")]
    pub updated_at: NaiveDateTime,
}

/// 创建同步会话请求
#[derive(Debug, Deserialize)]
pub struct CreateSessionRequest {
    pub device_id: String,
    pub device_name: Option<String>,
    pub source_type: String,
    pub files: Vec<CreateSyncItemRequest>,
}

#[derive(Debug, Deserialize)]
pub struct CreateSyncItemRequest {
    pub filename: String,
    pub file_size: Option<i64>,
}

/// 创建同步会话
pub async fn create_session(
    pool: &PgPool,
    req: CreateSessionRequest,
) -> anyhow::Result<SyncSession> {
    let session_id = Uuid::new_v4();
    let total_count = req.files.len() as i32;

    // 创建会话
    sqlx::query(
        r#"
        INSERT INTO sync_sessions (id, device_id, device_name, source_type, total_count, status, started_at)
        VALUES ($1, $2, $3, $4, $5, 'running', NOW())
        "#,
    )
    .bind(session_id)
    .bind(&req.device_id)
    .bind(&req.device_name)
    .bind(&req.source_type)
    .bind(total_count)
    .execute(pool)
    .await?;

    // 创建同步项目
    for file in req.files {
        sqlx::query(
            r#"
            INSERT INTO sync_items (session_id, filename, file_size, status)
            VALUES ($1, $2, $3, 'pending')
            "#,
        )
        .bind(session_id)
        .bind(&file.filename)
        .bind(file.file_size)
        .execute(pool)
        .await?;
    }

    get_session(pool, session_id).await
}

/// 获取同步会话详情
pub async fn get_session(pool: &PgPool, session_id: Uuid) -> anyhow::Result<SyncSession> {
    let session = sqlx::query_as::<_, SyncSession>(
        r#"
        SELECT id, device_id, device_name, source_type, total_count, success_count,
               failed_count, skipped_count, status::text, started_at, finished_at,
               created_at, error_message
        FROM sync_sessions
        WHERE id = $1
        "#,
    )
    .bind(session_id)
    .fetch_one(pool)
    .await?;

    Ok(session)
}

/// 获取设备的同步历史
pub async fn list_sessions(
    pool: &PgPool,
    device_id: Option<&str>,
    limit: i64,
    offset: i64,
) -> anyhow::Result<Vec<SyncSession>> {
    let sessions = if let Some(did) = device_id {
        sqlx::query_as::<_, SyncSession>(
            r#"
            SELECT id, device_id, device_name, source_type, total_count, success_count,
                   failed_count, skipped_count, status::text, started_at, finished_at,
                   created_at, error_message
            FROM sync_sessions
            WHERE device_id = $1
            ORDER BY created_at DESC
            LIMIT $2 OFFSET $3
            "#,
        )
        .bind(did)
        .bind(limit)
        .bind(offset)
        .fetch_all(pool)
        .await?
    } else {
        sqlx::query_as::<_, SyncSession>(
            r#"
            SELECT id, device_id, device_name, source_type, total_count, success_count,
                   failed_count, skipped_count, status::text, started_at, finished_at,
                   created_at, error_message
            FROM sync_sessions
            ORDER BY created_at DESC
            LIMIT $1 OFFSET $2
            "#,
        )
        .bind(limit)
        .bind(offset)
        .fetch_all(pool)
        .await?
    };

    Ok(sessions)
}

/// 获取会话中的同步项目
pub async fn list_session_items(pool: &PgPool, session_id: Uuid) -> anyhow::Result<Vec<SyncItem>> {
    let items = sqlx::query_as::<_, SyncItem>(
        r#"
        SELECT id, session_id, filename, file_size, asset_id, status::text,
               error_message, retry_count, created_at, updated_at
        FROM sync_items
        WHERE session_id = $1
        ORDER BY created_at ASC
        "#,
    )
    .bind(session_id)
    .fetch_all(pool)
    .await?;

    Ok(items)
}

/// 更新同步项目状态
pub async fn update_item_status(
    pool: &PgPool,
    item_id: Uuid,
    status: &str,
    asset_id: Option<Uuid>,
    error_message: Option<&str>,
) -> anyhow::Result<()> {
    sqlx::query(
        r#"
        UPDATE sync_items
        SET status = $2::sync_item_status,
            asset_id = COALESCE($3, asset_id),
            error_message = $4,
            updated_at = NOW()
        WHERE id = $1
        "#,
    )
    .bind(item_id)
    .bind(status)
    .bind(asset_id)
    .bind(error_message)
    .execute(pool)
    .await?;

    Ok(())
}

/// 更新会话统计并检查是否完成
pub async fn refresh_session_stats(pool: &PgPool, session_id: Uuid) -> anyhow::Result<()> {
    // 统计各状态数量
    sqlx::query(
        r#"
        UPDATE sync_sessions s
        SET success_count = (SELECT COUNT(*) FROM sync_items WHERE session_id = s.id AND status = 'succeeded'),
            failed_count = (SELECT COUNT(*) FROM sync_items WHERE session_id = s.id AND status = 'failed'),
            skipped_count = (SELECT COUNT(*) FROM sync_items WHERE session_id = s.id AND status = 'skipped'),
            status = CASE
                WHEN (SELECT COUNT(*) FROM sync_items WHERE session_id = s.id AND status IN ('pending', 'uploading')) = 0
                THEN 'completed'
                ELSE 'running'
            END,
            finished_at = CASE
                WHEN (SELECT COUNT(*) FROM sync_items WHERE session_id = s.id AND status IN ('pending', 'uploading')) = 0
                THEN NOW()
                ELSE NULL
            END
        WHERE id = $1
        "#,
    )
    .bind(session_id)
    .execute(pool)
    .await?;

    Ok(())
}

/// 重试失败的项目
pub async fn retry_failed_items(pool: &PgPool, session_id: Uuid) -> anyhow::Result<i64> {
    let result = sqlx::query(
        r#"
        UPDATE sync_items
        SET status = 'pending',
            error_message = NULL,
            retry_count = retry_count + 1,
            updated_at = NOW()
        WHERE session_id = $1 AND status = 'failed'
        "#,
    )
    .bind(session_id)
    .execute(pool)
    .await?;

    // 重置会话状态
    sqlx::query(
        r#"
        UPDATE sync_sessions
        SET status = 'running', finished_at = NULL
        WHERE id = $1
        "#,
    )
    .bind(session_id)
    .execute(pool)
    .await?;

    Ok(result.rows_affected() as i64)
}

/// 通过 session_id + filename (+ file_size) 找到一个最匹配的 sync_item（优先 pending/uploading），并更新状态。
///
/// 说明：
/// - 客户端当前只会在创建会话时上传 filename/file_size，上传文件本身走 /api/upload。
/// - 为了避免客户端必须持有 sync_item_id，这里用 filename+size 做“尽可能准确”的匹配。
/// - 若同名文件存在多条记录，会按 created_at 最早的那条 pending/uploading 优先更新。
pub async fn update_item_status_by_file(
    pool: &PgPool,
    session_id: Uuid,
    filename: &str,
    file_size: Option<i64>,
    status: &str,
    asset_id: Option<Uuid>,
    error_message: Option<&str>,
) -> anyhow::Result<()> {
    // 1) 先选出一个候选 item_id（尽量精准匹配 size）
    let item_id: Option<(Uuid,)> = sqlx::query_as(
        r#"
        SELECT id
        FROM sync_items
        WHERE session_id = $1
          AND filename = $2
          AND ($3::bigint IS NULL OR file_size = $3::bigint)
          AND status IN ('pending', 'uploading')
        ORDER BY created_at ASC
        LIMIT 1
        "#,
    )
    .bind(session_id)
    .bind(filename)
    .bind(file_size)
    .fetch_optional(pool)
    .await?;

    let Some((id,)) = item_id else {
        // 找不到就直接返回 OK：允许客户端不创建 session 的情况下仍可上传
        return Ok(());
    };

    update_item_status(pool, id, status, asset_id, error_message).await?;
    refresh_session_stats(pool, session_id).await?;
    Ok(())
}

