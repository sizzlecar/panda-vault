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

    init(filename: String, fileURL: URL, fileSize: Int64, folderId: UUID? = nil) {
        self.filename = filename
        self.fileURL = fileURL
        self.fileSize = fileSize
        self.folderId = folderId
    }
}
