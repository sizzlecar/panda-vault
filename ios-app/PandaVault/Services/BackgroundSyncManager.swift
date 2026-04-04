import BackgroundTasks
import Photos
import CryptoKit

final class BackgroundSyncManager {
    static let shared = BackgroundSyncManager()
    static let taskIdentifier = "com.pandavault.sync"

    private init() {}

    // MARK: - BGTask Registration

    func registerTasks() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.taskIdentifier,
            using: nil
        ) { task in
            if let bgTask = task as? BGProcessingTask {
                self.handleSync(task: bgTask)
            } else {
                task.setTaskCompleted(success: false)
            }
        }
    }

    func scheduleSync() {
        let request = BGProcessingTaskRequest(identifier: Self.taskIdentifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        request.earliestBeginDate = Date(timeIntervalSinceNow: 3600) // 1 小时后
        try? BGTaskScheduler.shared.submit(request)
    }

    private func handleSync(task: BGProcessingTask) {
        scheduleSync() // 链式调度下一次

        let syncTask = Task {
            await SyncEngine.shared.performSync()
        }

        task.expirationHandler = {
            syncTask.cancel()
        }

        Task {
            await syncTask.value
            task.setTaskCompleted(success: true)
        }
    }
}

// MARK: - Sync Engine

/// 独立的同步引擎，App 前台和后台都可调用
@MainActor
final class SyncEngine: ObservableObject {
    static let shared = SyncEngine()

    @Published var isSyncing = false
    @Published var lastSyncDate: Date?
    @Published var lastSyncResult: String = ""
    @Published var syncedCount = 0
    @Published var failedCount = 0
    @Published var totalToSync = 0
    @Published var syncFolderId: UUID? {
        didSet {
            if let id = syncFolderId {
                UserDefaults.standard.set(id.uuidString, forKey: "syncFolderId")
            } else {
                UserDefaults.standard.removeObject(forKey: "syncFolderId")
            }
        }
    }

    /// 已同步的 PHAsset localIdentifier 集合（持久化）
    private(set) var syncedIds: Set<String> = []
    private let syncedIdsKey = "syncedAssetIds"

    /// 相册总数和未同步数
    @Published var totalInLibrary = 0
    @Published var unsyncedCount = 0

    private init() {
        loadSyncedIds()
        lastSyncDate = UserDefaults.standard.object(forKey: "lastSyncDate") as? Date
        if let str = UserDefaults.standard.string(forKey: "syncFolderId") {
            syncFolderId = UUID(uuidString: str)
        }
        refreshStats()
    }

    func refreshStats() {
        let videos = PHAsset.fetchAssets(with: .video, options: nil).count
        let images = PHAsset.fetchAssets(with: .image, options: nil).count
        totalInLibrary = videos + images
        unsyncedCount = max(0, totalInLibrary - syncedIds.count)
    }

    // MARK: - Public

    func performSync() async {
        guard !isSyncing else { return }
        isSyncing = true
        defer {
            isSyncing = false
            UserDefaults.standard.set(Date(), forKey: "lastSyncDate")
            lastSyncDate = Date()
        }

        let serverURL = UserDefaults.standard.string(forKey: "serverURL") ?? ""
        guard !serverURL.isEmpty else {
            lastSyncResult = "未连接服务器"
            return
        }

        let api = APIService(baseURL: serverURL)

        // 1. 获取相册所有视频+图片（不限数量）
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        // 同步视频和图片
        let videos = PHAsset.fetchAssets(with: .video, options: options)
        let images = PHAsset.fetchAssets(with: .image, options: options)

        // 2. 过滤未同步的
        var toSync: [PHAsset] = []
        for result in [videos, images] {
            for i in 0..<result.count {
                let asset = result.object(at: i)
                if !syncedIds.contains(asset.localIdentifier) {
                    toSync.append(asset)
                }
            }
        }

        totalToSync = toSync.count
        syncedCount = 0
        failedCount = 0

        guard !toSync.isEmpty else {
            lastSyncResult = "已是最新"
            return
        }

        // 3. 并发上传（3 路）
        let concurrency = 3
        await withTaskGroup(of: Void.self) { group in
            var running = 0
            for phAsset in toSync {
                try? Task.checkCancellation()

                if running >= concurrency {
                    await group.next()
                    running -= 1
                }
                running += 1

                group.addTask { [self] in
                    await self.syncOne(phAsset: phAsset, api: api)
                }
            }
        }

        lastSyncResult = "同步完成: \(syncedCount) 成功, \(failedCount) 失败"
        saveSyncedIds()
        refreshStats()
    }

    // MARK: - Single Asset Sync

    private func syncOne(phAsset: PHAsset, api: APIService) async {
        do {
            // 导出
            let exported = try await PhotoLibraryService.exportAsset(phAsset)
            defer { try? FileManager.default.removeItem(at: exported.url) }

            // 快速去重：用文件大小 + 首 1MB hash 查服务端
            let fingerprint = await computeFingerprint(url: exported.url, size: exported.size)
            if let fp = fingerprint {
                let exists = try? await api.checkDuplicate(fingerprint: fp)
                if exists == true {
                    // 服务端已有，标记为已同步
                    syncedIds.insert(phAsset.localIdentifier)
                    syncedCount += 1
                    return
                }
            }

            // 上传（带目标文件夹）
            _ = try await api.uploadFile(fileURL: exported.url, folderId: syncFolderId)

            syncedIds.insert(phAsset.localIdentifier)
            syncedCount += 1
        } catch {
            failedCount += 1
        }
    }

    // MARK: - Fingerprint (文件大小 + 首 1MB SHA256)

    private func computeFingerprint(url: URL, size: Int64) async -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        let headSize = min(1024 * 1024, Int(size)) // 最多读 1MB
        guard let headData = try? handle.read(upToCount: headSize) else { return nil }

        let hash = SHA256.hash(data: headData)
        let hashStr = hash.compactMap { String(format: "%02x", $0) }.joined()
        return "\(size)_\(hashStr)"
    }

    // MARK: - Persistence

    private func loadSyncedIds() {
        if let arr = UserDefaults.standard.array(forKey: syncedIdsKey) as? [String] {
            syncedIds = Set(arr)
        }
    }

    private func saveSyncedIds() {
        // 只保留最近 10000 条，防止无限增长
        let arr = Array(syncedIds.suffix(10000))
        UserDefaults.standard.set(arr, forKey: syncedIdsKey)
    }
}
