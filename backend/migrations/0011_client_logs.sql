-- 客户端上报日志（iOS 等终端的运行日志，便于远程排障）
-- 7 天保留期，由后端定时任务清理
CREATE TABLE IF NOT EXISTS client_logs (
    id          BIGSERIAL PRIMARY KEY,
    received_at TIMESTAMP NOT NULL DEFAULT NOW(),
    client_ts   TIMESTAMP NOT NULL,
    device_id   TEXT,
    device_name TEXT,
    app_version TEXT,
    level       TEXT NOT NULL,
    category    TEXT NOT NULL,
    location    TEXT,
    message     TEXT NOT NULL,
    metadata    JSONB
);

CREATE INDEX IF NOT EXISTS idx_client_logs_received   ON client_logs (received_at DESC);
CREATE INDEX IF NOT EXISTS idx_client_logs_category   ON client_logs (category, received_at DESC);
CREATE INDEX IF NOT EXISTS idx_client_logs_device     ON client_logs (device_id, received_at DESC);
