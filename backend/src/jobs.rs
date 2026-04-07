use chrono::{Datelike, Utc};
use sqlx::{PgPool, Postgres, Transaction};
use tokio::time::{sleep, Duration};
use uuid::Uuid;

use crate::{ai, config::Config, db::AppState, media};

pub fn spawn_worker(state: AppState) {
    // 启动时：为遗漏的资产补创建 embedding 任务
    let state_for_fix = state.clone();
    tokio::spawn(async move {
        if let Err(e) = fix_missing_embedding_jobs(&state_for_fix.pool).await {
            tracing::warn!("修复遗漏的 embedding 任务失败: {e}");
        }
    });

    // 转码 worker
    let state_clone = state.clone();
    tokio::spawn(async move {
        loop {
            let interval = Duration::from_millis(state_clone.cfg.job_poll_interval_ms);
            match try_run_transcode_job(&state_clone).await {
                Ok(true) => continue,
                Ok(false) => sleep(interval).await,
                Err(e) => {
                    tracing::error!("transcode worker 错误: {e:?}");
                    sleep(interval).await;
                }
            }
        }
    });

    // Embedding worker（第三阶段）
    if state.ai_client.is_some() {
        tokio::spawn(async move {
            loop {
                let interval = Duration::from_millis(state.cfg.job_poll_interval_ms);
                match try_run_embedding_job(&state).await {
                    Ok(true) => continue,
                    Ok(false) => sleep(interval).await,
                    Err(e) => {
                        tracing::error!("embedding worker 错误: {e:?}");
                        sleep(interval).await;
                    }
                }
            }
        });
    }
}

/// 启动时修复：为转码成功但没有 embedding 的资产创建/重置任务
async fn fix_missing_embedding_jobs(pool: &PgPool) -> anyhow::Result<u64> {
    // 1. 为完全没有 embedding job 的资产创建任务
    let result1 = sqlx::query(
        r#"
        INSERT INTO embedding_jobs (asset_id, status)
        SELECT a.id, 'pending'
        FROM assets a
        INNER JOIN transcode_jobs tj ON tj.asset_id = a.id AND tj.status = 'succeeded'
        WHERE a.is_deleted = FALSE
          AND NOT EXISTS (SELECT 1 FROM embedding_jobs ej WHERE ej.asset_id = a.id)
        ON CONFLICT DO NOTHING
        "#,
    )
    .execute(pool)
    .await?;
    let count1 = result1.rows_affected();

    // 2. 重置有 embedding job 但没有实际 embedding 数据的任务
    let result2 = sqlx::query(
        r#"
        UPDATE embedding_jobs
        SET status = 'pending', last_error = NULL, started_at = NULL, finished_at = NULL
        WHERE status IN ('failed', 'succeeded')
          AND NOT EXISTS (SELECT 1 FROM asset_embeddings ae WHERE ae.asset_id = embedding_jobs.asset_id)
        "#,
    )
    .execute(pool)
    .await?;
    let count2 = result2.rows_affected();

    let total = count1 + count2;
    if total > 0 {
        tracing::info!("启动修复: 创建 {} 个新任务, 重置 {} 个无效任务", count1, count2);
    }
    Ok(total)
}

/// 公开 API 接口：修复缺失的 embedding 任务
pub async fn fix_missing_embedding_jobs_api(pool: &PgPool) -> anyhow::Result<u64> {
    fix_missing_embedding_jobs(pool).await
}

pub async fn enqueue_transcode_job(pool: &PgPool, asset_id: Uuid) -> anyhow::Result<()> {
    sqlx::query(
        r#"
        INSERT INTO transcode_jobs (asset_id, status)
        VALUES ($1, 'pending')
        "#,
    )
    .bind(asset_id)
    .execute(pool)
    .await?;
    Ok(())
}

#[derive(sqlx::FromRow)]
struct JobRow {
    id: Uuid,
    asset_id: Uuid,
}

#[derive(sqlx::FromRow)]
struct AssetPathRow {
    file_path: String,
    created_at: Option<chrono::NaiveDateTime>,
    volume_id: Option<Uuid>,
}

async fn try_run_transcode_job(state: &AppState) -> anyhow::Result<bool> {
    let mut tx = state.pool.begin().await?;
    let job = lock_one_transcode_job(&mut tx).await?;
    let Some(job) = job else {
        tx.commit().await?;
        return Ok(false);
    };

    mark_transcode_running(&mut tx, job.id).await?;
    tx.commit().await?;

    // 加载 asset 路径
    let asset = sqlx::query_as::<_, AssetPathRow>(
        r#"
        SELECT file_path, created_at, volume_id
        FROM assets
        WHERE id = $1
        "#,
    )
    .bind(job.asset_id)
    .fetch_one(&state.pool)
    .await?;

    let input_abs = state.volumes.resolve_asset_path(&asset.file_path, asset.volume_id).await?;

    // 先提取元数据并写回（二期）
    if let Ok(info) = media::probe(&state.cfg, &input_abs).await {
        sqlx::query(
            r#"
            UPDATE assets
            SET shoot_at = COALESCE(shoot_at, $2),
                duration_sec = COALESCE(duration_sec, $3),
                width = COALESCE(width, $4),
                height = COALESCE(height, $5)
            WHERE id = $1
            "#,
        )
        .bind(job.asset_id)
        .bind(info.shoot_at)
        .bind(info.duration_sec)
        .bind(info.width)
        .bind(info.height)
        .execute(&state.pool)
        .await?;
    }

    // 生成 proxy（图片转 webp，视频跳过——局域网直接播原始文件）
    let (yyyy, mm) = {
        let dt = asset.created_at.unwrap_or_else(|| Utc::now().naive_utc());
        (dt.date().year(), dt.date().month())
    };

    let ext = guess_proxy_ext(&input_abs);
    let is_video = ext != "webp";

    // 补生成缩略图（scan 时可能因缺 ffmpeg 而失败）
    let need_thumb: bool = sqlx::query_scalar::<_, bool>(
        "SELECT thumb_path IS NULL FROM assets WHERE id = $1"
    )
    .bind(job.asset_id)
    .fetch_one(&state.pool)
    .await
    .unwrap_or(false);

    if need_thumb {
        let thumb_rel = format!("/proxies/{:04}/{:02}/{}_thumb.jpg", yyyy, mm, job.asset_id);
        let thumb_abs = state.cfg.resolve_under_root(&thumb_rel);
        Config::ensure_parent(&thumb_abs)?;
        if media::try_generate_thumbnail(&state.cfg, &input_abs, &thumb_abs).await.is_ok() {
            sqlx::query("UPDATE assets SET thumb_path = $2 WHERE id = $1")
                .bind(job.asset_id)
                .bind(&thumb_rel)
                .execute(&state.pool)
                .await?;
        }
    }

    let transcode_res = if is_video {
        // 视频不转码，直接标记成功，播放时用原始文件
        Ok(())
    } else {
        let proxy_rel = format!("/proxies/{:04}/{:02}/{}_720p.{ext}", yyyy, mm, job.asset_id);
        let proxy_abs = state.cfg.resolve_under_root(&proxy_rel);
        Config::ensure_parent(&proxy_abs)?;
        let res = transcode_image_to_webp(&state.cfg, &input_abs, &proxy_abs).await;
        if res.is_ok() {
            sqlx::query("UPDATE assets SET proxy_path = $2 WHERE id = $1")
                .bind(job.asset_id)
                .bind(&proxy_rel)
                .execute(&state.pool)
                .await?;
        }
        res
    };

    match transcode_res {
        Ok(()) => {
            // proxy_path 已在上面的图片分支更新，视频不需要 proxy
            mark_transcode_succeeded(&state.pool, job.id).await?;

            // 第三阶段：转码成功后自动创建 embedding 任务
            // 无论 ai_client 是否存在都创建任务，这样 AI 服务启动后可以处理
            if let Err(e) = ai::enqueue_embedding_job(&state.pool, job.asset_id).await {
                tracing::warn!("创建 embedding 任务失败: {e}");
            }

            Ok(true)
        }
        Err(e) => {
            mark_transcode_failed(&state.pool, job.id, &e.to_string()).await?;
            Ok(true)
        }
    }
}

async fn lock_one_transcode_job(tx: &mut Transaction<'_, Postgres>) -> anyhow::Result<Option<JobRow>> {
    let job = sqlx::query_as::<_, JobRow>(
        r#"
        SELECT id, asset_id
        FROM transcode_jobs
        WHERE status = 'pending'
        ORDER BY created_at ASC
        FOR UPDATE SKIP LOCKED
        LIMIT 1
        "#,
    )
    .fetch_optional(&mut **tx)
    .await?;
    Ok(job)
}

async fn mark_transcode_running(tx: &mut Transaction<'_, Postgres>, job_id: Uuid) -> anyhow::Result<()> {
    sqlx::query(
        r#"
        UPDATE transcode_jobs
        SET status = 'running',
            started_at = NOW(),
            last_error = NULL
        WHERE id = $1
        "#,
    )
    .bind(job_id)
    .execute(&mut **tx)
    .await?;
    Ok(())
}

async fn mark_transcode_succeeded(pool: &PgPool, job_id: Uuid) -> anyhow::Result<()> {
    sqlx::query(
        r#"
        UPDATE transcode_jobs
        SET status = 'succeeded',
            finished_at = NOW()
        WHERE id = $1
        "#,
    )
    .bind(job_id)
    .execute(pool)
    .await?;
    Ok(())
}

async fn mark_transcode_failed(pool: &PgPool, job_id: Uuid, err: &str) -> anyhow::Result<()> {
    sqlx::query(
        r#"
        UPDATE transcode_jobs
        SET status = 'failed',
            finished_at = NOW(),
            last_error = $2
        WHERE id = $1
        "#,
    )
    .bind(job_id)
    .bind(err)
    .execute(pool)
    .await?;
    Ok(())
}

fn guess_proxy_ext(input: &std::path::Path) -> &'static str {
    let mt = mime_guess::from_path(input).first_or_octet_stream();
    if mt.type_() == mime::IMAGE {
        "webp"
    } else {
        "mp4"
    }
}

async fn transcode_video_to_720p(cfg: &Config, input: &std::path::Path, output: &std::path::Path) -> anyhow::Result<()> {
    let status = tokio::process::Command::new(&cfg.ffmpeg_bin)
        .arg("-y")
        .arg("-hide_banner")
        .arg("-loglevel")
        .arg("error")
        .arg("-i")
        .arg(input)
        .arg("-vf")
        .arg("scale='min(1280,iw)':-2")
        .arg("-c:v")
        .arg("libx264")
        .arg("-preset")
        .arg("veryfast")
        .arg("-crf")
        .arg("23")
        .arg("-movflags")
        .arg("+faststart")
        .arg("-c:a")
        .arg("aac")
        .arg("-b:a")
        .arg("128k")
        .arg(output)
        .status()
        .await?;

    if !status.success() {
        anyhow::bail!("ffmpeg 转码失败: exit={status}");
    }
    Ok(())
}

async fn transcode_image_to_webp(cfg: &Config, input: &std::path::Path, output: &std::path::Path) -> anyhow::Result<()> {
    // 优先 sips（macOS，完美支持 HEIC/HDR），失败回退 ffmpeg
    let sips_ok = tokio::process::Command::new("sips")
        .arg("--resampleWidth").arg("1280")
        .arg("-s").arg("format").arg("jpeg")
        .arg(input)
        .arg("--out").arg(output)
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .await
        .map(|s| s.success())
        .unwrap_or(false);

    if !sips_ok {
        let status = tokio::process::Command::new(&cfg.ffmpeg_bin)
            .arg("-y")
            .arg("-hide_banner")
            .arg("-loglevel").arg("error")
            .arg("-i").arg(input)
            .arg("-vf").arg("scale='min(1280,iw)':-2")
            .arg("-c:v").arg("libwebp")
            .arg("-q:v").arg("80")
            .arg(output)
            .status()
            .await?;
        if !status.success() {
            anyhow::bail!("ffmpeg 图片转码失败: exit={status}");
        }
    }
    Ok(())
}

// ============ 第三阶段：Embedding Worker ============

#[derive(sqlx::FromRow)]
struct EmbeddingJobRow {
    id: Uuid,
    asset_id: Uuid,
}

#[derive(sqlx::FromRow)]
struct AssetForEmbedding {
    file_path: String,
    thumb_path: Option<String>,
    volume_id: Option<Uuid>,
}

async fn try_run_embedding_job(state: &AppState) -> anyhow::Result<bool> {
    let Some(ref ai_client) = state.ai_client else {
        return Ok(false);
    };

    let mut tx = state.pool.begin().await?;
    let job = lock_one_embedding_job(&mut tx).await?;
    let Some(job) = job else {
        tx.commit().await?;
        return Ok(false);
    };

    mark_embedding_running(&mut tx, job.id).await?;
    tx.commit().await?;

    // 加载资产信息
    let asset = sqlx::query_as::<_, AssetForEmbedding>(
        r#"
        SELECT file_path, thumb_path, volume_id
        FROM assets
        WHERE id = $1
        "#,
    )
    .bind(job.asset_id)
    .fetch_one(&state.pool)
    .await?;

    // 优先使用缩略图，否则使用原始文件。
    // 但历史数据里可能存在：DB 有 thumb_path，但磁盘文件已不存在（例如之前 ffmpeg 失败/被清理）。
    // 这种情况下自动从 raw 重新生成缩略图，失败则回退到 raw 文件继续 embedding，避免 AI 端 404。
    let raw_path = state.volumes.resolve_asset_path(&asset.file_path, asset.volume_id).await?;
    let source_path = if let Some(ref thumb_rel) = asset.thumb_path {
        let thumb_abs = state.volumes.resolve_asset_path(thumb_rel, asset.volume_id).await?;
        if tokio::fs::metadata(&thumb_abs).await.is_ok() {
            thumb_abs
        } else {
            // 尝试重建缩略图
            if let Err(e) = crate::media::try_generate_thumbnail(&state.cfg, &raw_path, &thumb_abs).await {
                tracing::warn!(
                    "thumb 缺失且重建失败，将回退到 raw: thumb={}, raw={}, err={}",
                    thumb_abs.display(),
                    raw_path.display(),
                    e
                );
                raw_path.clone()
            } else {
                thumb_abs
            }
        }
    } else {
        raw_path.clone()
    };

    // 转换为绝对路径，避免 AI 服务因工作目录不同而找不到文件
    let source_path_abs = source_path.canonicalize().unwrap_or(source_path.clone());
    let source_path_str = {
        let s = source_path_abs.to_string_lossy().to_string();
        // Windows canonicalize 产生 \\?\ 前缀，去掉以兼容 AI 服务
        if s.starts_with(r"\\?\") { s[4..].to_string() } else { s }
    };

    // 判断是图片还是视频
    let mt = mime_guess::from_path(&source_path).first_or_octet_stream();
    let is_video = mt.type_() == mime::VIDEO;

    let result = if is_video {
        // 视频：ffmpeg 均匀抽 4 帧，每帧单独 embedding
        let frame_paths = extract_video_frames(&state.cfg, &source_path, 4).await;
        if frame_paths.is_empty() {
            // 抽帧失败，回退到缩略图单帧
            match ai_client.embed_image_path(&source_path_str).await {
                Ok(emb) => ai::save_embedding(&state.pool, job.asset_id, &emb, "video_frame", 0).await,
                Err(e) => Err(e),
            }
        } else {
            let frame_strs: Vec<String> = frame_paths.iter().map(|p| p.to_string_lossy().to_string()).collect();
            let embeddings = ai_client.embed_video_frames(&frame_strs).await?;
            let mut save_err = None;
            for (i, emb) in embeddings.iter().enumerate() {
                if let Err(e) = ai::save_embedding(&state.pool, job.asset_id, emb, "video_frame", i as i32).await {
                    save_err = Some(e);
                }
            }
            // 清理临时帧文件
            for p in &frame_paths {
                let _ = tokio::fs::remove_file(p).await;
            }
            match save_err {
                Some(e) => Err(e),
                None => Ok(()),
            }
        }
    } else {
        // 图片：直接提取
        match ai_client.embed_image_path(&source_path_str).await {
            Ok(embedding) => ai::save_embedding(&state.pool, job.asset_id, &embedding, "image", 0).await,
            Err(e) => Err(e),
        }
    };

    match result {
        Ok(()) => {
            mark_embedding_succeeded(&state.pool, job.id).await?;
            tracing::info!("embedding 完成: asset={}", job.asset_id);
            Ok(true)
        }
        Err(e) => {
            mark_embedding_failed(&state.pool, job.id, &e.to_string()).await?;
            tracing::warn!("embedding 失败: asset={}, err={}", job.asset_id, e);
            Ok(true)
        }
    }
}

/// 用 ffmpeg 从视频中均匀抽取 N 帧
async fn extract_video_frames(cfg: &crate::config::Config, video_path: &std::path::Path, num_frames: u32) -> Vec<std::path::PathBuf> {
    // 先用 ffprobe 获取时长
    let duration = {
        let output = tokio::process::Command::new(&cfg.ffprobe_bin)
            .args(["-v", "error", "-show_entries", "format=duration", "-of", "default=noprint_wrappers=1:nokey=1"])
            .arg(video_path)
            .output()
            .await;
        match output {
            Ok(o) => {
                let s = String::from_utf8_lossy(&o.stdout);
                s.trim().parse::<f64>().unwrap_or(10.0)
            }
            Err(_) => 10.0,
        }
    };

    let interval = duration / (num_frames as f64 + 1.0);
    let mut frame_paths = Vec::new();

    for i in 1..=num_frames {
        let timestamp = interval * i as f64;
        let out_path = cfg.temp_dir.join(format!("frame_{}_{}.jpg", std::process::id(), i));

        let status = tokio::process::Command::new(&cfg.ffmpeg_bin)
            .args(["-y", "-ss", &format!("{:.2}", timestamp), "-i"])
            .arg(video_path)
            .args(["-vframes", "1", "-q:v", "2"])
            .arg(&out_path)
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .status()
            .await;

        if status.is_ok() && out_path.exists() {
            frame_paths.push(out_path);
        }
    }

    frame_paths
}

async fn lock_one_embedding_job(tx: &mut Transaction<'_, Postgres>) -> anyhow::Result<Option<EmbeddingJobRow>> {
    let job = sqlx::query_as::<_, EmbeddingJobRow>(
        r#"
        SELECT id, asset_id
        FROM embedding_jobs
        WHERE status = 'pending'
        ORDER BY created_at ASC
        FOR UPDATE SKIP LOCKED
        LIMIT 1
        "#,
    )
    .fetch_optional(&mut **tx)
    .await?;
    Ok(job)
}

async fn mark_embedding_running(tx: &mut Transaction<'_, Postgres>, job_id: Uuid) -> anyhow::Result<()> {
    sqlx::query(
        r#"
        UPDATE embedding_jobs
        SET status = 'running',
            started_at = NOW(),
            last_error = NULL
        WHERE id = $1
        "#,
    )
    .bind(job_id)
    .execute(&mut **tx)
    .await?;
    Ok(())
}

async fn mark_embedding_succeeded(pool: &PgPool, job_id: Uuid) -> anyhow::Result<()> {
    sqlx::query(
        r#"
        UPDATE embedding_jobs
        SET status = 'succeeded',
            finished_at = NOW()
        WHERE id = $1
        "#,
    )
    .bind(job_id)
    .execute(pool)
    .await?;
    Ok(())
}

async fn mark_embedding_failed(pool: &PgPool, job_id: Uuid, err: &str) -> anyhow::Result<()> {
    sqlx::query(
        r#"
        UPDATE embedding_jobs
        SET status = 'failed',
            finished_at = NOW(),
            last_error = $2
        WHERE id = $1
        "#,
    )
    .bind(job_id)
    .bind(err)
    .execute(pool)
    .await?;
    Ok(())
}

