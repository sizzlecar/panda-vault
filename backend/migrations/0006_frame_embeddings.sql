-- 给 asset_embeddings 加 frame_index 字段，支持视频多帧 embedding
ALTER TABLE asset_embeddings ADD COLUMN IF NOT EXISTS frame_index INT NOT NULL DEFAULT 0;

-- 删除旧的唯一约束（可能是 constraint 或 index）
ALTER TABLE asset_embeddings DROP CONSTRAINT IF EXISTS asset_embeddings_asset_id_source_type_key;
DROP INDEX IF EXISTS asset_embeddings_asset_id_source_type_key;

-- 新的唯一约束包含 frame_index
CREATE UNIQUE INDEX IF NOT EXISTS idx_asset_embeddings_unique
    ON asset_embeddings(asset_id, source_type, frame_index);
