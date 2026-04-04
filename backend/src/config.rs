use std::env;
use std::path::{Component, Path, PathBuf};

/// 逻辑规范化路径（不要求路径存在于磁盘）
fn normalize_path(path: &Path) -> PathBuf {
    let mut out = PathBuf::new();
    for comp in path.components() {
        match comp {
            Component::ParentDir => { out.pop(); }
            Component::CurDir => {}
            other => out.push(other),
        }
    }
    out
}

#[derive(Clone, Debug)]
pub struct Config {
    pub bind_addr: String,
    pub database_url: String,

    pub storage_root: PathBuf,
    pub raw_dir: PathBuf,
    pub proxies_dir: PathBuf,
    pub temp_dir: PathBuf,

    // 第五阶段：文件夹与 SMB 同步
    pub albums_dir: PathBuf,  // 用户文件夹根目录 (raw/albums)
    pub inbox_dir: PathBuf,   // 未分类素材目录 (raw/inbox)
    pub trash_dir: PathBuf,   // 软删除素材目录 (raw/.trash)

    pub job_poll_interval_ms: u64,

    pub ffmpeg_bin: String,
    pub ffprobe_bin: String,

    // 第三阶段：AI 服务
    pub ai_service_url: Option<String>,
}

impl Config {
    pub fn from_env() -> anyhow::Result<Self> {
        let bind_addr = env::var("BIND_ADDR").unwrap_or_else(|_| "0.0.0.0:8080".to_string());
        let database_url = env::var("DATABASE_URL")
            .unwrap_or_else(|_| "postgres://user:pass@localhost:5432/mediadb".to_string());

        let storage_root = PathBuf::from(env::var("STORAGE_ROOT").unwrap_or_else(|_| "/data".into()));
        let raw_dir = PathBuf::from(env::var("RAW_DIR").unwrap_or_else(|_| "/data/raw".into()));
        let proxies_dir = PathBuf::from(env::var("PROXIES_DIR").unwrap_or_else(|_| "/data/proxies".into()));
        let temp_dir = PathBuf::from(env::var("TEMP_DIR").unwrap_or_else(|_| "/data/.temp".into()));

        // 第五阶段：文件夹目录
        let albums_dir = PathBuf::from(env::var("ALBUMS_DIR").unwrap_or_else(|_| "/data/raw/albums".into()));
        let inbox_dir = PathBuf::from(env::var("INBOX_DIR").unwrap_or_else(|_| "/data/raw/inbox".into()));
        let trash_dir = PathBuf::from(env::var("TRASH_DIR").unwrap_or_else(|_| "/data/raw/.trash".into()));

        let job_poll_interval_ms = env::var("JOB_POLL_INTERVAL_MS")
            .ok()
            .and_then(|v| v.parse::<u64>().ok())
            .unwrap_or(500);

        let ffmpeg_bin = env::var("FFMPEG_BIN").unwrap_or_else(|_| "ffmpeg".into());
        let ffprobe_bin = env::var("FFPROBE_BIN").unwrap_or_else(|_| "ffprobe".into());

        let ai_service_url = env::var("AI_SERVICE_URL").ok();

        Ok(Self {
            bind_addr,
            database_url,
            storage_root,
            raw_dir,
            proxies_dir,
            temp_dir,
            albums_dir,
            inbox_dir,
            trash_dir,
            job_poll_interval_ms,
            ffmpeg_bin,
            ffprobe_bin,
            ai_service_url,
        })
    }

    pub async fn ensure_dirs(&self) -> anyhow::Result<()> {
        tokio::fs::create_dir_all(&self.raw_dir).await?;
        tokio::fs::create_dir_all(&self.proxies_dir).await?;
        tokio::fs::create_dir_all(&self.temp_dir).await?;
        tokio::fs::create_dir_all(&self.albums_dir).await?;
        tokio::fs::create_dir_all(&self.inbox_dir).await?;
        tokio::fs::create_dir_all(&self.trash_dir).await?;
        Ok(())
    }

    pub fn resolve_under_root(&self, rel: &str) -> PathBuf {
        // rel 形如 /raw/2025/01/a.mp4
        let rel = rel.trim_start_matches('/');
        let joined = self.storage_root.join(rel);
        // 防止 .. 路径遍历：规范化后验证仍在 storage_root 下
        // 使用 components() 逻辑规范化（不要求路径已存在）
        let canonical = normalize_path(&joined);
        let root_canonical = normalize_path(&self.storage_root);
        if canonical.starts_with(&root_canonical) {
            canonical
        } else {
            tracing::warn!(
                "路径遍历检测: rel={}, resolved={}, 回退到 storage_root",
                rel,
                canonical.display()
            );
            root_canonical
        }
    }

    pub fn ensure_parent(p: &Path) -> anyhow::Result<()> {
        if let Some(parent) = p.parent() {
            std::fs::create_dir_all(parent)?;
        }
        Ok(())
    }

    /// 将用户输入的名称转换为文件系统安全的目录名
    /// 规则：替换 Windows/SMB 不支持的字符，去掉首尾空格和点
    pub fn sanitize_fs_name(name: &str) -> String {
        let mut result = String::with_capacity(name.len());
        for c in name.chars() {
            // Windows/SMB 不支持: / \ : * ? " < > |
            // 另外避免控制字符
            let safe = match c {
                '/' | '\\' | ':' | '*' | '?' | '"' | '<' | '>' | '|' => '_',
                c if c.is_control() => '_',
                c => c,
            };
            result.push(safe);
        }
        // 去掉首尾空格和点（Windows 不允许目录名以点或空格结尾）
        let result = result.trim().trim_matches('.').to_string();
        if result.is_empty() {
            "unnamed".to_string()
        } else {
            result
        }
    }

    /// 计算文件夹的完整 fs_path（相对于 albums_dir）
    pub fn build_folder_fs_path(parent_fs_path: Option<&str>, fs_name: &str) -> String {
        match parent_fs_path {
            Some(parent) if !parent.is_empty() => format!("{}/{}", parent, fs_name),
            _ => fs_name.to_string(),
        }
    }
}


