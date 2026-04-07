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
    pub asset_count: i64,
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

    // 5. 写入数据库
    sqlx::query(
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
    .await?;

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
    // 单条 SQL：JOIN 获取 asset_count 和封面缩略图
    // 封面优先使用 cover_asset_id，否则取该文件夹最新添加资产的缩略图
    let folders = if parent_id.is_some() {
        sqlx::query_as::<_, FolderWithCount>(
            r#"
            SELECT 
                f.id, f.name, f.description, f.cover_asset_id, f.parent_id, 
                f.created_by, f.created_at, f.updated_at, 
                f.fs_name, f.fs_path, 
                COALESCE(f.cover_thumb_path, cover_asset.thumb_path, latest_asset.thumb_path) as cover_thumb_path,
                COALESCE(cnt.asset_count, 0) as asset_count
            FROM folders f
            LEFT JOIN (
                SELECT folder_id, COUNT(*) as asset_count 
                FROM asset_folders 
                GROUP BY folder_id
            ) cnt ON cnt.folder_id = f.id
            LEFT JOIN assets cover_asset ON cover_asset.id = f.cover_asset_id
            LEFT JOIN LATERAL (
                SELECT a.thumb_path
                FROM asset_folders af
                JOIN assets a ON a.id = af.asset_id
                WHERE af.folder_id = f.id AND a.is_deleted = FALSE
                ORDER BY af.added_at DESC
                LIMIT 1
            ) latest_asset ON true
            WHERE f.parent_id = $1 AND f.is_deleted = FALSE
            ORDER BY f.name ASC
            "#,
        )
        .bind(parent_id)
        .fetch_all(pool)
        .await?
    } else {
        // parent_id 为 None 时，获取根文件夹
        sqlx::query_as::<_, FolderWithCount>(
            r#"
            SELECT 
                f.id, f.name, f.description, f.cover_asset_id, f.parent_id, 
                f.created_by, f.created_at, f.updated_at, 
                f.fs_name, f.fs_path, 
                COALESCE(f.cover_thumb_path, cover_asset.thumb_path, latest_asset.thumb_path) as cover_thumb_path,
                COALESCE(cnt.asset_count, 0) as asset_count
            FROM folders f
            LEFT JOIN (
                SELECT folder_id, COUNT(*) as asset_count 
                FROM asset_folders 
                GROUP BY folder_id
            ) cnt ON cnt.folder_id = f.id
            LEFT JOIN assets cover_asset ON cover_asset.id = f.cover_asset_id
            LEFT JOIN LATERAL (
                SELECT a.thumb_path
                FROM asset_folders af
                JOIN assets a ON a.id = af.asset_id
                WHERE af.folder_id = f.id AND a.is_deleted = FALSE
                ORDER BY af.added_at DESC
                LIMIT 1
            ) latest_asset ON true
            WHERE f.parent_id IS NULL AND f.is_deleted = FALSE
            ORDER BY f.name ASC
            "#,
        )
        .fetch_all(pool)
        .await?
    };

    Ok(folders)
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
    
    // 6. 删除 asset_folders 关联
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

