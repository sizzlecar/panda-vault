//! 文件夹模块
//! 第五阶段：文件夹与文件系统同步（SMB 一致）

use chrono::NaiveDateTime;
use serde::{Deserialize, Serialize};
use sqlx::PgPool;
use uuid::Uuid;

use crate::config::Config;

/// 文件夹
#[derive(Debug, Serialize, sqlx::FromRow)]
pub struct Folder {
    pub id: Uuid,
    pub name: String,
    pub description: Option<String>,
    pub cover_asset_id: Option<Uuid>,
    pub parent_id: Option<Uuid>,
    pub created_by: Option<String>,
    #[serde(serialize_with = "crate::timestamp::serialize")]
    pub created_at: NaiveDateTime,
    #[serde(serialize_with = "crate::timestamp::serialize")]
    pub updated_at: NaiveDateTime,
    // 第五阶段新增
    pub fs_name: Option<String>,        // 磁盘目录名
    pub fs_path: Option<String>,        // 相对于 albums/ 的完整路径
    pub cover_thumb_path: Option<String>, // 封面缩略图路径（优化 N+1）
}

/// 文件夹及其资产数量（用于列表返回）
#[derive(Debug, Serialize, sqlx::FromRow)]
pub struct FolderWithCount {
    pub id: Uuid,
    pub name: String,
    pub description: Option<String>,
    pub cover_asset_id: Option<Uuid>,
    pub parent_id: Option<Uuid>,
    pub created_by: Option<String>,
    #[serde(serialize_with = "crate::timestamp::serialize")]
    pub created_at: NaiveDateTime,
    #[serde(serialize_with = "crate::timestamp::serialize")]
    pub updated_at: NaiveDateTime,
    pub fs_name: Option<String>,
    pub fs_path: Option<String>,
    pub cover_thumb_path: Option<String>,
    /// 递归含子文件夹内所有资产的数量（NULL = 尚未计算，同 total_bytes 懒机制）
    pub asset_count: Option<i64>,
    /// 文件夹内所有资产字节数总和（递归，含子文件夹）
    /// NULL 表示尚未计算（会在 list_folders 异步触发 recompute，下次读就有值）
    pub total_bytes: Option<i64>,
}

/// 创建文件夹请求
#[derive(Debug, Deserialize)]
pub struct CreateFolderRequest {
    pub name: String,
    pub description: Option<String>,
    pub parent_id: Option<Uuid>,
    pub device_id: Option<String>,
}

/// 更新文件夹请求
#[derive(Debug, Deserialize)]
pub struct UpdateFolderRequest {
    pub name: Option<String>,
    pub description: Option<String>,
    pub cover_asset_id: Option<Uuid>,
    pub parent_id: Option<Uuid>,
}

/// 创建文件夹（同步创建磁盘目录）
pub async fn create_folder(pool: &PgPool, cfg: &Config, req: CreateFolderRequest) -> anyhow::Result<Folder> {
    let folder_id = Uuid::new_v4();
    
    // 1. 生成文件系统安全的目录名
    let fs_name = Config::sanitize_fs_name(&req.name);
    
    // 2. 获取父文件夹的 fs_path（如果有）
    let parent_fs_path = if let Some(parent_id) = req.parent_id {
        let parent = get_folder(pool, parent_id).await?;
        parent.fs_path
    } else {
        None
    };
    
    // 3. 构建完整的 fs_path
    let fs_path = Config::build_folder_fs_path(parent_fs_path.as_deref(), &fs_name);
    
    // 4. 创建磁盘目录
    let dir_abs = cfg.albums_dir.join(&fs_path);
    tokio::fs::create_dir_all(&dir_abs).await?;
    tracing::info!("创建文件夹目录: {}", dir_abs.display());

    // 5. 写入数据库（检查同名冲突）
    let result = sqlx::query(
        r#"
        INSERT INTO folders (id, name, description, parent_id, created_by, fs_name, fs_path)
        VALUES ($1, $2, $3, $4, $5, $6, $7)
        "#,
    )
    .bind(folder_id)
    .bind(&req.name)
    .bind(&req.description)
    .bind(req.parent_id)
    .bind(&req.device_id)
    .bind(&fs_name)
    .bind(&fs_path)
    .execute(pool)
    .await;

    if let Err(e) = result {
        let msg = e.to_string();
        if msg.contains("duplicate") || msg.contains("unique") {
            anyhow::bail!("同名文件夹已存在: {}", req.name);
        }
        return Err(e.into());
    }

    get_folder(pool, folder_id).await
}

/// 获取文件夹
pub async fn get_folder(pool: &PgPool, folder_id: Uuid) -> anyhow::Result<Folder> {
    let folder = sqlx::query_as::<_, Folder>(
        r#"
        SELECT id, name, description, cover_asset_id, parent_id, created_by, 
               created_at, updated_at, fs_name, fs_path, cover_thumb_path
        FROM folders
        WHERE id = $1 AND is_deleted = FALSE
        "#,
    )
    .bind(folder_id)
    .fetch_one(pool)
    .await?;

    Ok(folder)
}

/// 列出所有文件夹（可按父文件夹筛选）
/// 优化：单条 SQL 返回 asset_count 和 cover_thumb_path，避免 N+1
pub async fn list_folders(
    pool: &PgPool,
    parent_id: Option<Uuid>,
) -> anyhow::Result<Vec<FolderWithCount>> {
    // 单条 SQL：直接读取 folders.total_bytes 和 total_asset_count（写路径维护 + 懒重算）
    // asset_count/total_bytes 都是递归含子文件夹
    let query = r#"
        SELECT
            f.id, f.name, f.description, f.cover_asset_id, f.parent_id,
            f.created_by, f.created_at, f.updated_at,
            f.fs_name, f.fs_path,
            COALESCE(f.cover_thumb_path, cover_asset.thumb_path, latest_asset.thumb_path) as cover_thumb_path,
            f.total_asset_count as asset_count,
            f.total_bytes
        FROM folders f
        LEFT JOIN assets cover_asset ON cover_asset.id = f.cover_asset_id
        LEFT JOIN LATERAL (
            SELECT a.thumb_path
            FROM asset_folders af
            JOIN assets a ON a.id = af.asset_id
            WHERE af.folder_id = f.id AND a.is_deleted = FALSE
            ORDER BY af.added_at DESC
            LIMIT 1
        ) latest_asset ON true
        WHERE f.is_deleted = FALSE
    "#;

    let folders = if let Some(pid) = parent_id {
        sqlx::query_as::<_, FolderWithCount>(&format!("{query} AND f.parent_id = $1 ORDER BY f.name ASC"))
            .bind(pid)
            .fetch_all(pool)
            .await?
    } else {
        sqlx::query_as::<_, FolderWithCount>(&format!("{query} AND f.parent_id IS NULL ORDER BY f.name ASC"))
            .fetch_all(pool)
            .await?
    };

    Ok(folders)
}

/// 写路径通用 helper：把 delta_bytes / delta_count 加到 folder_id 及所有祖先
/// delta 可正可负；folder_id=None 或两个 delta 都为 0 直接 no-op
/// NULL 值（尚未计算）会先 COALESCE 为 0 再加 delta —— 可能临时不准，等异步 recompute 校正
pub async fn adjust_folder_ancestors(
    pool: &PgPool,
    folder_id: Option<Uuid>,
    delta_bytes: i64,
    delta_count: i64,
) -> anyhow::Result<()> {
    let fid = match folder_id {
        Some(id) => id,
        None => return Ok(()),
    };
    if delta_bytes == 0 && delta_count == 0 { return Ok(()); }
    sqlx::query(
        r#"
        WITH RECURSIVE ancestors AS (
            SELECT id, parent_id FROM folders WHERE id = $1
            UNION ALL
            SELECT f.id, f.parent_id FROM folders f
            JOIN ancestors a ON f.id = a.parent_id
            WHERE f.is_deleted = FALSE
        )
        UPDATE folders SET
            total_bytes       = GREATEST(0, COALESCE(total_bytes, 0)       + $2),
            total_asset_count = GREATEST(0, COALESCE(total_asset_count, 0) + $3)
        WHERE id IN (SELECT id FROM ancestors)
        "#,
    )
    .bind(fid)
    .bind(delta_bytes)
    .bind(delta_count)
    .execute(pool)
    .await?;
    Ok(())
}

/// 只调 bytes 的 helper（兼容），转发到新的两列 helper
pub async fn adjust_folder_ancestors_size(
    pool: &PgPool,
    folder_id: Option<Uuid>,
    delta: i64,
) -> anyhow::Result<()> {
    adjust_folder_ancestors(pool, folder_id, delta, 0).await
}

/// 查询一个 asset 当前关联的所有 folder ids（给 delete/restore 遍历用）
pub async fn folders_of_asset(pool: &PgPool, asset_id: Uuid) -> anyhow::Result<Vec<Uuid>> {
    let rows: Vec<(Uuid,)> = sqlx::query_as(
        "SELECT folder_id FROM asset_folders WHERE asset_id = $1",
    )
    .bind(asset_id)
    .fetch_all(pool)
    .await?;
    Ok(rows.into_iter().map(|r| r.0).collect())
}

/// 全量重算 folders.total_bytes / total_asset_count（含子文件夹递归）
/// 由 list_folders 检测到任意 NULL 值时异步触发；亦可手动调用作为校准
pub async fn recompute_all_folder_sizes(pool: &PgPool) -> anyhow::Result<u64> {
    let r = sqlx::query(
        r#"
        WITH RECURSIVE folder_closure AS (
            SELECT id AS root_id, id AS descendant_id
            FROM folders WHERE is_deleted = FALSE
            UNION ALL
            SELECT fc.root_id, f.id
            FROM folder_closure fc
            JOIN folders f ON f.parent_id = fc.descendant_id
            WHERE f.is_deleted = FALSE
        ),
        folder_stats AS (
            SELECT fc.root_id AS folder_id,
                   COALESCE(SUM(a.size_bytes), 0)::BIGINT AS total_bytes,
                   COUNT(a.id)::BIGINT AS total_count
            FROM folder_closure fc
            LEFT JOIN asset_folders af ON af.folder_id = fc.descendant_id
            LEFT JOIN assets a ON a.id = af.asset_id AND a.is_deleted = FALSE
            GROUP BY fc.root_id
        )
        UPDATE folders SET
            total_bytes       = COALESCE(fs.total_bytes, 0),
            total_asset_count = COALESCE(fs.total_count, 0)
        FROM folder_stats fs
        WHERE folders.id = fs.folder_id
          AND (folders.total_bytes IS NULL
               OR folders.total_asset_count IS NULL
               OR folders.total_bytes       <> COALESCE(fs.total_bytes, 0)
               OR folders.total_asset_count <> COALESCE(fs.total_count, 0))
        "#,
    )
    .execute(pool)
    .await?;
    Ok(r.rows_affected())
}

/// 更新文件夹
/// 注意：如果更改 name，也会更新 fs_name（但目录重命名暂不实现，需要后续支持）
pub async fn update_folder(
    pool: &PgPool,
    folder_id: Uuid,
    req: UpdateFolderRequest,
) -> anyhow::Result<Folder> {
    // 如果更改了 name，同步更新 fs_name
    let fs_name = req.name.as_ref().map(|n| Config::sanitize_fs_name(n));
    
    sqlx::query(
        r#"
        UPDATE folders
        SET name = COALESCE($2, name),
            description = COALESCE($3, description),
            cover_asset_id = COALESCE($4, cover_asset_id),
            parent_id = COALESCE($5, parent_id),
            fs_name = COALESCE($6, fs_name),
            updated_at = NOW()
        WHERE id = $1 AND is_deleted = FALSE
        "#,
    )
    .bind(folder_id)
    .bind(&req.name)
    .bind(&req.description)
    .bind(req.cover_asset_id)
    .bind(req.parent_id)
    .bind(&fs_name)
    .execute(pool)
    .await?;

    // TODO: 如果重命名，需要同步重命名磁盘目录并更新所有子文件夹的 fs_path
    // 这是一个复杂操作，暂时只更新 DB，后续版本实现完整的目录重命名

    get_folder(pool, folder_id).await
}

/// 删除文件夹（软删除）
pub async fn delete_folder(pool: &PgPool, folder_id: Uuid) -> anyhow::Result<()> {
    sqlx::query(
        r#"
        UPDATE folders
        SET is_deleted = TRUE, updated_at = NOW()
        WHERE id = $1
        "#,
    )
    .bind(folder_id)
    .execute(pool)
    .await?;

    Ok(())
}

/// 移动资产到文件夹（真实移动文件）
/// 这是"单归属"语义：资产只能在一个文件夹中，移动会覆盖之前的归属
pub async fn add_asset_to_folder(
    pool: &PgPool,
    cfg: &Config,
    folder_id: Uuid,
    asset_id: Uuid,
    device_id: Option<&str>,
) -> anyhow::Result<()> {
    // 1. 获取目标文件夹信息
    let folder = get_folder(pool, folder_id).await?;
    let folder_fs_path = folder.fs_path.ok_or_else(|| anyhow::anyhow!("文件夹缺少 fs_path"))?;
    
    // 2. 获取资产当前信息
    let asset: AssetPathInfo = sqlx::query_as(
        "SELECT id, filename, file_path FROM assets WHERE id = $1 AND is_deleted = FALSE"
    )
    .bind(asset_id)
    .fetch_one(pool)
    .await?;
    
    // 3. 计算新路径
    let old_abs = cfg.resolve_under_root(&asset.file_path);
    let new_rel = format!("/raw/albums/{}/{}_{}", folder_fs_path, asset.id, asset.filename);
    let new_abs = cfg.resolve_under_root(&new_rel);
    
    // 4. 确保目标目录存在
    if let Some(parent) = new_abs.parent() {
        tokio::fs::create_dir_all(parent).await?;
    }
    
    // 5. 移动文件（优先 rename，失败则 copy+delete）
    if old_abs != new_abs {
        if let Err(e) = tokio::fs::rename(&old_abs, &new_abs).await {
            tracing::warn!("rename 失败，尝试 copy: {e}");
            tokio::fs::copy(&old_abs, &new_abs).await?;
            tokio::fs::remove_file(&old_abs).await?;
        }
        tracing::info!("移动资产: {} -> {}", old_abs.display(), new_abs.display());
    }
    
    // 6. 更新 assets.file_path
    sqlx::query("UPDATE assets SET file_path = $2 WHERE id = $1")
        .bind(asset_id)
        .bind(&new_rel)
        .execute(pool)
        .await?;
    
    // 7. 更新 asset_folders（单归属：先删除旧关联，再插入新关联）
    //    更新前先查 asset 字节数和旧归属文件夹，以便更新 total_bytes
    let (size_bytes,): (i64,) = sqlx::query_as("SELECT size_bytes FROM assets WHERE id = $1")
        .bind(asset_id).fetch_one(pool).await?;
    let old_folder_ids = folders_of_asset(pool, asset_id).await?;

    sqlx::query("DELETE FROM asset_folders WHERE asset_id = $1")
        .bind(asset_id)
        .execute(pool)
        .await?;

    sqlx::query(
        r#"
        INSERT INTO asset_folders (folder_id, asset_id, added_by)
        VALUES ($1, $2, $3)
        "#,
    )
    .bind(folder_id)
    .bind(asset_id)
    .bind(device_id)
    .execute(pool)
    .await?;

    // 8. 更新 total_bytes / total_asset_count：从旧祖先树减、在新祖先树加
    for old_fid in old_folder_ids {
        let _ = adjust_folder_ancestors(pool, Some(old_fid), -size_bytes, -1).await;
    }
    let _ = adjust_folder_ancestors(pool, Some(folder_id), size_bytes, 1).await;

    Ok(())
}

/// 资产路径信息（用于移动操作）
#[derive(sqlx::FromRow)]
struct AssetPathInfo {
    id: Uuid,
    filename: String,
    file_path: String,
}

/// 从文件夹移除资产（移动到 inbox 未分类目录）
pub async fn remove_asset_from_folder(
    pool: &PgPool,
    cfg: &Config,
    folder_id: Uuid,
    asset_id: Uuid,
) -> anyhow::Result<()> {
    use chrono::{Datelike, Utc};
    
    // 1. 获取资产当前信息
    let asset: AssetPathInfo = sqlx::query_as(
        "SELECT id, filename, file_path FROM assets WHERE id = $1 AND is_deleted = FALSE"
    )
    .bind(asset_id)
    .fetch_one(pool)
    .await?;
    
    // 2. 计算 inbox 路径（按年月归档）
    let now = Utc::now();
    let (yyyy, mm) = (now.year(), now.month());
    let old_abs = cfg.resolve_under_root(&asset.file_path);
    let new_rel = format!("/raw/inbox/{:04}/{:02}/{}_{}", yyyy, mm, asset.id, asset.filename);
    let new_abs = cfg.resolve_under_root(&new_rel);
    
    // 3. 确保目标目录存在
    if let Some(parent) = new_abs.parent() {
        tokio::fs::create_dir_all(parent).await?;
    }
    
    // 4. 移动文件
    if old_abs != new_abs {
        if let Err(e) = tokio::fs::rename(&old_abs, &new_abs).await {
            tracing::warn!("rename 失败，尝试 copy: {e}");
            tokio::fs::copy(&old_abs, &new_abs).await?;
            tokio::fs::remove_file(&old_abs).await?;
        }
        tracing::info!("移除资产到 inbox: {} -> {}", old_abs.display(), new_abs.display());
    }
    
    // 5. 更新 assets.file_path
    sqlx::query("UPDATE assets SET file_path = $2 WHERE id = $1")
        .bind(asset_id)
        .bind(&new_rel)
        .execute(pool)
        .await?;
    
    // 6. 删除 asset_folders 关联前先拿 size
    let (size_bytes,): (i64,) = sqlx::query_as("SELECT size_bytes FROM assets WHERE id = $1")
        .bind(asset_id).fetch_one(pool).await?;

    sqlx::query(
        r#"
        DELETE FROM asset_folders
        WHERE folder_id = $1 AND asset_id = $2
        "#,
    )
    .bind(folder_id)
    .bind(asset_id)
    .execute(pool)
    .await?;

    // 7. 从该文件夹及其所有祖先的 total_bytes / total_asset_count 减掉
    let _ = adjust_folder_ancestors(pool, Some(folder_id), -size_bytes, -1).await;

    Ok(())
}

use crate::api::{AssetDto, AssetRow};

/// 获取文件夹中的资产列表
pub async fn list_folder_assets(
    pool: &PgPool,
    folder_id: Uuid,
    query: Option<&str>,
    limit: i64,
    offset: i64,
) -> anyhow::Result<Vec<AssetDto>> {
    let rows = if let Some(q) = query.filter(|s| !s.is_empty()) {
        let pattern = format!("%{}%", q);
        sqlx::query_as::<_, AssetRow>(
            r#"
            SELECT a.id, a.filename, a.file_path, a.proxy_path, a.thumb_path,
                   a.file_hash, a.size_bytes, a.shoot_at, a.created_at,
                   a.duration_sec, a.width, a.height, a.volume_id
            FROM asset_folders af
            JOIN assets a ON a.id = af.asset_id
            WHERE af.folder_id = $1 AND a.is_deleted = FALSE
              AND a.filename ILIKE $4
            ORDER BY af.added_at DESC
            LIMIT $2 OFFSET $3
            "#,
        )
        .bind(folder_id)
        .bind(limit)
        .bind(offset)
        .bind(&pattern)
        .fetch_all(pool)
        .await?
    } else {
        sqlx::query_as::<_, AssetRow>(
            r#"
            SELECT a.id, a.filename, a.file_path, a.proxy_path, a.thumb_path,
                   a.file_hash, a.size_bytes, a.shoot_at, a.created_at,
                   a.duration_sec, a.width, a.height, a.volume_id
            FROM asset_folders af
            JOIN assets a ON a.id = af.asset_id
            WHERE af.folder_id = $1 AND a.is_deleted = FALSE
            ORDER BY af.added_at DESC
            LIMIT $2 OFFSET $3
            "#,
        )
        .bind(folder_id)
        .bind(limit)
        .bind(offset)
        .fetch_all(pool)
        .await?
    };

    Ok(rows.into_iter().map(AssetDto::from_row).collect())
}

