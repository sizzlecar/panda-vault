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
}

struct CreateFolderRequest: Codable {
    let name: String
    let parentId: UUID?
}
