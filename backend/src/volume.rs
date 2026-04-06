//! 多卷存储管理
//! 支持多块硬盘/目录组成存储池，自动选择写入目标

use chrono::NaiveDateTime;
use serde::{Deserialize, Serialize};
use sqlx::PgPool;
use std::path::{Path, PathBuf};
use uuid::Uuid;

/// DB 行
#[derive(Debug, Clone, Serialize, Deserialize, sqlx::FromRow)]
pub struct StorageVolume {
    pub id: Uuid,
    pub label: String,
    pub base_path: String,
    pub priority: i32,
    pub min_free_bytes: i64,
    pub is_active: bool,
    pub is_default: bool,
    pub total_bytes: Option<i64>,
    pub free_bytes: Option<i64>,
    pub last_checked_at: Option<NaiveDateTime>,
    pub created_at: NaiveDateTime,
}

/// 卷管理器，缓存在 AppState 中
#[derive(Debug, Clone)]
pub struct VolumeManager {
    pool: PgPool,
}

impl VolumeManager {
    pub fn new(pool: PgPool) -> Self {
        Self { pool }
    }

    /// 获取所有活跃卷（按 priority DESC 排序）
    pub async fn active_volumes(&self) -> anyhow::Result<Vec<StorageVolume>> {
        let vols = sqlx::query_as::<_, StorageVolume>(
            "SELECT * FROM storage_volumes WHERE is_active = TRUE ORDER BY priority DESC",
        )
        .fetch_all(&self.pool)
        .await?;
        Ok(vols)
    }

    /// 获取所有卷
    pub async fn all_volumes(&self) -> anyhow::Result<Vec<StorageVolume>> {
        let vols = sqlx::query_as::<_, StorageVolume>(
            "SELECT * FROM storage_volumes ORDER BY priority DESC",
        )
        .fetch_all(&self.pool)
        .await?;
        Ok(vols)
    }

    /// 获取默认卷
    pub async fn default_volume(&self) -> anyhow::Result<StorageVolume> {
        let vol = sqlx::query_as::<_, StorageVolume>(
            "SELECT * FROM storage_volumes WHERE is_default = TRUE LIMIT 1",
        )
        .fetch_one(&self.pool)
        .await?;
        Ok(vol)
    }

    /// 按 ID 获取卷
    pub async fn get_volume(&self, id: Uuid) -> anyhow::Result<StorageVolume> {
        let vol = sqlx::query_as::<_, StorageVolume>(
            "SELECT * FROM storage_volumes WHERE id = $1",
        )
        .bind(id)
        .fetch_one(&self.pool)
        .await?;
        Ok(vol)
    }

    /// 选择写入卷：按 priority DESC，选第一个有足够空间的
    pub async fn pick_write_volume(&self, needed_bytes: u64) -> anyhow::Result<StorageVolume> {
        let volumes = self.active_volumes().await?;

        for vol in &volumes {
            let free = check_disk_free(&vol.base_path);
            if free > vol.min_free_bytes as u64 + needed_bytes {
                return Ok(vol.clone());
            }
            tracing::warn!(
                "卷 '{}' ({}) 空间不足: free={}MB, need={}MB",
                vol.label,
                vol.base_path,
                free / 1024 / 1024,
                (vol.min_free_bytes as u64 + needed_bytes) / 1024 / 1024
            );
        }

        anyhow::bail!("所有存储卷空间不足，无法写入 {} 字节", needed_bytes)
    }

    /// 解析资产的绝对路径
    pub async fn resolve_asset_path(
        &self,
        file_path: &str,
        volume_id: Option<Uuid>,
    ) -> anyhow::Result<PathBuf> {
        let vol = match volume_id {
            Some(id) => self.get_volume(id).await?,
            None => self.default_volume().await?,
        };
        Ok(resolve_path(&vol, file_path))
    }

    /// 更新卷的磁盘空间信息
    pub async fn refresh_disk_stats(&self) -> anyhow::Result<()> {
        let volumes = self.all_volumes().await?;
        for vol in &volumes {
            let (total, free) = check_disk_space(&vol.base_path);
            sqlx::query(
                "UPDATE storage_volumes SET total_bytes = $2, free_bytes = $3, last_checked_at = NOW() WHERE id = $1"
            )
            .bind(vol.id)
            .bind(total as i64)
            .bind(free as i64)
            .execute(&self.pool)
            .await?;

            // 空间不足自动停用
            if free < vol.min_free_bytes as u64 && vol.is_active {
                tracing::warn!("卷 '{}' 空间不足 ({}MB < {}MB)，自动停用",
                    vol.label,
                    free / 1024 / 1024,
                    vol.min_free_bytes / 1024 / 1024,
                );
                sqlx::query("UPDATE storage_volumes SET is_active = FALSE WHERE id = $1")
                    .bind(vol.id)
                    .execute(&self.pool)
                    .await?;
            }
        }
        Ok(())
    }
}

/// 解析文件相对路径到绝对路径
pub fn resolve_path(vol: &StorageVolume, rel: &str) -> PathBuf {
    let rel = rel.trim_start_matches('/');
    PathBuf::from(&vol.base_path).join(rel)
}

/// 确保卷的目录结构存在
pub async fn ensure_volume_dirs(vol: &StorageVolume) -> anyhow::Result<()> {
    let base = Path::new(&vol.base_path);
    for sub in ["raw", "raw/albums", "raw/inbox", "raw/.trash", "proxies", ".temp"] {
        tokio::fs::create_dir_all(base.join(sub)).await?;
    }
    Ok(())
}

/// 启动时确保默认卷存在
pub async fn ensure_default_volume(
    pool: &PgPool,
    storage_root: &Path,
) -> anyhow::Result<Uuid> {
    let base_path = storage_root.to_string_lossy().to_string();

    // 检查是否已有默认卷
    let existing: Option<(Uuid,)> = sqlx::query_as(
        "SELECT id FROM storage_volumes WHERE is_default = TRUE LIMIT 1",
    )
    .fetch_optional(pool)
    .await?;

    if let Some((id,)) = existing {
        // 更新 base_path 以防路径变了
        sqlx::query("UPDATE storage_volumes SET base_path = $2 WHERE id = $1")
            .bind(id)
            .bind(&base_path)
            .execute(pool)
            .await?;
        // 把没有 volume_id 的资产归到默认卷
        sqlx::query("UPDATE assets SET volume_id = $1 WHERE volume_id IS NULL")
            .bind(id)
            .execute(pool)
            .await?;
        return Ok(id);
    }

    // 创建默认卷
    let vol_id = Uuid::new_v4();
    sqlx::query(
        r#"INSERT INTO storage_volumes (id, label, base_path, priority, is_default, is_active)
           VALUES ($1, '默认存储', $2, 0, TRUE, TRUE)"#,
    )
    .bind(vol_id)
    .bind(&base_path)
    .execute(pool)
    .await?;

    // 归属现有资产
    sqlx::query("UPDATE assets SET volume_id = $1 WHERE volume_id IS NULL")
        .bind(vol_id)
        .execute(pool)
        .await?;

    tracing::info!("创建默认存储卷: {} -> {}", vol_id, base_path);
    Ok(vol_id)
}

/// 添加新卷
pub async fn add_volume(
    pool: &PgPool,
    label: &str,
    base_path: &str,
    priority: i32,
    min_free_bytes: i64,
) -> anyhow::Result<StorageVolume> {
    let vol_id = Uuid::new_v4();
    sqlx::query(
        r#"INSERT INTO storage_volumes (id, label, base_path, priority, min_free_bytes, is_active)
           VALUES ($1, $2, $3, $4, $5, TRUE)"#,
    )
    .bind(vol_id)
    .bind(label)
    .bind(base_path)
    .bind(priority)
    .bind(min_free_bytes)
    .execute(pool)
    .await?;

    let vol = sqlx::query_as::<_, StorageVolume>(
        "SELECT * FROM storage_volumes WHERE id = $1",
    )
    .bind(vol_id)
    .fetch_one(pool)
    .await?;

    // 确保目录结构
    ensure_volume_dirs(&vol).await?;

    tracing::info!("添加存储卷: '{}' -> {}", label, base_path);
    Ok(vol)
}

/// 检查磁盘可用空间（字节）
fn check_disk_free(path: &str) -> u64 {
    fs2::available_space(path).unwrap_or(0)
}

/// 检查磁盘总空间和可用空间
fn check_disk_space(path: &str) -> (u64, u64) {
    let total = fs2::total_space(path).unwrap_or(0);
    let free = fs2::available_space(path).unwrap_or(0);
    (total, free)
}
