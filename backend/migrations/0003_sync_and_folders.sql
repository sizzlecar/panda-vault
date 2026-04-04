-- 第四阶段：同步任务系统 + 文件夹功能

-- ============ 同步任务系统 ============

-- 同步会话：每次批量上传/同步创建一个会话
CREATE TABLE IF NOT EXISTS sync_sessions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  device_id VARCHAR(64) NOT NULL,           -- 设备标识（客户端生成）
  device_name VARCHAR(128),                  -- 设备名称（如 "iPhone 15 Pro"）
  source_type VARCHAR(32) NOT NULL,          -- 来源类型：file_picker / photo_library / auto_sync
  
  total_count INT NOT NULL DEFAULT 0,        -- 总文件数
  success_count INT NOT NULL DEFAULT 0,      -- 成功数
  failed_count INT NOT NULL DEFAULT 0,       -- 失败数
  skipped_count INT NOT NULL DEFAULT 0,      -- 跳过数（已存在）
  
  status VARCHAR(16) NOT NULL DEFAULT 'pending',  -- pending / running / completed / failed
  started_at TIMESTAMP,
  finished_at TIMESTAMP,
  created_at TIMESTAMP NOT NULL DEFAULT NOW(),
  
  error_message TEXT                         -- 如果整体失败，记录错误信息
);

CREATE INDEX IF NOT EXISTS idx_sync_sessions_device ON sync_sessions(device_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_sync_sessions_status ON sync_sessions(status);

-- 同步项目状态枚举
DO $$ BEGIN
  CREATE TYPE sync_item_status AS ENUM ('pending', 'uploading', 'succeeded', 'failed', 'skipped');
EXCEPTION
  WHEN duplicate_object THEN NULL;
END $$;

-- 同步项目：每个文件的上传状态
CREATE TABLE IF NOT EXISTS sync_items (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  session_id UUID NOT NULL REFERENCES sync_sessions(id) ON DELETE CASCADE,
  
  filename VARCHAR(512) NOT NULL,            -- 原始文件名
  file_size BIGINT,                          -- 文件大小（字节）
  
  asset_id UUID REFERENCES assets(id) ON DELETE SET NULL,  -- 成功后关联的资产
  status sync_item_status NOT NULL DEFAULT 'pending',
  
  error_message TEXT,                        -- 失败原因
  retry_count INT NOT NULL DEFAULT 0,        -- 重试次数
  
  created_at TIMESTAMP NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMP NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_sync_items_session ON sync_items(session_id);
CREATE INDEX IF NOT EXISTS idx_sync_items_status ON sync_items(status);

-- ============ 文件夹功能 ============

-- 文件夹表
CREATE TABLE IF NOT EXISTS folders (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name VARCHAR(256) NOT NULL,
  description TEXT,
  cover_asset_id UUID REFERENCES assets(id) ON DELETE SET NULL,  -- 封面图片
  
  parent_id UUID REFERENCES folders(id) ON DELETE CASCADE,  -- 支持嵌套文件夹
  
  created_by VARCHAR(64),                    -- 创建者设备ID
  created_at TIMESTAMP NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMP NOT NULL DEFAULT NOW(),
  
  is_deleted BOOLEAN NOT NULL DEFAULT FALSE
);

CREATE INDEX IF NOT EXISTS idx_folders_parent ON folders(parent_id) WHERE is_deleted = FALSE;

-- 资产-文件夹关联表（多对多：一张图片可以在多个文件夹）
CREATE TABLE IF NOT EXISTS asset_folders (
  asset_id UUID NOT NULL REFERENCES assets(id) ON DELETE CASCADE,
  folder_id UUID NOT NULL REFERENCES folders(id) ON DELETE CASCADE,
  added_at TIMESTAMP NOT NULL DEFAULT NOW(),
  added_by VARCHAR(64),                      -- 添加者设备ID
  
  PRIMARY KEY (asset_id, folder_id)
);

CREATE INDEX IF NOT EXISTS idx_asset_folders_folder ON asset_folders(folder_id);

-- ============ 资产表扩展 ============

-- 添加上传者设备ID
ALTER TABLE assets ADD COLUMN IF NOT EXISTS uploaded_by VARCHAR(64);

-- 添加软删除支持的删除者和删除时间
ALTER TABLE assets ADD COLUMN IF NOT EXISTS deleted_at TIMESTAMP;
ALTER TABLE assets ADD COLUMN IF NOT EXISTS deleted_by VARCHAR(64);

