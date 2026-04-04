CREATE TABLE IF NOT EXISTS upload_sessions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    filename TEXT NOT NULL,
    file_size BIGINT NOT NULL,
    chunk_size INT NOT NULL DEFAULT 5242880,  -- 5MB
    uploaded_bytes BIGINT NOT NULL DEFAULT 0,
    file_hash VARCHAR(64),
    status VARCHAR(20) NOT NULL DEFAULT 'uploading', -- uploading, completed, expired
    created_at TIMESTAMP DEFAULT NOW(),
    updated_at TIMESTAMP DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_upload_sessions_status ON upload_sessions(status);
