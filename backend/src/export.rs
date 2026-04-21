//! 剪辑工程包导出
//!
//! 用户在 iOS 选一批 asset → 调 POST /api/export → 这里把它们打成 zip
//! 写到 `cfg.export_dir`（默认 `STORAGE_ROOT/exports/`）
//! Mac 端直接 Finder 打开导出目录就能用；也可以 HTTP 下载（/exports/*.zip）
//!
//! zip 内部结构：
//!   media/
//!     <original_filename>           # 大文件按原始 filename 放根下，重名时加 id 前缀
//!     <uuid-prefix>_<filename>      # 重名去冲
//!   metadata.json                   # 每个 asset 的元数据（剪辑时脚本用）
//!
//! 压缩策略：
//!   - 媒体文件本身已经压缩（H.264/HEIC/JPEG），zip 再压一遍只浪费 CPU 且收益几乎为 0
//!   - 所以媒体文件用 Stored（不压缩），metadata.json 用 Deflated
//!   - 打包瞬时完成 —— APFS 不支持 zip clonefile，但纯复制也是磁盘带宽瓶颈，对 iOS 客户端是可接受的
//!
//! 大文件策略（对齐用户"GB 级"需求）：
//!   - 无单文件大小上限 —— 打 100GB 也行
//!   - 使用 `zip64` 自动触发（当总量 > 4GB 时）
//!   - 流式读写（64KB buffer）—— 内存占用固定
//!   - 后端异步 tokio::spawn_blocking，不阻塞 axum worker

use axum::{
    extract::{Path, State},
    http::StatusCode,
    response::{IntoResponse, Response},
    Json,
};
use chrono::NaiveDateTime;
use serde::{Deserialize, Serialize};
use std::io::{Read, Write};
use std::path::PathBuf;
use uuid::Uuid;

use crate::api::{json_err, AssetRow};
use crate::db::AppState;

#[derive(Debug, Deserialize)]
pub struct CreateExportRequest {
    pub asset_ids: Vec<Uuid>,
    /// 可选的名称前缀 —— 不填就用"pandavault"
    pub name: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct ExportInfo {
    /// zip 文件名（含扩展名 · 不含目录）
    pub filename: String,
    /// 服务端绝对路径（Mac 上打开 Finder 用）
    pub absolute_path: String,
    /// HTTP 下载路径（相对 baseURL）—— 例如 "/exports/xxx.zip"
    pub download_path: String,
    /// 字节数
    pub size_bytes: i64,
    /// 打包耗时毫秒
    pub duration_ms: i64,
    /// 包含的 asset 数量
    pub asset_count: usize,
    /// 创建时间（文件 mtime）
    #[serde(serialize_with = "crate::timestamp::serialize_opt")]
    pub created_at: Option<NaiveDateTime>,
}

#[derive(Debug, Serialize)]
struct AssetMetadata {
    id: Uuid,
    filename: String,
    archive_path: String,              // 在 zip 内的相对路径（e.g. "media/xxx.mov"）
    size_bytes: i64,
    file_hash: String,
    #[serde(serialize_with = "crate::timestamp::serialize_opt")]
    shoot_at: Option<NaiveDateTime>,
    #[serde(serialize_with = "crate::timestamp::serialize_opt")]
    created_at: Option<NaiveDateTime>,
    duration_sec: Option<i32>,
    width: Option<i32>,
    height: Option<i32>,
    note: Option<String>,
    /// 用户归属的文件夹路径（如 "2026春节/精修图"），空代表未分类
    folder_path: Option<String>,
}

#[derive(Debug, Serialize)]
struct ExportManifest {
    /// 导出时间 RFC3339
    exported_at: String,
    /// 来源
    source: String,
    /// PandaVault 版本（方便后续解析脚本做兼容）
    app_version: String,
    /// 资产列表
    assets: Vec<AssetMetadata>,
}

// ---- Handlers ----

pub async fn create_export(
    State(state): State<AppState>,
    Json(req): Json<CreateExportRequest>,
) -> Response {
    if req.asset_ids.is_empty() {
        return json_err(StatusCode::BAD_REQUEST, "asset_ids 不能为空").into_response();
    }
    if req.asset_ids.len() > 5000 {
        return json_err(StatusCode::BAD_REQUEST, "一次最多 5000 个 asset").into_response();
    }

    let t0 = std::time::Instant::now();

    // 拉资产详情 + 所属文件夹
    let assets = match fetch_assets_with_folder(&state, &req.asset_ids).await {
        Ok(v) => v,
        Err(e) => {
            tracing::error!("export[fetch-fail] {:#}", e);
            return json_err(StatusCode::INTERNAL_SERVER_ERROR, format!("读取资产失败: {e}")).into_response();
        }
    };

    if assets.is_empty() {
        return json_err(StatusCode::NOT_FOUND, "未找到任何匹配的 asset").into_response();
    }

    // 预解析所有绝对路径（在打包前失败得早）
    let mut paths: Vec<(AssetRow, Option<String>, PathBuf)> = Vec::with_capacity(assets.len());
    for (a, folder_path) in assets {
        let abs = match state.volumes.resolve_asset_path(&a.file_path, a.volume_id).await {
            Ok(p) => p,
            Err(e) => {
                tracing::warn!("export[skip] 无法解析路径 id={} err={:#}", a.id, e);
                continue;
            }
        };
        if !abs.exists() {
            tracing::warn!("export[skip] 文件不存在 id={} path={}", a.id, abs.display());
            continue;
        }
        paths.push((a, folder_path, abs));
    }

    if paths.is_empty() {
        return json_err(StatusCode::NOT_FOUND, "所有 asset 的原始文件都不存在").into_response();
    }

    // 生成 zip 文件名
    let name_slug = req
        .name
        .as_deref()
        .map(sanitize_name)
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "pandavault".to_string());
    let ts = chrono::Local::now().format("%Y%m%d-%H%M%S").to_string();
    let zip_name = format!("{name_slug}_{ts}.zip");
    let out_path = state.cfg.export_dir.join(&zip_name);

    tracing::info!(
        "export[start] 打包 {} 个 asset → {}",
        paths.len(),
        out_path.display()
    );

    // 打包放 spawn_blocking —— zip2 是同步 API，别阻塞 axum
    let out_path_clone = out_path.clone();
    let export_dir_display = state.cfg.export_dir.display().to_string();
    let result = tokio::task::spawn_blocking(move || -> std::io::Result<(i64, usize)> {
        build_zip(&out_path_clone, paths)
    })
    .await;

    let (size_bytes, asset_count) = match result {
        Ok(Ok(v)) => v,
        Ok(Err(e)) => {
            tracing::error!("export[zip-fail] {}", e);
            let _ = tokio::fs::remove_file(&out_path).await;
            return json_err(StatusCode::INTERNAL_SERVER_ERROR, format!("打包失败: {e}")).into_response();
        }
        Err(e) => {
            tracing::error!("export[task-fail] {}", e);
            let _ = tokio::fs::remove_file(&out_path).await;
            return json_err(StatusCode::INTERNAL_SERVER_ERROR, format!("打包任务失败: {e}")).into_response();
        }
    };

    let ms = t0.elapsed().as_millis() as i64;
    tracing::info!(
        "export[done] name={} size={}MB ms={} count={} dir={}",
        zip_name,
        size_bytes / 1024 / 1024,
        ms,
        asset_count,
        export_dir_display
    );

    let info = ExportInfo {
        filename: zip_name.clone(),
        absolute_path: out_path.display().to_string(),
        download_path: format!("/exports/{zip_name}"),
        size_bytes,
        duration_ms: ms,
        asset_count,
        created_at: Some(chrono::Local::now().naive_local()),
    };
    (StatusCode::OK, Json(info)).into_response()
}

pub async fn list_exports(State(state): State<AppState>) -> Response {
    let dir = state.cfg.export_dir.clone();
    let mut entries = match tokio::fs::read_dir(&dir).await {
        Ok(e) => e,
        Err(e) => {
            tracing::error!("export[list-fail] {:#}", e);
            return json_err(StatusCode::INTERNAL_SERVER_ERROR, format!("读取导出目录失败: {e}")).into_response();
        }
    };
    let mut out: Vec<ExportInfo> = Vec::new();
    while let Ok(Some(entry)) = entries.next_entry().await {
        let path = entry.path();
        if path.extension().and_then(|e| e.to_str()) != Some("zip") { continue; }
        let meta = match entry.metadata().await {
            Ok(m) => m,
            Err(_) => continue,
        };
        let filename = path.file_name().and_then(|n| n.to_str()).unwrap_or("").to_string();
        let mtime = meta
            .modified()
            .ok()
            .and_then(|t| {
                t.duration_since(std::time::UNIX_EPOCH).ok().and_then(|d| {
                    chrono::DateTime::from_timestamp(d.as_secs() as i64, d.subsec_nanos())
                        .map(|dt| dt.naive_local())
                })
            });
        out.push(ExportInfo {
            filename: filename.clone(),
            absolute_path: path.display().to_string(),
            download_path: format!("/exports/{filename}"),
            size_bytes: meta.len() as i64,
            duration_ms: 0,
            asset_count: 0, // 列表接口不打开 zip 读 manifest，省 I/O
            created_at: mtime,
        });
    }
    // 新的在前
    out.sort_by(|a, b| b.created_at.cmp(&a.created_at));
    (StatusCode::OK, Json(out)).into_response()
}

pub async fn delete_export(
    State(state): State<AppState>,
    Path(filename): Path<String>,
) -> Response {
    // 路径安全 —— 只接受没有 / .. 的纯文件名
    if filename.contains('/') || filename.contains("..") || !filename.ends_with(".zip") {
        return json_err(StatusCode::BAD_REQUEST, "非法文件名").into_response();
    }
    let path = state.cfg.export_dir.join(&filename);
    match tokio::fs::remove_file(&path).await {
        Ok(_) => {
            tracing::info!("export[delete] {}", path.display());
            (StatusCode::NO_CONTENT, ()).into_response()
        }
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            json_err(StatusCode::NOT_FOUND, "导出不存在").into_response()
        }
        Err(e) => {
            tracing::error!("export[delete-fail] {}: {}", path.display(), e);
            json_err(StatusCode::INTERNAL_SERVER_ERROR, format!("删除失败: {e}")).into_response()
        }
    }
}

// ---- Helpers ----

async fn fetch_assets_with_folder(
    state: &AppState,
    ids: &[Uuid],
) -> anyhow::Result<Vec<(AssetRow, Option<String>)>> {
    // 先批量拉 asset 行（带 volume_id / note）
    let rows: Vec<AssetRow> = sqlx::query_as::<_, AssetRow>(
        r#"SELECT id, filename, file_path, proxy_path, thumb_path, file_hash, size_bytes,
                  shoot_at, created_at, duration_sec, width, height, volume_id, note
             FROM assets
            WHERE id = ANY($1) AND deleted_at IS NULL"#,
    )
    .bind(ids)
    .fetch_all(&state.pool)
    .await?;

    // 拉每个 asset 的第一个 folder（一个 asset 可能在多个 folder 里，这里就拿一个用于展示）
    // 查询：asset_folders LEFT JOIN folders 得到文件夹路径
    let folder_map: std::collections::HashMap<Uuid, String> = {
        let rows: Vec<(Uuid, String)> = sqlx::query_as::<_, (Uuid, String)>(
            r#"SELECT DISTINCT ON (af.asset_id) af.asset_id, f.name
                 FROM asset_folders af
                 JOIN folders f ON f.id = af.folder_id
                WHERE af.asset_id = ANY($1)
                ORDER BY af.asset_id, af.added_at ASC"#,
        )
        .bind(ids)
        .fetch_all(&state.pool)
        .await
        .unwrap_or_default();
        rows.into_iter().collect()
    };

    Ok(rows.into_iter().map(|r| {
        let fp = folder_map.get(&r.id).cloned();
        (r, fp)
    }).collect())
}

/// 把 asset 列表写进一个 zip 文件（同步，要跑在 spawn_blocking）
/// 返回 (字节数, 成功写入的 asset 数)
fn build_zip(
    out_path: &std::path::Path,
    items: Vec<(AssetRow, Option<String>, PathBuf)>,
) -> std::io::Result<(i64, usize)> {
    if let Some(parent) = out_path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let file = std::fs::File::create(out_path)?;
    let buf = std::io::BufWriter::with_capacity(1024 * 1024, file); // 1MB write buf
    let mut zip = zip::ZipWriter::new(buf);

    // 媒体文件用 Stored —— 已经压缩过，再压没收益
    let stored = zip::write::SimpleFileOptions::default()
        .compression_method(zip::CompressionMethod::Stored)
        .large_file(true); // 关键：> 4GB 自动 zip64

    let mut metadata: Vec<AssetMetadata> = Vec::with_capacity(items.len());
    let mut used_names: std::collections::HashSet<String> = std::collections::HashSet::new();
    let mut written_count: usize = 0;

    for (asset, folder_path, abs_path) in items {
        // zip 内 archive path：media/<filename>，冲突时加 id 前缀
        let base_name = &asset.filename;
        let archive_path = if used_names.contains(base_name) {
            format!("media/{}__{}", &asset.id.simple().to_string()[..8], base_name)
        } else {
            format!("media/{}", base_name)
        };
        used_names.insert(base_name.clone());

        // 写 zip 条目
        if let Err(e) = zip.start_file::<_, ()>(&archive_path, stored) {
            tracing::error!("export[zip-entry-fail] path={} err={}", archive_path, e);
            continue;
        }
        let mut src = match std::fs::File::open(&abs_path) {
            Ok(f) => f,
            Err(e) => {
                tracing::warn!("export[skip-open] id={} path={} err={}", asset.id, abs_path.display(), e);
                continue;
            }
        };
        // 64KB 流式拷贝
        let mut buf = [0u8; 64 * 1024];
        loop {
            match src.read(&mut buf) {
                Ok(0) => break,
                Ok(n) => {
                    if let Err(e) = zip.write_all(&buf[..n]) {
                        tracing::error!("export[zip-write-fail] path={} err={}", archive_path, e);
                        break;
                    }
                }
                Err(e) => {
                    tracing::error!("export[zip-read-fail] path={} err={}", abs_path.display(), e);
                    break;
                }
            }
        }

        metadata.push(AssetMetadata {
            id: asset.id,
            filename: asset.filename.clone(),
            archive_path,
            size_bytes: asset.size_bytes,
            file_hash: asset.file_hash.clone(),
            shoot_at: asset.shoot_at,
            created_at: asset.created_at,
            duration_sec: asset.duration_sec,
            width: asset.width,
            height: asset.height,
            note: asset.note.clone(),
            folder_path,
        });
        written_count += 1;
    }

    // 写 metadata.json（deflate —— 文本压缩有意义）
    let deflated = zip::write::SimpleFileOptions::default()
        .compression_method(zip::CompressionMethod::Deflated)
        .compression_level(Some(6));

    let manifest = ExportManifest {
        exported_at: chrono::Local::now().to_rfc3339(),
        source: "PandaVault".to_string(),
        app_version: env!("CARGO_PKG_VERSION").to_string(),
        assets: metadata,
    };
    if let Err(e) = zip.start_file::<_, ()>("metadata.json", deflated) {
        tracing::error!("export[manifest-entry-fail] {}", e);
    } else {
        let json = serde_json::to_vec_pretty(&manifest).unwrap_or_else(|_| b"{}".to_vec());
        let _ = zip.write_all(&json);
    }

    zip.finish()?;

    let size = std::fs::metadata(out_path).map(|m| m.len() as i64).unwrap_or(0);
    Ok((size, written_count))
}

/// 清掉 / \ : * ? " < > | 等非法字符，trim 空格
fn sanitize_name(name: &str) -> String {
    let mut out = String::with_capacity(name.len());
    for c in name.chars() {
        match c {
            '/' | '\\' | ':' | '*' | '?' | '"' | '<' | '>' | '|' => out.push('_'),
            c if c.is_control() => {}
            c => out.push(c),
        }
    }
    out.trim().trim_matches('.').to_string()
}
