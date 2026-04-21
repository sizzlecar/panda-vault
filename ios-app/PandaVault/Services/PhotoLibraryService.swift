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
                    PVLog.uploadError("exportVideo: avAsset 不是 AVURLAsset，info=\(String(describing: info))")
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
                    PVLog.upload("exportVideo[ok] \(filename) size=\(size.humanReadableBytes) tmp=\(tmpURL.lastPathComponent)")
                    continuation.resume(returning: (tmpURL, filename, size))
                } catch {
                    PVLog.uploadError("exportVideo: 复制到 tmp 失败 \(filename): \(error)")
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

            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, info in
                guard let data else {
                    PVLog.uploadError("exportImage: 没拿到 data for \(filename), info=\(String(describing: info))")
                    continuation.resume(throwing: PhotoError.exportFailed)
                    return
                }

                let tmpURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "_" + filename)
                do {
                    try data.write(to: tmpURL)
                    PVLog.upload("exportImage[ok] \(filename) size=\(Int64(data.count).humanReadableBytes) tmp=\(tmpURL.lastPathComponent)")
                    continuation.resume(returning: (tmpURL, filename, Int64(data.count)))
                } catch {
                    PVLog.uploadError("exportImage: 写 tmp 失败 \(filename): \(error)")
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

enum PhotoError: LocalizedError {
    case permissionDenied
    case exportFailed
    case userCancelled

    var errorDescription: String? {
        switch self {
        case .permissionDenied: return "需要相册访问权限"
        case .exportFailed: return "导出文件失败"
        case .userCancelled: return "用户取消了删除"
        }
    }
}

extension PhotoLibraryService {
    /// 删除相册里对应 localIdentifier 的原图
    /// —— 系统会自动弹原生确认框，不用我们再自绘一层
    /// - Returns: 实际删除成功的条数（cancelled 时为 0）
    static func deleteOriginals(localIdentifiers: [String]) async throws -> Int {
        guard !localIdentifiers.isEmpty else { return 0 }

        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else {
            throw PhotoError.permissionDenied
        }

        let fetch = PHAsset.fetchAssets(withLocalIdentifiers: localIdentifiers, options: nil)
        guard fetch.count > 0 else { return 0 }

        var toDelete: [PHAsset] = []
        fetch.enumerateObjects { asset, _, _ in toDelete.append(asset) }

        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(toDelete as NSArray)
            }
            return toDelete.count
        } catch let err as NSError {
            // 用户点了系统弹窗的"取消"也走到这里 — domain=Cocoa code=3072
            if err.domain == NSCocoaErrorDomain && err.code == 3072 {
                throw PhotoError.userCancelled
            }
            throw err
        }
    }
}
