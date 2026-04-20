import Foundation

struct Folder: Codable, Identifiable, Hashable {
    let id: UUID
    let name: String
    let fsName: String?
    let fsPath: String?
    let parentId: UUID?
    let coverThumbPath: String?
    let assetCount: Int?
    let createdAt: Date?
    let updatedAt: Date?
    /// 文件夹及子文件夹所有资产的字节数总和；后端懒计算，null 表示"计算中"
    let totalBytes: Int64?
}

struct CreateFolderRequest: Codable {
    let name: String
    let parentId: UUID?
}
