-- 第五阶段：文件夹与文件系统同步（SMB 一致）
-- 将文件夹从"标签关系"升级为"真实目录"

-- ============ 1. folders 表新增文件系统字段 ============

-- fs_name: 磁盘上的目录名（sanitize 后，对 SMB/Windows 安全）
ALTER TABLE folders ADD COLUMN IF NOT EXISTS fs_name VARCHAR(256);

-- fs_path: 相对于 albums/ 的完整路径（如 "旅行/2025-日本"）
ALTER TABLE folders ADD COLUMN IF NOT EXISTS fs_path TEXT;

-- 同级目录下 fs_name 不能重复（防止磁盘冲突）
-- 注意：只对未删除的文件夹生效
CREATE UNIQUE INDEX IF NOT EXISTS idx_folders_parent_fsname
  ON folders (COALESCE(parent_id, '00000000-0000-0000-0000-000000000000'::uuid), fs_name)
  WHERE is_deleted = FALSE AND fs_name IS NOT NULL;

-- ============ 2. asset_folders 改为单归属 ============

-- 一个资产只能属于一个文件夹（符合文件系统语义）
-- 先删除可能存在的重复关联（保留最新的）
DELETE FROM asset_folders a
WHERE EXISTS (
  SELECT 1 FROM asset_folders b
  WHERE b.asset_id = a.asset_id
    AND b.added_at > a.added_at
);

-- 添加唯一约束：每个 asset 只能在一个 folder 里
-- 注意：这会让 asset_id 成为唯一键（单归属）
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'asset_folders_asset_id_unique'
  ) THEN
    ALTER TABLE asset_folders ADD CONSTRAINT asset_folders_asset_id_unique UNIQUE (asset_id);
  END IF;
END $$;

-- ============ 3. 为现有文件夹生成 fs_name/fs_path ============

-- 对现有数据做一次初始化（将 name 作为 fs_name，简单 sanitize）
-- 注意：这只是临时兼容，新创建的文件夹会在后端代码里正确设置
UPDATE folders
SET fs_name = REGEXP_REPLACE(
  REGEXP_REPLACE(name, '[/\\:*?"<>|]', '_', 'g'),  -- 替换 Windows 不支持的字符
  '^\.+|\.+$|\s+$', '', 'g'                         -- 去掉开头的点和尾部空格
),
fs_path = REGEXP_REPLACE(
  REGEXP_REPLACE(name, '[/\\:*?"<>|]', '_', 'g'),
  '^\.+|\.+$|\s+$', '', 'g'
)
WHERE fs_name IS NULL AND is_deleted = FALSE;

-- ============ 4. 添加 cover_thumb_path 用于优化 N+1 ============

-- 缓存封面缩略图路径，避免客户端为每个文件夹再请求一次
ALTER TABLE folders ADD COLUMN IF NOT EXISTS cover_thumb_path TEXT;

-- ============ 5. 索引优化 ============

-- 按 fs_path 快速查找
CREATE INDEX IF NOT EXISTS idx_folders_fs_path ON folders(fs_path) WHERE is_deleted = FALSE;


