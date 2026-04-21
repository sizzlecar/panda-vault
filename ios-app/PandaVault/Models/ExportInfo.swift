import Foundation

/// 剪辑工程包 —— 后端 zip + metadata.json，用户 Mac 侧 Finder 打开
struct ExportInfo: Codable, Identifiable, Hashable {
    /// 用 filename 作为主键（后端不用数据库存 —— 一个文件就是一条"记录"）
    var id: String { filename }

    /// 例如 `pandavault_20260421-141523.zip`
    let filename: String

    /// Mac 服务端的绝对路径，方便用户在 Finder 里定位
    let absolutePath: String

    /// HTTP 下载相对路径，例如 `/exports/pandavault_20260421-141523.zip`
    let downloadPath: String

    /// 字节数
    let sizeBytes: Int64

    /// 打包耗时 ms（仅 create 接口返回；list 接口为 0）
    let durationMs: Int64?

    /// 资产数（仅 create 接口返回；list 接口为 0）
    let assetCount: Int?

    /// 文件 mtime（list 接口用）或创建时间（create 接口用）
    let createdAt: Date?
}
