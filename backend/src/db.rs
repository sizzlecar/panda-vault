use crate::ai::AiClient;
use crate::config::Config;
use crate::volume::VolumeManager;
use sqlx::{postgres::PgPoolOptions, PgPool};

#[derive(Clone)]
pub struct AppState {
    pub cfg: Config,
    pub pool: PgPool,
    pub ai_client: Option<AiClient>,
    pub volumes: VolumeManager,
}

pub async fn connect_and_migrate(database_url: &str) -> anyhow::Result<PgPool> {
    let pool = PgPoolOptions::new()
        .max_connections(10)
        .connect(database_url)
        .await?;

    sqlx::migrate!("./migrations").run(&pool).await?;
    Ok(pool)
}


