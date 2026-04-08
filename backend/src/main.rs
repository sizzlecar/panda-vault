mod ai;
mod api;
mod chunked_upload;
mod config;
mod db;
mod folder;
mod jobs;
mod media;
mod scan;
mod sync;
mod timestamp;
mod volume;
mod web;

use axum::{extract::DefaultBodyLimit, routing::get, Router};
use config::Config;
use tower_http::catch_panic::CatchPanicLayer;
use tower_http::{cors::CorsLayer, trace::TraceLayer};
use tracing_subscriber::EnvFilter;

// macOS: 用系统 dns-sd 命令
#[cfg(target_os = "macos")]
fn spawn_mdns(port: u16) {
    std::thread::spawn(move || {
        let child = std::process::Command::new("dns-sd")
            .args(["-R", "PandaVault", "_pandavault._tcp", "local", &port.to_string()])
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .spawn();
        match child {
            Ok(mut c) => {
                tracing::info!("mDNS 已广播: PandaVault._pandavault._tcp.local port={}", port);
                let _ = c.wait();
            }
            Err(e) => tracing::warn!("mDNS 广播失败: {}", e),
        }
    });
}

// Windows/Linux: 用 mdns-sd crate
#[cfg(not(target_os = "macos"))]
fn spawn_mdns(port: u16) {
    std::thread::spawn(move || {
        let mdns = mdns_sd::ServiceDaemon::new().expect("mDNS daemon 创建失败");
        let host = hostname::get().unwrap_or_default().to_string_lossy().to_string();
        let service = mdns_sd::ServiceInfo::new(
            "_pandavault._tcp.local.",
            "PandaVault",
            &format!("{}.", host),
            "", port, None,
        ).expect("mDNS ServiceInfo 创建失败");
        mdns.register(service).expect("mDNS 注册失败");
        tracing::info!("mDNS 已广播 (mdns-sd): PandaVault._pandavault._tcp.local port={}", port);
        loop { std::thread::park(); }
    });
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(EnvFilter::from_default_env().add_directive("info".parse()?))
        .init();

    let cfg = Config::from_env()?;
    cfg.ensure_dirs().await?;

    let pool = db::connect_and_migrate(&cfg.database_url).await?;

    let ai_client = cfg.ai_service_url.as_ref().map(|url| ai::AiClient::new(url));
    if let Some(url) = &cfg.ai_service_url {
        tracing::info!("AI 服务已配置: {}", url);
    }

    // 初始化多卷存储
    let default_vol_id = volume::ensure_default_volume(&pool, &cfg.storage_root).await?;
    let vol_mgr = volume::VolumeManager::new(pool.clone());
    // 确保默认卷目录结构
    if let Ok(default_vol) = vol_mgr.get_volume(default_vol_id).await {
        volume::ensure_volume_dirs(&default_vol).await?;
    }
    // 刷新磁盘空间
    vol_mgr.refresh_disk_stats().await?;
    tracing::info!("存储卷已初始化，默认卷: {}", default_vol_id);

    let app_state = db::AppState {
        cfg: cfg.clone(),
        pool,
        ai_client,
        volumes: vol_mgr.clone(),
        ffmpeg_semaphore: std::sync::Arc::new(tokio::sync::Semaphore::new(2)), // 最多 2 个并发 ffmpeg
    };

    // 后台 worker：轮询任务队列并转码/提取元数据
    jobs::spawn_worker(app_state.clone());

    // 补全已有 assets 的首尾指纹（head_hash / tail_hash）
    {
        let pool_bf = app_state.pool.clone();
        let storage_root = cfg.storage_root.clone();
        tokio::spawn(async move {
            let rows: Vec<(uuid::Uuid, String)> = sqlx::query_as(
                "SELECT id, file_path FROM assets WHERE head_hash IS NULL AND is_deleted = FALSE"
            ).fetch_all(&pool_bf).await.unwrap_or_default();

            if rows.is_empty() { return; }
            tracing::info!("补全首尾指纹: {} 条记录", rows.len());

            for (id, file_path) in rows {
                let rel = file_path.trim_start_matches('/');
                let abs = storage_root.join(rel);
                let result = tokio::task::spawn_blocking(move || {
                    media::compute_head_tail_hash_from_file(&abs)
                }).await;
                match result {
                    Ok(Ok((head, tail))) => {
                        let _ = sqlx::query(
                            "UPDATE assets SET head_hash = $2, tail_hash = $3 WHERE id = $1"
                        ).bind(id).bind(&head).bind(&tail).execute(&pool_bf).await;
                    }
                    _ => tracing::warn!("补全指纹失败: {}", id),
                }
            }
            tracing::info!("首尾指纹补全完成");
        });
    }

    // 启动时 + 定期清理过期临时文件（失败/超时的分片上传残留）
    {
        let pool_c = app_state.pool.clone();
        let temp_dir = cfg.temp_dir.clone();
        tokio::spawn(async move {
            loop {
                // 标记超过 1 小时仍在 uploading 的会话为 failed
                let _ = sqlx::query(
                    "UPDATE upload_sessions SET status = 'failed' WHERE status = 'uploading' AND created_at < NOW() - INTERVAL '1 hour'"
                ).execute(&pool_c).await;

                // 删除对应的 .part 文件
                if let Ok(mut entries) = tokio::fs::read_dir(&temp_dir).await {
                    while let Ok(Some(entry)) = entries.next_entry().await {
                        let path = entry.path();
                        if path.extension().and_then(|e| e.to_str()) == Some("part") {
                            // 超过 2 小时的临时文件直接删
                            if let Ok(meta) = tokio::fs::metadata(&path).await {
                                if let Ok(modified) = meta.modified() {
                                    if modified.elapsed().unwrap_or_default() > std::time::Duration::from_secs(7200) {
                                        tracing::info!("清理过期临时文件: {}", path.display());
                                        let _ = tokio::fs::remove_file(&path).await;
                                    }
                                }
                            }
                        }
                    }
                }
                tokio::time::sleep(tokio::time::Duration::from_secs(300)).await; // 每 5 分钟检查
            }
        });
    }

    // 回收站自动清理：每小时删除 7 天前的已删除资产
    {
        let pool_gc = app_state.pool.clone();
        let cfg_gc = cfg.clone();
        let vol_gc = vol_mgr.clone();
        tokio::spawn(async move {
            loop {
                tokio::time::sleep(tokio::time::Duration::from_secs(3600)).await;

                let rows: Vec<(uuid::Uuid, String, Option<String>, Option<String>, Option<uuid::Uuid>)> = sqlx::query_as(
                    "SELECT id, file_path, proxy_path, thumb_path, volume_id FROM assets WHERE is_deleted = TRUE AND deleted_at < NOW() - INTERVAL '7 days'"
                ).fetch_all(&pool_gc).await.unwrap_or_default();

                if rows.is_empty() { continue; }
                tracing::info!("回收站自动清理: {} 个过期资产", rows.len());

                let ids: Vec<uuid::Uuid> = rows.iter().map(|r| r.0).collect();
                for (_, file_path, proxy_path, thumb_path, volume_id) in &rows {
                    let raw_abs = vol_gc.resolve_asset_path(file_path, *volume_id).await
                        .unwrap_or_else(|_| cfg_gc.resolve_under_root(file_path));
                    let _ = tokio::fs::remove_file(&raw_abs).await;
                    if let Some(p) = proxy_path { let _ = tokio::fs::remove_file(cfg_gc.resolve_under_root(p)).await; }
                    if let Some(p) = thumb_path { let _ = tokio::fs::remove_file(cfg_gc.resolve_under_root(p)).await; }
                }

                let _ = sqlx::query("DELETE FROM asset_embeddings WHERE asset_id = ANY($1)").bind(&ids).execute(&pool_gc).await;
                let _ = sqlx::query("DELETE FROM embedding_jobs WHERE asset_id = ANY($1)").bind(&ids).execute(&pool_gc).await;
                let _ = sqlx::query("DELETE FROM transcode_jobs WHERE asset_id = ANY($1)").bind(&ids).execute(&pool_gc).await;
                let _ = sqlx::query("DELETE FROM asset_folders WHERE asset_id = ANY($1)").bind(&ids).execute(&pool_gc).await;
                let _ = sqlx::query("DELETE FROM assets WHERE id = ANY($1)").bind(&ids).execute(&pool_gc).await;
                tracing::info!("回收站清理完成");
            }
        });
    }

    // 磁盘空间定时检查（每 60 秒）
    {
        let vm = vol_mgr.clone();
        tokio::spawn(async move {
            loop {
                tokio::time::sleep(tokio::time::Duration::from_secs(60)).await;
                if let Err(e) = vm.refresh_disk_stats().await {
                    tracing::warn!("磁盘空间检查失败: {e}");
                }
            }
        });
    }

    // Bonjour mDNS 广播，让 iOS App 自动发现
    let port = cfg.bind_addr.split(':').last()
        .and_then(|p| p.parse::<u16>().ok())
        .unwrap_or(8080);
    spawn_mdns(port);

    let router = Router::new()
        .route("/", get(web::index))
        .merge(api::routes(app_state))
        .layer(DefaultBodyLimit::disable())
        .layer(CorsLayer::permissive())
        .layer(CatchPanicLayer::new())
        .layer(TraceLayer::new_for_http());

    let listener = tokio::net::TcpListener::bind(&cfg.bind_addr).await?;
    tracing::info!("listening on {}", cfg.bind_addr);
    axum::serve(listener, router).await?;
    Ok(())
}



