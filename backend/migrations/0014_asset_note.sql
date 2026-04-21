-- 资产备注（用户自定义文字标注，显示在 AssetDetailView 底部）
ALTER TABLE assets ADD COLUMN IF NOT EXISTS note TEXT;
