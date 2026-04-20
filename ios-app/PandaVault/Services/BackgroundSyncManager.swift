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
    @Published var currentFileName: String = ""
    @Published var currentProgress: Double = 0 // 0~1 当前文件上传进度
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
        // 异步刷新统计，不阻塞主线程
        Task { await refreshStats() }
    }

    func refreshStats() async {
        let (videos, images) = await Task.detached {
            let v = PHAsset.fetchAssets(with: .video, options: nil).count
            let i = PHAsset.fetchAssets(with: .image, options: nil).count
            return (v, i)
        }.value
        totalInLibrary = videos + images
        unsyncedCount = max(0, totalInLibrary - syncedIds.count)
    }

    // MARK: - Public

    func performSync() async {
        guard !isSyncing else {
            PVLog.sync("performSync: 已在运行，忽略")
            return
        }
        isSyncing = true
        let startedAt = Date()
        PVLog.sync("performSync[start] folder=\(syncFolderId?.uuidString ?? "default") 已同步=\(syncedIds.count)")
        defer {
            isSyncing = false
            UserDefaults.standard.set(Date(), forKey: "lastSyncDate")
            lastSyncDate = Date()
            let elapsed = Int(Date().timeIntervalSince(startedAt))
            PVLog.sync("performSync[end] 耗时=\(elapsed)s 成功=\(syncedCount) 失败=\(failedCount)")
        }

        let serverURL = UserDefaults.standard.string(forKey: "serverURL") ?? ""
        guard !serverURL.isEmpty else {
            PVLog.syncError("performSync: serverURL 为空，跳过")
            lastSyncResult = "未连接服务器"
            return
        }

        let api = APIService(baseURL: serverURL)
        let currentSyncedIds = syncedIds
        let lastSync = lastSyncDate

        // 1. 在后台线程获取相册并过滤（增量：只取上次同步后新增的）
        let toSync: [PHAsset] = await Task.detached {
            let options = PHFetchOptions()
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]

            // 增量优化：有上次同步时间且已同步集合非空时，只取新增的
            if let cutoff = lastSync, !currentSyncedIds.isEmpty {
                let buffer = cutoff.addingTimeInterval(-120) // 2 分钟余量
                options.predicate = NSPredicate(format: "creationDate > %@", buffer as NSDate)
            }

            let videos = PHAsset.fetchAssets(with: .video, options: options)
            let images = PHAsset.fetchAssets(with: .image, options: options)

            var result: [PHAsset] = []
            for fetchResult in [videos, images] {
                for i in 0..<fetchResult.count {
                    let asset = fetchResult.object(at: i)
                    if !currentSyncedIds.contains(asset.localIdentifier) {
                        result.append(asset)
                    }
                }
            }
            return result
        }.value

        totalToSync = toSync.count
        syncedCount = 0
        failedCount = 0
        PVLog.sync("performSync: 待同步 \(toSync.count) 项")

        guard !toSync.isEmpty else {
            lastSyncResult = "已是最新"
            return
        }

        // 2. 逐个上传（避免内存爆炸）
        let folderId = syncFolderId
        for (i, phAsset) in toSync.enumerated() {
            if Task.isCancelled { break }
            let resources = PHAssetResource.assetResources(for: phAsset)
            currentFileName = resources.first?.originalFilename ?? "文件 \(i+1)"
            currentProgress = 0
            await syncOne(phAsset: phAsset, api: api, folderId: folderId)
        }
        currentFileName = ""
        currentProgress = 0

        lastSyncResult = "同步完成: \(syncedCount) 成功, \(failedCount) 失败"
        saveSyncedIds()
        await refreshStats()
    }

    // MARK: - Single Asset Sync

    private func syncOne(phAsset: PHAsset, api: APIService, folderId: UUID?) async {
        let resName = PHAssetResource.assetResources(for: phAsset).first?.originalFilename ?? "?"
        do {
            let exported = try await PhotoLibraryService.exportAsset(phAsset)
            defer { try? FileManager.default.removeItem(at: exported.url) }

            // 在后台线程算指纹
            if let fp = await FileFingerprint.compute(url: exported.url, size: exported.size) {
                let result = try? await api.checkDuplicate(size: fp.size, headHash: fp.headHash, tailHash: fp.tailHash)
                if result?.exists == true {
                    syncedIds.insert(phAsset.localIdentifier)
                    syncedCount += 1
                    PVLog.sync("syncOne[duplicate] \(resName) size=\(exported.size.humanReadableBytes)")
                    return
                }
            }

            // 带上照片拍摄时间 + 进度回调
            _ = try await api.uploadFile(fileURL: exported.url, folderId: folderId, shootAt: phAsset.creationDate) { [weak self] progress in
                Task { @MainActor in self?.currentProgress = progress }
            }

            syncedIds.insert(phAsset.localIdentifier)
            syncedCount += 1
            PVLog.sync("syncOne[ok] \(resName) size=\(exported.size.humanReadableBytes)")
        } catch {
            failedCount += 1
            PVLog.syncError("syncOne[fail] \(resName) err=\(error.localizedDescription)")
        }
    }

    // MARK: - Persistence

    private func loadSyncedIds() {
        if let arr = UserDefaults.standard.array(forKey: syncedIdsKey) as? [String] {
            syncedIds = Set(arr)
        }
    }

    private func saveSyncedIds() {
        let arr = Array(syncedIds.suffix(10000))
        UserDefaults.standard.set(arr, forKey: syncedIdsKey)
    }
}
