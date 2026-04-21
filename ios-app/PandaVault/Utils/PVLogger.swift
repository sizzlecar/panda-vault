import Foundation
import os

/// 统一日志：同时输出到 Xcode Console（os.Logger，Console.app 可查）
/// 以及 Documents/pandavault.log（方便"分享日志"给开发者）
enum PVLog {
    private static let logger = Logger(subsystem: "com.pandavault.app", category: "PandaVault")
    private static let uploadLogger = Logger(subsystem: "com.pandavault.app", category: "Upload")
    private static let diskLogger = Logger(subsystem: "com.pandavault.app", category: "Disk")

    /// 文件日志落盘（可从 Settings 里分享出去）
    static let fileLog = PVFileLogger()

    // NOTE: 统一用 .notice 级别 —— iOS 对 .info 会滚动丢弃。
    //       插值都标 privacy: .public，防止 Release 构建脱敏成 <private>。

    static func info(_ msg: String, file: String = #fileID, line: Int = #line) {
        logger.notice("[\(file, privacy: .public):\(line, privacy: .public)] \(msg, privacy: .public)")
        fileLog.append(level: "INFO", category: "App", loc: "\(file):\(line)", msg: msg)
        LogReporter.shared.enqueue(level: "INFO", category: "App", location: "\(file):\(line)", message: msg)
    }

    static func error(_ msg: String, file: String = #fileID, line: Int = #line) {
        logger.error("[\(file, privacy: .public):\(line, privacy: .public)] \(msg, privacy: .public)")
        fileLog.append(level: "ERROR", category: "App", loc: "\(file):\(line)", msg: msg)
        LogReporter.shared.enqueue(level: "ERROR", category: "App", location: "\(file):\(line)", message: msg)
    }

    static func mem(_ context: String, file: String = #fileID, line: Int = #line) {
        let used = Self.memoryUsageMB()
        let level: String
        if used > 500 { level = "CRITICAL" }
        else if used > 300 { level = "HIGH" }
        else { level = "OK" }
        let msg = "MEM \(level): \(used)MB — \(context)"
        logger.warning("[\(file, privacy: .public):\(line, privacy: .public)] \(msg, privacy: .public)")
        fileLog.append(level: "WARN", category: "Mem", loc: "\(file):\(line)", msg: msg)
        LogReporter.shared.enqueue(level: "WARN", category: "Mem", location: "\(file):\(line)", message: msg)
    }

    /// 记录上传链路状态（独立 category，Console.app 过滤用）
    static func upload(_ msg: String, file: String = #fileID, line: Int = #line) {
        uploadLogger.notice("[\(file, privacy: .public):\(line, privacy: .public)] \(msg, privacy: .public)")
        fileLog.append(level: "INFO", category: "Upload", loc: "\(file):\(line)", msg: msg)
        LogReporter.shared.enqueue(level: "INFO", category: "Upload", location: "\(file):\(line)", message: msg)
    }

    static func uploadError(_ msg: String, file: String = #fileID, line: Int = #line) {
        uploadLogger.error("[\(file, privacy: .public):\(line, privacy: .public)] \(msg, privacy: .public)")
        fileLog.append(level: "ERROR", category: "Upload", loc: "\(file):\(line)", msg: msg)
        LogReporter.shared.enqueue(level: "ERROR", category: "Upload", location: "\(file):\(line)", message: msg)
    }

    /// 记录相册自动同步状态
    static func sync(_ msg: String, file: String = #fileID, line: Int = #line) {
        logger.notice("[\(file, privacy: .public):\(line, privacy: .public)] SYNC \(msg, privacy: .public)")
        fileLog.append(level: "INFO", category: "Sync", loc: "\(file):\(line)", msg: msg)
        LogReporter.shared.enqueue(level: "INFO", category: "Sync", location: "\(file):\(line)", message: msg)
    }

    static func syncError(_ msg: String, file: String = #fileID, line: Int = #line) {
        logger.error("[\(file, privacy: .public):\(line, privacy: .public)] SYNC \(msg, privacy: .public)")
        fileLog.append(level: "ERROR", category: "Sync", loc: "\(file):\(line)", msg: msg)
        LogReporter.shared.enqueue(level: "ERROR", category: "Sync", location: "\(file):\(line)", message: msg)
    }

    /// 记录下载状态
    static func download(_ msg: String, file: String = #fileID, line: Int = #line) {
        logger.notice("[\(file, privacy: .public):\(line, privacy: .public)] DL \(msg, privacy: .public)")
        fileLog.append(level: "INFO", category: "Download", loc: "\(file):\(line)", msg: msg)
        LogReporter.shared.enqueue(level: "INFO", category: "Download", location: "\(file):\(line)", message: msg)
    }

    static func downloadError(_ msg: String, file: String = #fileID, line: Int = #line) {
        logger.error("[\(file, privacy: .public):\(line, privacy: .public)] DL \(msg, privacy: .public)")
        fileLog.append(level: "ERROR", category: "Download", loc: "\(file):\(line)", msg: msg)
        LogReporter.shared.enqueue(level: "ERROR", category: "Download", location: "\(file):\(line)", message: msg)
    }

    /// 测量一段交互到主线程空闲的耗时（ms）
    /// 原理：调用点采样 t0，DispatchQueue.main.async 排到当前 runloop 末尾
    /// 再采样 t1，差值就是当前主线程 busy 时间 —— 若 hang 就显著
    /// > 100ms 自动升级为 WARN，方便快速过滤"卡顿事件"
    static func perf(_ label: String, file: String = #fileID, line: Int = #line) {
        let t0 = Date()
        let f = file, l = line, lbl = label
        DispatchQueue.main.async {
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            let msg = "\(lbl) \(ms)ms"
            if ms > 100 {
                logger.error("[\(f, privacy: .public):\(l, privacy: .public)] PERF ⚠️ \(msg, privacy: .public)")
                fileLog.append(level: "WARN", category: "Perf", loc: "\(f):\(l)", msg: msg)
                LogReporter.shared.enqueue(level: "WARN", category: "Perf", location: "\(f):\(l)", message: msg)
            } else {
                logger.notice("[\(f, privacy: .public):\(l, privacy: .public)] PERF \(msg, privacy: .public)")
                fileLog.append(level: "INFO", category: "Perf", loc: "\(f):\(l)", msg: msg)
                LogReporter.shared.enqueue(level: "INFO", category: "Perf", location: "\(f):\(l)", message: msg)
            }
        }
    }

    /// 记录 App 生命周期
    static func lifecycle(_ msg: String, file: String = #fileID, line: Int = #line) {
        logger.notice("[\(file, privacy: .public):\(line, privacy: .public)] LIFECYCLE \(msg, privacy: .public)")
        fileLog.append(level: "INFO", category: "Lifecycle", loc: "\(file):\(line)", msg: msg)
        LogReporter.shared.enqueue(level: "INFO", category: "Lifecycle", location: "\(file):\(line)", message: msg)
    }

    /// 记录当前磁盘占用快照
    static func disk(_ context: String, file: String = #fileID, line: Int = #line) {
        let s = DiskDiagnostics.summary()
        let msg = "DISK tmp=\(s.tempBytes.humanReadableBytes) caches=\(s.cachesBytes.humanReadableBytes) docs=\(s.documentsBytes.humanReadableBytes) total=\(s.totalBytes.humanReadableBytes) — \(context)"
        diskLogger.notice("[\(file, privacy: .public):\(line, privacy: .public)] \(msg, privacy: .public)")
        fileLog.append(level: "INFO", category: "Disk", loc: "\(file):\(line)", msg: msg)
        LogReporter.shared.enqueue(level: "INFO", category: "Disk", location: "\(file):\(line)", message: msg)
    }

    /// 当前进程占用内存（MB）
    static func memoryUsageMB() -> Int {
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

// MARK: - File Logger

/// 线程安全的追加型文件日志 —— 单文件 + 尺寸上限触发滚动截断
final class PVFileLogger {
    private let queue = DispatchQueue(label: "com.pandavault.filelog", qos: .utility)
    private let maxBytes: Int64 = 10 * 1024 * 1024    // 10MB 上限
    private let trimToBytes: Int64 = 5 * 1024 * 1024  // 超上限则仅保留最后 5MB

    private let fmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        f.timeZone = TimeZone.current
        return f
    }()

    /// 日志文件路径（Documents/pandavault.log）
    var logFileURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("pandavault.log")
    }

    /// 当前文件字节数（同步读取，供 UI 展示）
    var fileSize: Int64 {
        let url = logFileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return 0 }
        return (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
    }

    /// 追加一条日志（异步、不阻塞调用方）
    func append(level: String, category: String, loc: String, msg: String) {
        let ts = fmt.string(from: Date())
        let line = "[\(ts)][\(level)][\(category)][\(loc)] \(msg)\n"
        queue.async { [weak self] in
            self?.write(line)
        }
    }

    /// 清空日志文件
    func clear() {
        queue.async { [weak self] in
            guard let self else { return }
            try? Data().write(to: self.logFileURL)
        }
    }

    /// 同步等队列 drain —— 分享日志前调用，确保最新条目已落盘
    func flush() {
        queue.sync {}
    }

    // MARK: - 内部实现（仅在 queue 上调用）

    private func write(_ line: String) {
        let data = Data(line.utf8)
        let url = logFileURL
        if !FileManager.default.fileExists(atPath: url.path) {
            try? data.write(to: url)
            return
        }
        do {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            // 每次 append 后检查一下尺寸；attributesOfItem 是 stat 级调用，开销可忽略
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
            if size > maxBytes {
                try rotate(url: url, currentSize: size)
            }
        } catch {
            // 不递归日志，失败就丢一条
        }
    }

    /// 把当前文件尾部 `trimToBytes` 字节读出，覆盖写回，实现"保留最近 N MB"的简单滚动
    private func rotate(url: URL, currentSize: Int64) throws {
        let offset = currentSize - trimToBytes
        let reader = try FileHandle(forReadingFrom: url)
        try reader.seek(toOffset: UInt64(offset))
        let tail = try reader.readToEnd() ?? Data()
        try reader.close()
        // 从第一个换行之后截开，避免半行日志污染
        if let nlIdx = tail.firstIndex(of: 0x0A) {
            let start = tail.index(after: nlIdx)
            try tail[start...].write(to: url)
        } else {
            try tail.write(to: url)
        }
    }
}
