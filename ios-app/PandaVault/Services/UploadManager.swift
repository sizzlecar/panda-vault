import Foundation
import Photos
import SwiftUI

@MainActor
final class UploadManager: ObservableObject {
    @Published var tasks: [UploadTask] = []
    @Published var isUploading = false

    private var api: APIService
    private let chunkSize = 8 * 1024 * 1024 // 8MB — 降低单次内存峰值
    private let largeFileThreshold: Int64 = 10 * 1024 * 1024 // 10MB: 以上走分片（流式读文件，低内存）
    // 并发数根据文件大小自适应：大文件少并发（带宽瓶颈），小文件多并发（延迟瓶颈）
    private var maxConcurrent: Int {
        let avgSize = tasks.filter({ $0.status == .pending }).map(\.fileSize).reduce(0, +)
            / max(1, Int64(tasks.filter({ $0.status == .pending }).count))
        if avgSize > 100 * 1024 * 1024 { return 2 }  // >100MB: 2路
        if avgSize > 10 * 1024 * 1024 { return 3 }   // >10MB: 3路
        return 5                                       // 小文件: 5路
    }
    private let maxRetries = 3

    init(api: APIService) {
        self.api = api
    }

    func updateAPI(_ api: APIService) {
        self.api = api
    }

    var activeTasks: [UploadTask] {
        tasks.filter {
            if case .uploading = $0.status { return true }
            if case .pending = $0.status { return true }
            return false
        }
    }

    var failedTasks: [UploadTask] {
        tasks.filter { if case .failed = $0.status { return true }; return false }
    }

    var completedCount: Int {
        tasks.filter {
            if case .completed = $0.status { return true }
            if case .duplicated = $0.status { return true }
            return false
        }.count
    }

    var hasFailedTasks: Bool {
        tasks.contains { if case .failed = $0.status { return true }; return false }
    }

    var statusSummary: String {
        let done = tasks.filter {
            if case .completed = $0.status { return true }
            if case .duplicated = $0.status { return true }
            return false
        }.count
        let failed = tasks.filter { if case .failed = $0.status { return true }; return false }.count
        let total = tasks.count
        if failed > 0 { return "\(done)/\(total) 完成, \(failed) 失败" }
        return "\(done)/\(total) 完成"
    }

    func addFiles(
        _ urls: [(url: URL, filename: String, size: Int64, shootAt: Date?, localIdentifier: String?)],
        folderId: UUID? = nil
    ) {
        let before = tasks.count
        for file in urls {
            let task = UploadTask(
                filename: file.filename,
                fileURL: file.url,
                fileSize: file.size,
                folderId: folderId,
                shootAt: file.shootAt,
                localIdentifier: file.localIdentifier
            )
            tasks.append(task)
        }
        let pending = tasks.filter { $0.status == .pending }.count
        PVLog.upload("addFiles: +\(urls.count)（先前队列 \(before) → 现在 \(tasks.count)，pending=\(pending)，isUploading=\(isUploading)）")
        Task { await processQueue() }
    }

    func retryFailed() {
        for task in tasks {
            if case .failed = task.status {
                task.status = .pending
            }
        }
        Task { await processQueue() }
    }

    // MARK: - Queue

    private func processQueue() async {
        if isUploading {
            let pending = tasks.filter { $0.status == .pending }.count
            PVLog.upload("processQueue: 已在运行，跳过调用（pending=\(pending)） — ⚠️ 这些 pending 可能被吞掉")
            return
        }
        isUploading = true
        defer { isUploading = false }

        let pendingSnapshot = tasks.filter { $0.status == .pending }
        PVLog.upload("processQueue: 启动（pending=\(pendingSnapshot.count)，maxConcurrent=\(maxConcurrent)）")

        await withTaskGroup(of: Void.self) { group in
            var running = 0
            for task in tasks where task.status == .pending {
                if running >= maxConcurrent {
                    await group.next()
                    running -= 1
                }
                running += 1
                group.addTask { [self] in
                    await self.uploadOne(task)
                }
            }
        }

        let doneAfter = tasks.filter {
            if case .completed = $0.status { return true }
            if case .duplicated = $0.status { return true }
            return false
        }.count
        let pendingAfter = tasks.filter { $0.status == .pending }.count
        let failedAfter = tasks.filter { if case .failed = $0.status { return true }; return false }.count
        PVLog.upload("processQueue: 结束（done=\(doneAfter) failed=\(failedAfter) 剩余pending=\(pendingAfter) 总=\(tasks.count)）")
        if pendingAfter > 0 {
            PVLog.uploadError("⚠️ 退出时仍有 \(pendingAfter) 个 pending — 它们将不会被自动处理（需再次触发 addFiles/retry）")
        }
    }

    private func uploadOne(_ task: UploadTask) async {
        let fileExists = FileManager.default.fileExists(atPath: task.fileURL.path)
        PVLog.upload("uploadOne[start] \(task.filename) size=\(task.fileSize) exists=\(fileExists) url=\(task.fileURL.lastPathComponent)")
        PVLog.mem("开始上传: \(task.filename) size=\(task.fileSize)")
        await MainActor.run { task.status = .uploading(progress: 0) }

        defer {
            // Clean up temp file from photo export after upload completes (success or failure)
            let removed = (try? FileManager.default.removeItem(at: task.fileURL)) != nil
            PVLog.upload("uploadOne[cleanup] \(task.filename) tempRemoved=\(removed)")
        }

        // 上传前预检：首尾 hash 判重，命中则跳过上传
        if let fp = await FileFingerprint.compute(url: task.fileURL, size: task.fileSize) {
            if let result = try? await api.checkDuplicate(size: fp.size, headHash: fp.headHash, tailHash: fp.tailHash),
               result.exists {
                let assetId = result.assetId ?? UUID()
                await MainActor.run { task.status = .duplicated(assetId: assetId) }
                PVLog.upload("uploadOne[duplicate] \(task.filename) assetId=\(assetId)")
                return
            }
        }

        for attempt in 1...maxRetries {
            do {
                if task.fileSize < largeFileThreshold {
                    try await simpleUpload(task)
                } else {
                    try await chunkedUpload(task)
                }
                PVLog.upload("uploadOne[success] \(task.filename) attempt=\(attempt)")
                return
            } catch {
                PVLog.uploadError("uploadOne[retry] \(task.filename) attempt=\(attempt)/\(maxRetries) err=\(error.localizedDescription)")
                if attempt < maxRetries {
                    try? await Task.sleep(nanoseconds: UInt64(pow(2.0, Double(attempt))) * 1_000_000_000)
                    await MainActor.run { task.status = .uploading(progress: 0) }
                } else {
                    await MainActor.run { task.status = .failed(message: error.localizedDescription) }
                    PVLog.uploadError("uploadOne[failed] \(task.filename) 最终失败: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Simple Upload (< 10MB)
    // 关键：把 multipart body 写到磁盘临时文件，上传用 `session.upload(fromFile:)`，
    //       避免整个文件 + multipart body 读进内存（之前 5 路并发 50MB simpleUpload
    //       曾把内存撑到 890MB 被 jetsam 杀）

    private func simpleUpload(_ task: UploadTask) async throws {
        guard let url = URL(string: "\(api.baseURL)/api/upload") else { throw APIError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 600

        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let bodyURL = try writeMultipartBodyToDisk(task: task, boundary: boundary)
        defer { try? FileManager.default.removeItem(at: bodyURL) }

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 3600  // 1小时，大文件服务端处理慢
        config.timeoutIntervalForResource = 7200 // 2小时
        let session = URLSession(configuration: config)
        let (data, response) = try await session.upload(for: request, fromFile: bodyURL)

        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw APIError.httpError(statusCode: code)
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .secondsSince1970

        struct Wrapper: Decodable { let asset: Asset }
        let w = try decoder.decode(Wrapper.self, from: data)

        await MainActor.run { task.status = .completed(assetId: w.asset.id) }
    }

    /// 把 multipart body 流式写到 tmp 文件：[前置字段] + [文件内容流式 copy] + [结束 boundary]
    private func writeMultipartBodyToDisk(task: UploadTask, boundary: String) throws -> URL {
        let bodyURL = FileManager.default.temporaryDirectory.appendingPathComponent("upload_body_\(UUID().uuidString)")
        FileManager.default.createFile(atPath: bodyURL.path, contents: nil)
        let writer = try FileHandle(forWritingTo: bodyURL)
        defer { try? writer.close() }

        func writePart(_ s: String) throws {
            try writer.write(contentsOf: Data(s.utf8))
        }

        if let fid = task.folderId {
            try writePart("--\(boundary)\r\n")
            try writePart("Content-Disposition: form-data; name=\"folder_id\"\r\n\r\n")
            try writePart("\(fid.uuidString)\r\n")
        }
        if let shootAt = task.shootAt {
            try writePart("--\(boundary)\r\n")
            try writePart("Content-Disposition: form-data; name=\"shoot_at\"\r\n\r\n")
            try writePart("\(shootAt.timeIntervalSince1970)\r\n")
        }
        try writePart("--\(boundary)\r\n")
        try writePart("Content-Disposition: form-data; name=\"file\"; filename=\"\(task.filename)\"\r\n")
        try writePart("Content-Type: application/octet-stream\r\n\r\n")

        // 流式把文件内容 copy 到 body
        let reader = try FileHandle(forReadingFrom: task.fileURL)
        defer { try? reader.close() }
        let bufSize = 256 * 1024 // 256KB，内存上限极低
        while let chunk = try reader.read(upToCount: bufSize), !chunk.isEmpty {
            try writer.write(contentsOf: chunk)
        }

        try writePart("\r\n--\(boundary)--\r\n")
        return bodyURL
    }

    // MARK: - Chunked Upload (>= 50MB)

    private func chunkedUpload(_ task: UploadTask) async throws {
        // 1. Init
        let initResp = try await api.initChunkedUpload(filename: task.filename, fileSize: task.fileSize, shootAt: task.shootAt)

        // 2. Query offset (断点续传)
        let offsetResp = try await api.queryUploadOffset(uploadId: initResp.uploadId)
        var currentOffset = offsetResp.offset

        // 3. 分片发送
        let handle = try FileHandle(forReadingFrom: task.fileURL)
        defer { try? handle.close() }

        if currentOffset > 0 {
            try handle.seek(toOffset: UInt64(currentOffset))
        }

        while currentOffset < task.fileSize {
            let readSize = min(Int(task.fileSize - currentOffset), chunkSize)
            guard let chunk = try handle.read(upToCount: readSize), !chunk.isEmpty else { break }

            try await api.uploadChunk(uploadId: initResp.uploadId, offset: currentOffset, chunk: chunk)

            currentOffset += Int64(chunk.count)
            await MainActor.run { task.status = .uploading(progress: Double(currentOffset) / Double(task.fileSize)) }
        }

        // 4. Complete
        let result = try await api.completeChunkedUpload(uploadId: initResp.uploadId)

        // 5. 关联文件夹（分片上传的 complete 不经过 upload handler，需要手动关联）
        if let fid = task.folderId {
            try? await api.addAssetToFolder(folderId: fid, assetId: result.assetId)
        }

        await MainActor.run {
            task.status = .completed(assetId: result.assetId)
        }
    }
}
