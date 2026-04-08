use std::sync::Arc;
use crate::ai::AiClient;
use crate::config::Config;
use crate::volume::VolumeManager;
use sqlx::{postgres::PgPoolOptions, PgPool};
use tokio::sync::Semaphore;

#[derive(Clone)]
pub struct AppState {
    pub cfg: Config,
    pub pool: PgPool,
    pub ai_client: Option<AiClient>,
    pub volumes: VolumeManager,
    /// 限制并发 ffmpeg 进程数（缩略图 + 转码 + probe 共享）
    pub ffmpeg_semaphore: Arc<Semaphore>,
}

pub async fn connect_and_migrate(database_url: &str) -> anyhow::Result<PgPool> {
    let pool = PgPoolOptions::new()
        .max_connections(10)
        .connect(database_url)
        .await?;

    sqlx::migrate!("./migrations").run(&pool).await?;
    Ok(pool)
}


