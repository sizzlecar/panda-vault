import Foundation

struct UploadInitResponse: Codable {
    let uploadId: String
    let chunkSize: Int
}

struct UploadCompleteResponse: Codable {
    let assetId: UUID
    let duplicate: Bool
}

struct UploadOffsetResponse: Codable {
    let uploadId: String
    let offset: Int64
    let totalSize: Int64
}

enum UploadTaskStatus: Equatable {
    case pending
    case uploading(progress: Double)
    case completed(assetId: UUID)
    case duplicated(assetId: UUID)
    case failed(message: String)

    var isTerminal: Bool {
        switch self {
        case .completed, .failed, .duplicated: return true
        default: return false
        }
    }
}

@MainActor
final class UploadTask: ObservableObject, Identifiable {
    let id = UUID()
    let filename: String
    let fileURL: URL
    let fileSize: Int64
    @Published var status: UploadTaskStatus = .pending

    let folderId: UUID?
    let shootAt: Date?

    /// 对应系统相册里原图的 PHAsset.localIdentifier
    /// 上传成功/重复后可用它批量删除本地原图（系统会弹官方确认框）
    let localIdentifier: String?

    /// 相册原图已在本次会话里被删除 —— UI 上可挂个标记
    @Published var localDeleted = false

    init(
        filename: String,
        fileURL: URL,
        fileSize: Int64,
        folderId: UUID? = nil,
        shootAt: Date? = nil,
        localIdentifier: String? = nil
    ) {
        self.filename = filename
        self.fileURL = fileURL
        self.fileSize = fileSize
        self.folderId = folderId
        self.shootAt = shootAt
        self.localIdentifier = localIdentifier
    }
}
