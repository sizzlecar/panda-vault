-- 文件夹总资产数（含子文件夹，递归）
-- NULL = 尚未计算；与 total_bytes 同一套懒更新机制
ALTER TABLE folders ADD COLUMN IF NOT EXISTS total_asset_count BIGINT;
