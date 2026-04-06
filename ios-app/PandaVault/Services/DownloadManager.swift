import Foundation
import SwiftUI

enum DownloadTaskStatus: Equatable {
    case pending
    case downloading(progress: Double)
    case saving
    case completed
    case failed(message: String)

    var isTerminal: Bool {
        switch self {
        case .completed, .failed: return true
        default: return false
        }
    }
}

@MainActor
final class DownloadTask: ObservableObject, Identifiable {
    let id: UUID
    let assetId: UUID
    let filename: String
    let isVideo: Bool
    @Published var status: DownloadTaskStatus = .pending

    init(asset: Asset) {
        self.id = UUID()
        self.assetId = asset.id
        self.filename = asset.filename
        self.isVideo = asset.isVideo
    }
}

@MainActor
final class DownloadManager: ObservableObject {
    @Published var tasks: [DownloadTask] = []
    @Published var isActive = false

    private var api: APIService?

    func updateAPI(_ api: APIService) {
        self.api = api
    }

    var completedCount: Int {
        tasks.filter { if case .completed = $0.status { return true }; return false }.count
    }
    var failedCount: Int {
        tasks.filter { if case .failed = $0.status { return true }; return false }.count
    }
    var totalCount: Int { tasks.count }
    var overallProgress: Double {
        guard totalCount > 0 else { return 0 }
        var sum = 0.0
        for t in tasks {
            switch t.status {
            case .completed, .saving: sum += 1.0
            case .downloading(let p): sum += p
            default: break
            }
        }
        return sum / Double(totalCount)
    }
    var isDone: Bool { tasks.allSatisfy { $0.status.isTerminal } }

    func addAssets(_ assets: [Asset]) {
        for asset in assets {
            let task = DownloadTask(asset: asset)
            tasks.append(task)
        }
        if !isActive {
            Task { await processQueue() }
        }
    }

    func clear() {
        tasks.removeAll()
        isActive = false
    }

    private func processQueue() async {
        guard let api, !isActive else { return }
        isActive = true
        defer { isActive = false }

        // 自适应并发
        let avgSize = tasks.map(\.assetId).count // 无法知道文件大小，默认 3 路
        let concurrency = 3

        await withTaskGroup(of: Void.self) { group in
            var running = 0
            for task in tasks where task.status == .pending {
                if running >= concurrency {
                    await group.next()
                    running -= 1
                }
                running += 1
                group.addTask { [self] in
                    await self.downloadOne(task)
                }
            }
        }
    }

    private func downloadOne(_ task: DownloadTask) async {
        guard let api else { return }
        await MainActor.run { task.status = .downloading(progress: 0) }

        do {
            let tempURL = try await api.downloadAsset(id: task.assetId) { p in
                Task { @MainActor in task.status = .downloading(progress: p) }
            }

            // 加正确扩展名，PHPhotoLibrary 需要
            let ext = (task.filename as NSString).pathExtension.lowercased()
            let destURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(ext.isEmpty ? "jpg" : ext)
            try FileManager.default.moveItem(at: tempURL, to: destURL)
            defer { try? FileManager.default.removeItem(at: destURL) }

            await MainActor.run { task.status = .saving }
            if task.isVideo {
                try await PhotoLibraryService.saveVideoToAlbum(fileURL: destURL)
            } else {
                try await PhotoLibraryService.saveImageToAlbum(fileURL: destURL)
            }
            await MainActor.run { task.status = .completed }
        } catch {
            print("[PandaVault] Download error: \(error)")
            await MainActor.run { task.status = .failed(message: error.localizedDescription) }
        }
    }
}
