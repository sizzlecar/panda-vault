-- 文件夹总字节数（含子文件夹，递归）
-- NULL = 尚未计算；写路径增量维护；首次访问 /api/folders 时异步 recompute
ALTER TABLE folders ADD COLUMN IF NOT EXISTS total_bytes BIGINT;
