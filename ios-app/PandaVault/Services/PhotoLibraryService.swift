import Photos
import UIKit

enum PhotoLibraryService {
    /// 保存视频文件到相册
    static func saveVideoToAlbum(fileURL: URL) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw PhotoError.permissionDenied
        }

        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: fileURL)
        }
    }

    /// 保存图片文件到相册
    static func saveImageToAlbum(fileURL: URL) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw PhotoError.permissionDenied
        }

        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: fileURL)
        }
    }

    /// 获取相册中的资源（分页）
    static func fetchAssets(mediaType: PHAssetMediaType = .video, limit: Int = 50, offset: Int = 0) -> [PHAsset] {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = limit + offset

        let results = PHAsset.fetchAssets(with: mediaType, options: options)
        var assets: [PHAsset] = []
        let start = min(offset, results.count)
        let end = min(offset + limit, results.count)
        for i in start..<end {
            assets.append(results.object(at: i))
        }
        return assets
    }

    /// 导出 PHAsset 为临时文件
    static func exportAsset(_ asset: PHAsset) async throws -> (url: URL, filename: String, size: Int64) {
        if asset.mediaType == .video {
            return try await exportVideo(asset)
        } else {
            return try await exportImage(asset)
        }
    }

    private static func exportVideo(_ asset: PHAsset) async throws -> (URL, String, Int64) {
        try await withCheckedThrowingContinuation { continuation in
            let options = PHVideoRequestOptions()
            options.isNetworkAccessAllowed = true
            options.deliveryMode = .highQualityFormat

            PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { avAsset, _, info in
                guard let urlAsset = avAsset as? AVURLAsset else {
                    continuation.resume(throwing: PhotoError.exportFailed)
                    return
                }

                let srcURL = urlAsset.url
                let filename = srcURL.lastPathComponent
                let size = (try? FileManager.default.attributesOfItem(atPath: srcURL.path)[.size] as? Int64) ?? 0

                // 复制到临时目录（PHAsset 的原始文件可能被系统回收）
                let tmpURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "_" + filename)
                do {
                    try FileManager.default.copyItem(at: srcURL, to: tmpURL)
                    continuation.resume(returning: (tmpURL, filename, size))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func exportImage(_ asset: PHAsset) async throws -> (URL, String, Int64) {
        try await withCheckedThrowingContinuation { continuation in
            let options = PHImageRequestOptions()
            options.isNetworkAccessAllowed = true
            options.deliveryMode = .highQualityFormat

            let resources = PHAssetResource.assetResources(for: asset)
            let filename = resources.first?.originalFilename ?? "image.jpg"

            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, _ in
                guard let data else {
                    continuation.resume(throwing: PhotoError.exportFailed)
                    return
                }

                let tmpURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "_" + filename)
                do {
                    try data.write(to: tmpURL)
                    continuation.resume(returning: (tmpURL, filename, Int64(data.count)))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

enum PhotoError: LocalizedError {
    case permissionDenied
    case exportFailed

    var errorDescription: String? {
        switch self {
        case .permissionDenied: return "需要相册访问权限"
        case .exportFailed: return "导出文件失败"
        }
    }
}
