//! AI 服务集成模块
//!
//! 与 Ferrum 推理服务通信（OpenAI /v1/embeddings 标准格式）

use anyhow::{anyhow, Result};
use serde::{Deserialize, Serialize};
use sqlx::PgPool;
use uuid::Uuid;

/// AI 服务客户端（兼容 OpenAI /v1/embeddings 格式）
#[derive(Clone)]
pub struct AiClient {
    base_url: String,
    model: String,
    client: reqwest::Client,
}

impl AiClient {
    pub fn new(base_url: &str) -> Self {
        let model = std::env::var("CLIP_MODEL")
            .unwrap_or_else(|_| "OFA-Sys/chinese-clip-vit-base-patch16".to_string());
        Self {
            base_url: base_url.trim_end_matches('/').to_string(),
            model,
            client: reqwest::Client::builder()
                .timeout(std::time::Duration::from_secs(120))
                .no_proxy()
                .build()
                .expect("reqwest client 创建失败"),
        }
    }

    /// 从本地图片路径提取向量
    pub async fn embed_image_path(&self, path: &str) -> Result<Vec<f32>> {
        let req = EmbeddingsRequest {
            model: self.model.clone(),
            input: EmbeddingInput::Single(InputItem::Image {
                image: path.to_string(),
            }),
        };
        let embeddings = self.call_embeddings(&req).await?;
        embeddings
            .into_iter()
            .next()
            .map(|d| d.embedding)
            .ok_or_else(|| anyhow!("AI 返回空 embeddings"))
    }

    /// 从本地视频路径提取多帧向量
    /// 后端用 ffmpeg 均匀抽帧，每帧单独发给 ferrum
    pub async fn embed_video_frames(&self, frame_paths: &[String]) -> Result<Vec<Vec<f32>>> {
        let mut embeddings = Vec::new();
        for path in frame_paths {
            match self.embed_image_path(path).await {
                Ok(emb) => embeddings.push(emb),
                Err(e) => tracing::warn!("帧 embedding 失败 {}: {}", path, e),
            }
        }
        Ok(embeddings)
    }

    /// 从文本提取向量（用于语义搜索）
    pub async fn embed_text(&self, text: &str) -> Result<Vec<f32>> {
        let req = EmbeddingsRequest {
            model: self.model.clone(),
            input: EmbeddingInput::Single(InputItem::Text(text.to_string())),
        };
        let embeddings = self.call_embeddings(&req).await?;
        embeddings
            .into_iter()
            .next()
            .map(|d| d.embedding)
            .ok_or_else(|| anyhow!("AI 返回空 embeddings"))
    }

    /// 健康检查
    pub async fn health(&self) -> Result<bool> {
        let resp = self
            .client
            .get(format!("{}/health", self.base_url))
            .send()
            .await?;
        Ok(resp.status().is_success())
    }

    /// 调用 /v1/embeddings 通用方法
    async fn call_embeddings(&self, req: &EmbeddingsRequest) -> Result<Vec<EmbeddingData>> {
        let resp = self
            .client
            .post(format!("{}/v1/embeddings", self.base_url))
            .json(req)
            .send()
            .await?;

        if !resp.status().is_success() {
            let text = resp.text().await.unwrap_or_default();
            return Err(anyhow!("AI embeddings 请求失败: {}", text));
        }

        let body: EmbeddingsResponse = resp.json().await?;
        Ok(body.data)
    }
}

// ============ OpenAI /v1/embeddings 请求/响应结构 ============

#[derive(Serialize)]
struct EmbeddingsRequest {
    model: String,
    input: EmbeddingInput,
}

#[derive(Serialize)]
#[serde(untagged)]
enum EmbeddingInput {
    Single(InputItem),
    #[allow(dead_code)]
    Batch(Vec<InputItem>),
}

#[derive(Serialize)]
#[serde(untagged)]
enum InputItem {
    /// 纯文本输入: "海边日落"
    Text(String),
    /// 图片路径输入: { "image": "/data/raw/..." }
    Image { image: String },
}

#[derive(Deserialize)]
struct EmbeddingsResponse {
    data: Vec<EmbeddingData>,
}

#[derive(Deserialize)]
struct EmbeddingData {
    embedding: Vec<f32>,
}

// ============ 数据库操作（不变）============

/// 将向量保存到数据库
pub async fn save_embedding(
    pool: &PgPool,
    asset_id: Uuid,
    embedding: &[f32],
    source_type: &str,
    frame_index: i32,
) -> Result<()> {
    let vec_str = format!(
        "[{}]",
        embedding
            .iter()
            .map(|f| f.to_string())
            .collect::<Vec<_>>()
            .join(",")
    );

    sqlx::query(
        r#"
        INSERT INTO asset_embeddings (asset_id, embedding, source_type, frame_index)
        VALUES ($1, $2::vector, $3, $4)
        ON CONFLICT (asset_id, source_type, frame_index) DO UPDATE SET embedding = EXCLUDED.embedding
        "#,
    )
    .bind(asset_id)
    .bind(&vec_str)
    .bind(source_type)
    .bind(frame_index)
    .execute(pool)
    .await?;

    Ok(())
}

/// 语义搜索结果
#[derive(Debug, Serialize)]
pub struct SemanticSearchResult {
    pub asset_id: Uuid,
    pub similarity: f64,
}

/// 语义搜索：输入文本向量，返回最相似的资产
pub async fn semantic_search(
    pool: &PgPool,
    query_embedding: &[f32],
    limit: i64,
) -> Result<Vec<SemanticSearchResult>> {
    let vec_str = format!(
        "[{}]",
        query_embedding
            .iter()
            .map(|f| f.to_string())
            .collect::<Vec<_>>()
            .join(",")
    );

    let count: (i64,) = sqlx::query_as("SELECT COUNT(*) FROM asset_embeddings")
        .fetch_one(pool)
        .await?;
    let embedding_count = count.0;

    let mut tx = pool.begin().await?;

    if embedding_count < 1000 {
        sqlx::query("SET LOCAL enable_indexscan = off")
            .execute(&mut *tx)
            .await
            .ok();
    } else {
        sqlx::query("SET LOCAL ivfflat.probes = 20")
            .execute(&mut *tx)
            .await
            .ok();
    }

    // 取每个 asset 所有帧中最大相似度（视频多帧取最佳匹配帧）
    let rows = sqlx::query_as::<_, (Uuid, f64)>(
        r#"
        SELECT sub.asset_id, sub.similarity FROM (
            SELECT e.asset_id,
                   MAX(1 - (e.embedding <=> $1::vector)) AS similarity
            FROM asset_embeddings e
            JOIN assets a ON a.id = e.asset_id
            WHERE a.is_deleted = FALSE
            GROUP BY e.asset_id
        ) sub
        ORDER BY sub.similarity DESC
        LIMIT $2
        "#,
    )
    .bind(&vec_str)
    .bind(limit)
    .fetch_all(&mut *tx)
    .await?;

    tx.commit().await?;

    Ok(rows
        .into_iter()
        .map(|(asset_id, similarity)| SemanticSearchResult { asset_id, similarity })
        .collect())
}

/// 创建 embedding 任务
pub async fn enqueue_embedding_job(pool: &PgPool, asset_id: Uuid) -> Result<()> {
    sqlx::query(
        r#"
        INSERT INTO embedding_jobs (asset_id, status)
        VALUES ($1, 'pending')
        ON CONFLICT DO NOTHING
        "#,
    )
    .bind(asset_id)
    .execute(pool)
    .await?;

    Ok(())
}
