mod ai;
mod api;
mod chunked_upload;
mod config;
mod db;
mod folder;
mod jobs;
mod media;
mod sync;
mod timestamp;
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

    let app_state = db::AppState {
        cfg: cfg.clone(),
        pool,
        ai_client,
    };

    // 后台 worker：轮询任务队列并转码/提取元数据
    jobs::spawn_worker(app_state.clone());

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



