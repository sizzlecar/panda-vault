import Foundation
import UIKit

/// 客户端日志远程上报：批量缓冲 + 定时/触发式 flush，POST 到后端 /api/client-logs
/// PVLog 的每个调用都会同步 enqueue（非阻塞），后台任务负责实际发送
final class LogReporter: @unchecked Sendable {
    static let shared = LogReporter()

    // 缓冲与上限
    private let lock = NSLock()
    private var buffer: [Entry] = []
    private let maxBufferSize = 1000          // 内存上限：最多 1000 条；超出丢最旧
    private let flushBatchSize = 50            // 凑够 50 条立即 flush

    // 服务器与设备身份
    private var serverBaseURL: String = ""    // 由 start/updateServerURL 写入；空则跳过
    private let deviceId: String
    private let deviceName: String
    private let appVersion: String

    // 定时任务
    private var timerTask: Task<Void, Never>?

    private init() {
        self.deviceId = UIDevice.current.identifierForVendor?.uuidString ?? "unknown"
        self.deviceName = UIDevice.current.name  // iOS16+ 隐私限制下通常返回机型，足够用作分组
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        self.appVersion = "\(v) (\(b))"
    }

    // MARK: - Public

    /// 在 App 启动时调用一次。serverURL 可为空（待用户配置后再 update）
    func start(serverURL: String) {
        updateServerURL(serverURL)
        startTimer()
        observeLifecycle()
    }

    /// 服务器地址变化（用户在 Settings 改了）后调用
    func updateServerURL(_ url: String) {
        let trimmed = url.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        serverBaseURL = trimmed
    }

    /// 由 PVLog 同步调用，线程安全、非阻塞
    func enqueue(level: String, category: String, location: String, message: String, ts: Date = Date()) {
        let entry = Entry(
            ts: ts.timeIntervalSince1970,
            level: level,
            category: category,
            location: location,
            message: message
        )
        var shouldFlush = false
        lock.lock()
        buffer.append(entry)
        if buffer.count > maxBufferSize {
            buffer.removeFirst(buffer.count - maxBufferSize)
        }
        if buffer.count >= flushBatchSize {
            shouldFlush = true
        }
        lock.unlock()

        if shouldFlush {
            Task.detached { [weak self] in await self?.flush() }
        }
    }

    /// 主动 flush（lifecycle 切换、Settings 操作时可调）
    func flush() async {
        guard !serverBaseURL.isEmpty else { return }
        lock.lock()
        let toSend = buffer
        buffer.removeAll(keepingCapacity: true)
        lock.unlock()

        guard !toSend.isEmpty else { return }

        do {
            try await send(entries: toSend)
        } catch {
            // 失败：把这批塞回去（前面），并保持上限
            lock.lock()
            buffer.insert(contentsOf: toSend, at: 0)
            if buffer.count > maxBufferSize {
                buffer.removeFirst(buffer.count - maxBufferSize)
            }
            lock.unlock()
        }
    }

    var pendingCount: Int {
        lock.lock(); defer { lock.unlock() }
        return buffer.count
    }

    // MARK: - Private

    private func send(entries: [Entry]) async throws {
        guard let url = URL(string: "\(serverBaseURL)/api/client-logs") else {
            throw URLError(.badURL)
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 15

        let payload = IngestPayload(
            deviceId: deviceId,
            deviceName: deviceName,
            appVersion: appVersion,
            entries: entries
        )
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        req.httpBody = try encoder.encode(payload)

        let (_, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }

    private func startTimer() {
        timerTask?.cancel()
        timerTask = Task.detached { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000) // 30s
                await self?.flush()
            }
        }
    }

    private func observeLifecycle() {
        let nc = NotificationCenter.default
        nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { [weak self] _ in
            Task.detached { await self?.flush() }
        }
        nc.addObserver(forName: UIApplication.willTerminateNotification, object: nil, queue: nil) { [weak self] _ in
            Task.detached { await self?.flush() }
        }
    }

    // MARK: - DTO

    private struct Entry: Codable {
        let ts: Double
        let level: String
        let category: String
        let location: String
        let message: String
    }

    private struct IngestPayload: Encodable {
        let deviceId: String
        let deviceName: String
        let appVersion: String
        let entries: [Entry]
    }
}
