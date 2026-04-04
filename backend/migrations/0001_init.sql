-- 资产表：一期/二期共用
CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TABLE IF NOT EXISTS assets (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  filename TEXT NOT NULL,

  -- 物理路径（相对 STORAGE_ROOT）
  file_path TEXT NOT NULL,        -- e.g. /raw/2025/01/video.mov
  proxy_path TEXT,                -- e.g. /proxies/2025/01/video_720p.mp4
  thumb_path TEXT,                -- e.g. /proxies/2025/01/video_thumb.jpg

  -- 查重指纹
  file_hash VARCHAR(64) NOT NULL, -- SHA256 hex
  size_bytes BIGINT NOT NULL,

  -- 核心元数据（二期）
  shoot_at TIMESTAMP,
  created_at TIMESTAMP DEFAULT NOW(),
  duration_sec INTEGER,
  width INTEGER,
  height INTEGER,

  is_deleted BOOLEAN DEFAULT FALSE
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_assets_hash ON assets(file_hash);
CREATE INDEX IF NOT EXISTS idx_assets_shoot_at ON assets(shoot_at DESC NULLS LAST);
CREATE INDEX IF NOT EXISTS idx_assets_created_at ON assets(created_at DESC);

-- 异步任务队列（二期）
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'job_status') THEN
    CREATE TYPE job_status AS ENUM ('pending', 'running', 'succeeded', 'failed');
  END IF;
END$$;

CREATE TABLE IF NOT EXISTS transcode_jobs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  asset_id UUID NOT NULL REFERENCES assets(id) ON DELETE CASCADE,
  status job_status NOT NULL DEFAULT 'pending',
  created_at TIMESTAMP NOT NULL DEFAULT NOW(),
  started_at TIMESTAMP,
  finished_at TIMESTAMP,
  last_error TEXT
);

CREATE INDEX IF NOT EXISTS idx_jobs_status_created_at ON transcode_jobs(status, created_at);

