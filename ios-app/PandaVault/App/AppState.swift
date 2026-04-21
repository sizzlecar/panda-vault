import SwiftUI
import Combine

@MainActor
final class AppState: ObservableObject {
    @Published var serverURL: String {
        didSet {
            UserDefaults.standard.set(serverURL, forKey: "serverURL")
            _api = APIService(baseURL: serverURL)
            LogReporter.shared.updateServerURL(serverURL)
        }
    }
    @Published var isConnected = false
    /// 子屏进入批量选择时置 true，MainTabView 据此隐藏浮动 CTabBar，让
    /// FloatingBatchBar 占据底部（避免二者重合）
    @Published var tabBarHidden = false

    let downloadManager = DownloadManager()
    /// Share Extension 放到 inbox 的文件，主 app 复用这个 manager 做实际上传
    /// 启动 / 前台激活时扫 inbox → 调 addFiles
    let uploadManager: UploadManager
    private var _api: APIService!
    var api: APIService { _api }

    init() {
        let url = UserDefaults.standard.string(forKey: "serverURL") ?? ""
        self.serverURL = url
        self._api = APIService(baseURL: url)
        self.uploadManager = UploadManager(api: self._api)
    }

    func updateServerURL(_ url: String) {
        serverURL = url
        downloadManager.updateAPI(api)
        uploadManager.updateAPI(api)
    }

    func checkConnection() async {
        do {
            isConnected = try await api.ping()
        } catch {
            isConnected = false
        }
    }

    // MARK: - Share Inbox intake

    /// 扫 App Group 的 inbox，把文件搬到主 app tmp，喂给 UploadManager
    /// 调用点：app 启动、前台激活
    /// - Returns: 本次消费的文件数
    @discardableResult
    func ingestShareInbox() async -> Int {
        let pending = ShareInbox.listPending()
        guard !pending.isEmpty else { return 0 }
        PVLog.upload("shareInbox[scan] 发现 \(pending.count) 个待处理文件")
        PVLog.disk("shareInbox 消费前")

        var batch: [(url: URL, filename: String, size: Int64, shootAt: Date?, localIdentifier: String?)] = []
        var failed = 0
        var totalBytes: Int64 = 0
        for item in pending {
            if let consumed = ShareInbox.consume(item) {
                // Share Extension 收到的不是 PHAsset，没有 localIdentifier；
                // shootAt 也拿不到（除非扩展专门读 EXIF，这里先不做）
                batch.append((consumed.url, consumed.filename, consumed.size, nil, nil))
                totalBytes += consumed.size
                PVLog.upload("shareInbox[consume] name=\(consumed.filename) size=\(consumed.size.humanReadableBytes)")
            } else {
                failed += 1
                PVLog.uploadError("shareInbox[consume-fail] 无法搬移 \(item.lastPathComponent)")
            }
        }

        if batch.isEmpty {
            PVLog.uploadError("shareInbox[done] 待处理 \(pending.count) 全部消费失败（fail=\(failed)）")
            return 0
        }
        uploadManager.addFiles(batch, folderId: nil)
        PVLog.upload("shareInbox[done] 入队 \(batch.count) 项 总量=\(totalBytes.humanReadableBytes)（fail=\(failed)）")
        return batch.count
    }
}
