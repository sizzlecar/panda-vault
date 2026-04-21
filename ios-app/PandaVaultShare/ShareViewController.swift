import UIKit
import UniformTypeIdentifiers
import os

/// PandaVault Share Extension
/// 用户在「相机/微信/剪映」点分享 → 这里 —— 把文件存进 App Group 共享沙箱的 inbox
/// 主 app 启动或前台激活时会扫 inbox，把里面的文件搬到 tmp → 喂给 UploadManager
final class ShareViewController: UIViewController {

    // Extension 不能用 PVLog（PVLog 依赖主 app 的 Documents / LogReporter）
    // 只用 os.Logger，subsystem 跟主 app 保持一致，Console.app 能一起过滤
    private let log = Logger(subsystem: "com.pandavault.app", category: "ShareExt")

    // 大文件策略 —— Extension 内存上限约 120MB，运行时间 ~30s
    // APFS clonefile 复制再大的文件都是 O(1)，所以真正的约束只有两个：
    //   1) extension 进程生命周期（~30s 被系统杀）
    //   2) 单文件加载时间（iCloud 未下载的大文件拉不动）
    // 文件本身的体积几乎没上限 —— 默认 32GB 拦住明显异常
    /// 单文件硬顶（32GB —— 实际只用来兜住 NSItemProvider 坏数据）
    private let perFileLimit: Int64 = 32 * 1024 * 1024 * 1024     // 32 GB
    /// 单次 share 总字节数（主要是兜住 bug，不限制正常使用）
    private let totalBatchLimit: Int64 = 64 * 1024 * 1024 * 1024  // 64 GB
    /// 单次 share 处理耗时硬截止（触到就收尾 —— iOS 到 30s 会强杀 extension）
    private let hardDeadline: TimeInterval = 25.0                 // 留 5s 给收尾
    /// 单文件加载超时（卡 iCloud 下载时才放弃 —— 本地文件 APFS clone 是瞬时的）
    private let perFileTimeout: TimeInterval = 20.0

    private let messageLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)

    private var deadline: Date { Date(timeIntervalSinceNow: hardDeadline) }
    private var startedAt = Date()
    private var totalBytesSaved: Int64 = 0

    override func viewDidLoad() {
        super.viewDidLoad()
        // 奶油色背景对齐主 app
        view.backgroundColor = UIColor(red: 0xF7/255.0, green: 0xEF/255.0, blue: 0xE2/255.0, alpha: 1.0)
        setupUI()
        log.notice("[ShareExt] 拉起；inputItems=\(self.extensionContext?.inputItems.count ?? 0, privacy: .public)")
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        Task { await run() }
    }

    // MARK: - UI

    private func setupUI() {
        messageLabel.text = "正在保存到 PandaVault…"
        messageLabel.textAlignment = .center
        messageLabel.textColor = UIColor(red: 0x3D/255.0, green: 0x2E/255.0, blue: 0x27/255.0, alpha: 1.0) // PV.ink
        messageLabel.font = .systemFont(ofSize: 15, weight: .medium)
        messageLabel.numberOfLines = 0
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(messageLabel)

        spinner.startAnimating()
        spinner.color = UIColor(red: 0xC6/255.0, green: 0x8B/255.0, blue: 0x5F/255.0, alpha: 1.0) // PV.caramel
        spinner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(spinner)

        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -16),
            messageLabel.topAnchor.constraint(equalTo: spinner.bottomAnchor, constant: 12),
            messageLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            messageLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 32),
            messageLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -32),
        ])
    }

    private func finishUI(result: ShareResult) {
        spinner.stopAnimating()
        spinner.isHidden = true
        if result.saved > 0 {
            var tail: [String] = []
            if result.failed > 0 { tail.append("失败 \(result.failed)") }
            if result.skippedLarge > 0 { tail.append("超限 \(result.skippedLarge)") }
            if result.skippedDeadline > 0 { tail.append("超时 \(result.skippedDeadline)") }
            let suffix = tail.isEmpty ? "" : "\n(\(tail.joined(separator: " · ")))"
            messageLabel.text = "已放入 PandaVault 收件箱\n成功 \(result.saved)\(suffix)"
        } else if result.skippedLarge > 0 {
            messageLabel.text = "文件太大，请打开 PandaVault 主 app 直接上传"
            messageLabel.textColor = UIColor(red: 0xD0/255.0, green: 0x7A/255.0, blue: 0x7A/255.0, alpha: 1.0)
        } else if result.skippedDeadline > 0 {
            messageLabel.text = "来不及处理所有文件，请打开 PandaVault 分批上传"
            messageLabel.textColor = UIColor(red: 0xD0/255.0, green: 0x7A/255.0, blue: 0x7A/255.0, alpha: 1.0)
        } else {
            messageLabel.text = "保存失败 \(result.failed == 0 ? "" : "\(result.failed) 项")\n请打开 PandaVault 重试"
            messageLabel.textColor = UIColor(red: 0xD0/255.0, green: 0x7A/255.0, blue: 0x7A/255.0, alpha: 1.0)
        }
    }

    // MARK: - Flow

    private func run() async {
        startedAt = Date()
        let result = await saveAllAttachments()
        let ms = Int(Date().timeIntervalSince(startedAt) * 1000)
        let memMB = Self.memoryUsageMB()
        log.notice("[ShareExt] 完成 saved=\(result.saved, privacy: .public) failed=\(result.failed, privacy: .public) skippedLarge=\(result.skippedLarge, privacy: .public) skippedDeadline=\(result.skippedDeadline, privacy: .public) totalBytes=\(self.totalBytesSaved, privacy: .public) mem=\(memMB, privacy: .public)MB \(ms, privacy: .public)ms")

        await MainActor.run {
            finishUI(result: result)
        }

        // 短暂展示结果再退出，避免用户疑惑
        try? await Task.sleep(nanoseconds: result.saved > 0 ? 600_000_000 : 1_400_000_000)
        await MainActor.run {
            self.extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
        }
    }

    struct ShareResult {
        var saved: Int = 0
        var failed: Int = 0
        var skippedLarge: Int = 0      // 单文件超 perFileLimit 或 总量超 totalBatchLimit
        var skippedDeadline: Int = 0   // 扩展时间快用完，剩下的跳过
    }

    private func saveAllAttachments() async -> ShareResult {
        guard let items = extensionContext?.inputItems as? [NSExtensionItem] else {
            log.error("[ShareExt] extensionContext 没 inputItems")
            return ShareResult()
        }

        var r = ShareResult()
        let hardCutoff = deadline

        for (itemIdx, item) in items.enumerated() {
            let attachments = item.attachments ?? []
            log.notice("[ShareExt] item[\(itemIdx, privacy: .public)] attachments=\(attachments.count, privacy: .public)")

            for (i, provider) in attachments.enumerated() {
                // 时间用光 —— 剩下的全部跳过（告诉用户去主 app 上传）
                if Date() >= hardCutoff {
                    r.skippedDeadline += 1
                    log.error("[ShareExt] 时间耗尽 跳过 idx=\(i, privacy: .public)")
                    continue
                }
                // 总量超限 —— 剩下也跳过
                if totalBytesSaved >= totalBatchLimit {
                    r.skippedLarge += 1
                    log.error("[ShareExt] 批量总量超限 跳过 idx=\(i, privacy: .public) totalSaved=\(self.totalBytesSaved, privacy: .public)")
                    continue
                }

                let outcome = await handleProvider(provider, index: i, of: attachments.count)
                switch outcome {
                case .saved(let bytes):
                    r.saved += 1
                    totalBytesSaved += bytes
                case .tooLarge:
                    r.skippedLarge += 1
                case .failed:
                    r.failed += 1
                }
            }
        }
        return r
    }

    enum ProviderOutcome {
        case saved(bytes: Int64)
        case tooLarge
        case failed
    }

    /// 尝试把单个 NSItemProvider 写到 inbox
    /// 按优先级匹配类型：movie > image > generic file
    private func handleProvider(_ provider: NSItemProvider, index: Int, of total: Int) async -> ProviderOutcome {
        // 优先按「电影 / 图片 / 文件」顺序匹配 —— 兼容微信 / 剪映 导出的 mov/mp4/heic/jpg
        let candidates: [UTType] = [
            .movie, .quickTimeMovie, .mpeg4Movie, .video,
            .image, .heic, .jpeg, .png, .tiff, .rawImage,
            .fileURL, .data
        ]

        for type in candidates {
            guard provider.hasItemConformingToTypeIdentifier(type.identifier) else { continue }
            do {
                let result = try await loadAndWrite(provider: provider, type: type)
                log.notice("[ShareExt] 写入成功 idx=\(index, privacy: .public)/\(total, privacy: .public) type=\(type.identifier, privacy: .public) size=\(result.size, privacy: .public) name=\(result.name, privacy: .public)")
                return .saved(bytes: result.size)
            } catch ShareExtError.tooLarge(let size) {
                log.error("[ShareExt] 单文件超限 idx=\(index, privacy: .public) size=\(size, privacy: .public) limit=\(self.perFileLimit, privacy: .public) — 去主 app 上传")
                return .tooLarge
            } catch {
                log.error("[ShareExt] 写入失败 idx=\(index, privacy: .public) type=\(type.identifier, privacy: .public) err=\(error.localizedDescription, privacy: .public)")
                // 继续尝试下一个类型（偶尔 movie 会冲突、落到 fileURL 能过）
                continue
            }
        }
        log.error("[ShareExt] 所有类型都不匹配或失败 idx=\(index, privacy: .public)")
        return .failed
    }

    /// 调 `loadFileRepresentation`，在 completion 内把系统 tmp URL 立即搬进 App Group inbox
    /// 策略：
    /// - 先 hardlink（APFS O(1)，占零额外存储），失败 fallback copy（clonefile 依然 O(1)）
    /// - 加 per-file 超时：卡 iCloud 下载时能及时放弃
    /// - 写入前做大小预检：`provider` 没直接 API，只能在 write 完后量
    ///   若发现超 perFileLimit 立刻删掉并抛 tooLarge
    private func loadAndWrite(provider: NSItemProvider, type: UTType) async throws -> (name: String, size: Int64) {
        let requested = provider.suggestedName
        let perFileLimit = self.perFileLimit
        let timeout = self.perFileTimeout

        return try await withThrowingTaskGroup(of: (name: String, size: Int64).self) { group in
            group.addTask {
                try await Self.performLoadAndWrite(
                    provider: provider,
                    type: type,
                    suggestedName: requested,
                    perFileLimit: perFileLimit
                )
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw ShareExtError.timedOut
            }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }
    }

    /// 纯函数化，便于 TaskGroup 里并行超时
    private static func performLoadAndWrite(
        provider: NSItemProvider,
        type: UTType,
        suggestedName: String?,
        perFileLimit: Int64
    ) async throws -> (name: String, size: Int64) {
        try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, err in
                if let err {
                    continuation.resume(throwing: err)
                    return
                }
                guard let url else {
                    continuation.resume(throwing: ShareExtError.noURL)
                    return
                }

                // 预检：超 perFileLimit 直接不搬（系统临时文件马上被清，OK）
                let srcSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
                if srcSize > perFileLimit {
                    continuation.resume(throwing: ShareExtError.tooLarge(bytes: srcSize))
                    return
                }

                let filename: String
                if let suggested = suggestedName, !suggested.isEmpty {
                    let ext = url.pathExtension
                    filename = ext.isEmpty ? suggested : "\(suggested).\(ext)"
                } else {
                    filename = url.lastPathComponent
                }

                do {
                    let saved = try ShareInbox.write(sourceURL: url, originalFilename: filename)
                    let size = (try? FileManager.default.attributesOfItem(atPath: saved.path)[.size] as? Int64) ?? 0
                    // 搬完再验一次（兜底）—— 超限删掉
                    if size > perFileLimit {
                        try? FileManager.default.removeItem(at: saved)
                        continuation.resume(throwing: ShareExtError.tooLarge(bytes: size))
                        return
                    }
                    continuation.resume(returning: (filename, size))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - 进程内存 (用于日志 —— Extension 容易被 jetsam 杀)
    private static func memoryUsageMB() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Int(info.resident_size / 1024 / 1024)
    }
}

enum ShareExtError: LocalizedError {
    case noURL
    case tooLarge(bytes: Int64)
    case timedOut

    var errorDescription: String? {
        switch self {
        case .noURL: return "provider 没拿到文件 URL"
        case .tooLarge(let b): return "文件 \(b / 1024 / 1024) MB 超过 Extension 上限"
        case .timedOut: return "加载超时（iCloud 未下载？）"
        }
    }
}
