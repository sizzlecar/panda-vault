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
    };

    // 后台 worker：轮询任务队列并转码/提取元数据
    jobs::spawn_worker(app_state.clone());

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



