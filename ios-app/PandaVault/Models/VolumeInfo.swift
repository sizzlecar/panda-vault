import Foundation

/// 后端返回的存储卷信息（/api/volumes）
struct VolumeInfo: Identifiable, Decodable {
    let id: UUID
    let label: String
    let basePath: String
    let priority: Int
    /// 卷剩余空间低于此值时停止写入（"低空间阈值"）
    let minFreeBytes: Int64
    let isActive: Bool
    let isDefault: Bool
    /// 卷所在磁盘的总容量（statvfs，整盘）
    let totalBytes: Int64?
    /// 卷所在磁盘的剩余空间（statvfs，整盘）
    let freeBytes: Int64?
    /// 该卷下未删除资产的字节数总和（仅本应用占用，不含其他程序）
    let usedByAssets: Int64
    /// 该卷下未删除资产数量
    let assetCount: Int64
    /// ISO 8601 字符串，UI 不强依赖（避免 decoder 配置冲突）
    let lastCheckedAt: String?
    let createdAt: String?

    /// 整盘已用 = 总 - 剩余
    var diskUsedBytes: Int64? {
        guard let total = totalBytes, let free = freeBytes else { return nil }
        return max(0, total - free)
    }

    /// 整盘使用率（其他程序也算在内）
    var diskUsagePercent: Double? {
        guard let total = totalBytes, total > 0, let used = diskUsedBytes else { return nil }
        return Double(used) / Double(total)
    }

    /// 剩余是否低于阈值
    var isLowSpace: Bool {
        guard let free = freeBytes else { return false }
        return free <= minFreeBytes
    }
}
