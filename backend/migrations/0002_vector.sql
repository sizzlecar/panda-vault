-- 第三阶段：AI 语义搜索 - 向量索引
-- 需要 PostgreSQL + pgvector 扩展

CREATE EXTENSION IF NOT EXISTS vector;

-- 资产向量表：存储 CLIP embedding（512 维）
CREATE TABLE IF NOT EXISTS asset_embeddings (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  asset_id UUID NOT NULL REFERENCES assets(id) ON DELETE CASCADE,
  
  -- CLIP ViT-B/32 输出 512 维向量
  embedding vector(512) NOT NULL,
  
  -- 向量来源：thumbnail / frame_N / full
  source_type VARCHAR(32) NOT NULL DEFAULT 'thumbnail',
  
  created_at TIMESTAMP NOT NULL DEFAULT NOW(),
  
  UNIQUE(asset_id, source_type)
);

-- 向量索引（IVFFlat 适合百万级数据）
CREATE INDEX IF NOT EXISTS idx_embeddings_vector 
  ON asset_embeddings 
  USING ivfflat (embedding vector_cosine_ops)
  WITH (lists = 100);

-- 向量生成任务队列
CREATE TABLE IF NOT EXISTS embedding_jobs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  asset_id UUID NOT NULL REFERENCES assets(id) ON DELETE CASCADE,
  status job_status NOT NULL DEFAULT 'pending',
  created_at TIMESTAMP NOT NULL DEFAULT NOW(),
  started_at TIMESTAMP,
  finished_at TIMESTAMP,
  last_error TEXT
);

CREATE INDEX IF NOT EXISTS idx_embedding_jobs_status ON embedding_jobs(status, created_at);

