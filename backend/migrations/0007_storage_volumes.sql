-- 多卷存储：支持多块硬盘/目录作为存储池

CREATE TABLE IF NOT EXISTS storage_volumes (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    label VARCHAR(128) NOT NULL,              -- 显示名，如 "主硬盘"
    base_path TEXT NOT NULL UNIQUE,           -- 绝对路径，如 "/mnt/disk1"
    priority INT NOT NULL DEFAULT 0,          -- 越大越优先写入
    min_free_bytes BIGINT NOT NULL DEFAULT 5368709120, -- 5GB 保底
    is_active BOOLEAN NOT NULL DEFAULT TRUE,  -- 是否可用
    is_default BOOLEAN NOT NULL DEFAULT FALSE,-- 默认卷（现有数据归属）
    total_bytes BIGINT,
    free_bytes BIGINT,
    last_checked_at TIMESTAMP,
    created_at TIMESTAMP NOT NULL DEFAULT NOW()
);

-- assets 关联卷（NULL = 默认卷，向后兼容）
ALTER TABLE assets ADD COLUMN IF NOT EXISTS volume_id UUID REFERENCES storage_volumes(id);
CREATE INDEX IF NOT EXISTS idx_assets_volume ON assets(volume_id);
