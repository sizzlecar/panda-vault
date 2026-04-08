-- 上传预检指纹：首 1MB hash + 尾 1MB hash，配合 size_bytes 快速判重
ALTER TABLE assets ADD COLUMN head_hash VARCHAR(64);
ALTER TABLE assets ADD COLUMN tail_hash VARCHAR(64);

CREATE INDEX idx_assets_fingerprint
    ON assets(size_bytes, head_hash, tail_hash)
    WHERE is_deleted = FALSE AND head_hash IS NOT NULL;
