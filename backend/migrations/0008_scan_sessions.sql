-- 目录扫描会话：跟踪扫描进度

CREATE TABLE IF NOT EXISTS scan_sessions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    volume_id UUID NOT NULL REFERENCES storage_volumes(id),
    scan_path TEXT NOT NULL DEFAULT 'raw/albums', -- 扫描的相对路径
    status VARCHAR(20) NOT NULL DEFAULT 'pending', -- pending/running/completed/failed
    total_files INT NOT NULL DEFAULT 0,
    processed_files INT NOT NULL DEFAULT 0,
    new_assets INT NOT NULL DEFAULT 0,
    skipped_files INT NOT NULL DEFAULT 0,
    error_count INT NOT NULL DEFAULT 0,
    started_at TIMESTAMP,
    finished_at TIMESTAMP,
    created_at TIMESTAMP NOT NULL DEFAULT NOW(),
    last_error TEXT
);

-- 文件夹唯一约束：同一父目录下不能重名
CREATE UNIQUE INDEX IF NOT EXISTS idx_folders_parent_fsname
    ON folders (COALESCE(parent_id, '00000000-0000-0000-0000-000000000000'), fs_name)
    WHERE is_deleted = FALSE;
