import Foundation

final class APIService: Sendable {
    let baseURL: String
    private let session: URLSession
    private let decoder: JSONDecoder

    init(baseURL: String) {
        self.baseURL = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 3600
        self.session = URLSession(configuration: config)

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .secondsSince1970
        self.decoder = decoder
    }

    private func makeURL(_ path: String) -> URL? {
        guard !baseURL.isEmpty else { return nil }
        return URL(string: "\(baseURL)\(path)")
    }

    // MARK: - Health

    func healthCheck() async throws -> HealthResponse {
        try await get("/api/health")
    }

    func ping() async throws -> Bool {
        guard let url = makeURL("/api/health") else { return false }
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return false }
        let text = String(data: data, encoding: .utf8) ?? ""
        return text.contains("ok")
    }

    // MARK: - Assets

    func getAssets(query: String? = nil, limit: Int = 50, offset: Int = 0) async throws -> [Asset] {
        var params = "limit=\(limit)&offset=\(offset)"
        if let q = query, !q.isEmpty {
            params += "&q=\(q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? q)"
        }
        return try await get("/api/assets?\(params)")
    }

    /// 按月获取资产，month 格式 "2026-04"
    func getAssetsByMonth(month: String, limit: Int = 500, offset: Int = 0) async throws -> [Asset] {
        let params = "month=\(month)&limit=\(limit)&offset=\(offset)"
        return try await get("/api/assets?\(params)")
    }

    func getAsset(id: UUID) async throws -> Asset {
        try await get("/api/assets/\(id)")
    }

    /// 更新资产（当前支持修改 filename 和 note；传 note: nil 表示不动，传 note: "" 清空）
    func updateAsset(id: UUID, filename: String? = nil, note: String? = nil) async throws -> Asset {
        struct Req: Codable {
            let filename: String?
            let note: String?
        }
        guard let url = makeURL("/api/assets/\(id)") else { throw APIError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        request.httpBody = try encoder.encode(Req(filename: filename, note: note))
        let (data, response) = try await session.data(for: request)
        try validateResponse(response)
        return try decoder.decode(Asset.self, from: data)
    }

    func deleteAsset(id: UUID) async throws {
        guard let url = makeURL("/api/assets/\(id)") else { throw APIError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        let (_, response) = try await session.data(for: request)
        try validateResponse(response)
    }

    // MARK: - Timeline

    func getTimeline() async throws -> [TimelineGroup] {
        try await get("/api/timeline")
    }

    // MARK: - Search

    func semanticSearch(text: String, limit: Int = 20, folderId: UUID? = nil) async throws -> [Asset] {
        struct SearchRequest: Codable {
            let text: String
            let limit: Int
            let folderId: UUID?
        }
        struct SearchResult: Decodable { let asset: Asset; let similarity: Double }
        struct SearchResponse: Decodable { let results: [SearchResult] }
        let resp: SearchResponse = try await post(
            "/api/search/semantic",
            body: SearchRequest(text: text, limit: limit, folderId: folderId)
        )
        return resp.results.map(\.asset)
    }

    // MARK: - Image Search

    func imageSearch(imageData: Data) async throws -> [Asset] {
        guard let url = makeURL("/api/search/image") else { throw APIError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"

        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        body.appendMultipart(boundary: boundary, name: "file", filename: "search.jpg", data: imageData)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        let (data, response) = try await session.data(for: request)
        try validateResponse(response)

        struct SearchResult: Decodable { let asset: Asset; let similarity: Double }
        struct SearchResponse: Decodable { let results: [SearchResult] }
        let resp = try decoder.decode(SearchResponse.self, from: data)
        return resp.results.map(\.asset)
    }

    // MARK: - Volumes

    func getVolumes() async throws -> [VolumeInfo] {
        try await get("/api/volumes")
    }

    // MARK: - Trash

    func getTrash(limit: Int = 200, offset: Int = 0) async throws -> [Asset] {
        return try await get("/api/assets/trash?limit=\(limit)&offset=\(offset)")
    }

    func restoreAssets(ids: [UUID]) async throws {
        struct Req: Codable { let ids: [UUID] }
        struct Resp: Decodable { let restored: Int }
        let _: Resp = try await post("/api/assets/restore", body: Req(ids: ids))
    }

    func permanentlyDeleteAssets(ids: [UUID]) async throws {
        struct Req: Codable { let ids: [UUID] }
        struct Resp: Decodable { let deleted: Int }
        let _: Resp = try await post("/api/assets/trash/empty", body: Req(ids: ids))
    }

    // MARK: - Duplicate Check

    struct DuplicateCheckResult: Decodable {
        let exists: Bool
        let assetId: UUID?
    }

    func checkDuplicate(size: Int64, headHash: String, tailHash: String) async throws -> DuplicateCheckResult {
        struct Req: Codable { let size: Int64; let headHash: String; let tailHash: String }
        return try await post("/api/assets/check-duplicate", body: Req(size: size, headHash: headHash, tailHash: tailHash))
    }

    // MARK: - Folders

    func getFolders(parentId: UUID? = nil) async throws -> [Folder] {
        var path = "/api/folders"
        if let pid = parentId { path += "?parent_id=\(pid)" }
        return try await get(path)
    }

    /// 最近活跃的 N 个文件夹 — 按 updated_at DESC，只返回非空文件夹
    /// 用于素材库时间视图顶部的"最近在整理"横滚卡
    func getRecentFolders(limit: Int = 6) async throws -> [Folder] {
        try await get("/api/folders/recent?limit=\(limit)")
    }

    func createFolder(name: String, parentId: UUID? = nil) async throws -> Folder {
        try await post("/api/folders", body: CreateFolderRequest(name: name, parentId: parentId))
    }

    func deleteFolder(id: UUID) async throws {
        guard let url = makeURL("/api/folders/\(id)") else { throw APIError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        let (_, response) = try await session.data(for: request)
        try validateResponse(response)
    }

    func renameFolder(id: UUID, name: String) async throws {
        struct RenameRequest: Codable { let name: String }
        guard let url = makeURL("/api/folders/\(id)") else { throw APIError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        request.httpBody = try encoder.encode(RenameRequest(name: name))
        let (_, response) = try await session.data(for: request)
        try validateResponse(response)
    }

    func getFolderAssets(folderId: UUID, query: String? = nil, limit: Int = 200, offset: Int = 0) async throws -> [Asset] {
        var params = "limit=\(limit)&offset=\(offset)"
        if let q = query, !q.isEmpty {
            params += "&q=\(q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? q)"
        }
        return try await get("/api/folders/\(folderId)/assets?\(params)")
    }

    func addAssetToFolder(folderId: UUID, assetId: UUID) async throws {
        guard let url = makeURL("/api/folders/\(folderId)/assets/\(assetId)") else { throw APIError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        let (_, response) = try await session.data(for: request)
        try validateResponse(response)
    }

    // MARK: - Upload

    private let largeFileThreshold: Int64 = 50 * 1024 * 1024 // 50MB
    private let chunkSize = 50 * 1024 * 1024 // 50MB — 局域网大分片

    /// 小文件 Data 直传，大文件走分片上传
    func uploadFile(fileURL: URL, folderId: UUID? = nil, shootAt: Date? = nil, onProgress: ((Double) -> Void)? = nil) async throws -> Asset {
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int64) ?? 0

        if fileSize < largeFileThreshold {
            onProgress?(1.0)
            return try await simpleUpload(fileURL: fileURL, folderId: folderId, shootAt: shootAt)
        } else {
            return try await chunkedUploadFile(fileURL: fileURL, fileSize: fileSize, folderId: folderId, onProgress: onProgress)
        }
    }

    /// < 50MB: 整个读进内存，multipart 直传
    private func simpleUpload(fileURL: URL, folderId: UUID?, shootAt: Date? = nil) async throws -> Asset {
        guard let url = makeURL("/api/upload") else { throw APIError.invalidURL }

        let boundary = UUID().uuidString
        let filename = fileURL.lastPathComponent
        let fileData = try Data(contentsOf: fileURL)

        var body = Data()
        if let fid = folderId {
            body.appendMultipart(boundary: boundary, name: "folder_id", value: fid.uuidString)
        }
        if let shootAt {
            body.appendMultipart(boundary: boundary, name: "shoot_at", value: "\(shootAt.timeIntervalSince1970)")
        }
        body.appendMultipart(boundary: boundary, name: "file", filename: filename, data: fileData)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = 3600

        let (responseData, response) = try await session.data(for: request)
        try validateResponse(response)
        return try decoder.decode(UploadWrapper.self, from: responseData).asset
    }

    /// >= 50MB: 分片上传，带进度回调
    private func chunkedUploadFile(fileURL: URL, fileSize: Int64, folderId: UUID?, onProgress: ((Double) -> Void)? = nil) async throws -> Asset {
        let filename = fileURL.lastPathComponent
        let initResp = try await initChunkedUpload(filename: filename, fileSize: fileSize)

        let offsetResp = try await queryUploadOffset(uploadId: initResp.uploadId)
        var currentOffset = offsetResp.offset

        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        if currentOffset > 0 {
            try handle.seek(toOffset: UInt64(currentOffset))
            onProgress?(Double(currentOffset) / Double(fileSize))
        }

        while currentOffset < fileSize {
            let readSize = min(Int(fileSize - currentOffset), chunkSize)
            guard let chunk = try handle.read(upToCount: readSize), !chunk.isEmpty else { break }
            try await uploadChunk(uploadId: initResp.uploadId, offset: currentOffset, chunk: chunk)
            currentOffset += Int64(chunk.count)
            onProgress?(Double(currentOffset) / Double(fileSize))
        }

        let result = try await completeChunkedUpload(uploadId: initResp.uploadId)
        // 分片上传不经过 upload handler，需要手动关联文件夹
        if let fid = folderId {
            try? await addAssetToFolder(folderId: fid, assetId: result.assetId)
        }
        return try await getAsset(id: result.assetId)
    }

    // MARK: - Chunked Upload

    func initChunkedUpload(filename: String, fileSize: Int64, shootAt: Date? = nil) async throws -> UploadInitResponse {
        struct InitRequest: Codable { let filename: String; let fileSize: Int64; let shootAt: Double? }
        let ts = shootAt.map { $0.timeIntervalSince1970 }
        return try await post("/api/upload/init", body: InitRequest(filename: filename, fileSize: fileSize, shootAt: ts))
    }

    func queryUploadOffset(uploadId: String) async throws -> UploadOffsetResponse {
        try await get("/api/upload/\(uploadId)")
    }

    func uploadChunk(uploadId: String, offset: Int64, chunk: Data) async throws {
        guard let url = makeURL("/api/upload/\(uploadId)") else { throw APIError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue("bytes \(offset)-\(offset + Int64(chunk.count) - 1)", forHTTPHeaderField: "Content-Range")
        request.httpBody = chunk

        let (_, response) = try await session.data(for: request)
        try validateResponse(response)
    }

    func completeChunkedUpload(uploadId: String) async throws -> UploadCompleteResponse {
        try await post("/api/upload/\(uploadId)/complete", body: Optional<String>.none)
    }

    // MARK: - Download

    func downloadAsset(id: UUID, progressHandler: @escaping @Sendable (Double) -> Void) async throws -> URL {
        guard let url = makeURL("/api/assets/\(id)/download") else { throw APIError.invalidURL }
        let (tempURL, response) = try await session.download(for: URLRequest(url: url))
        try validateResponse(response)
        progressHandler(1.0)
        // Move to our temp dir to prevent system cleanup
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.moveItem(at: tempURL, to: dest)
        return dest
    }

    // MARK: - URL Builders

    func thumbnailURL(for asset: Asset) -> URL? {
        guard let path = asset.thumbPath else { return nil }
        return buildURL(path: path)
    }

    func proxyURL(for asset: Asset) -> URL? {
        guard let path = asset.proxyPath else { return nil }
        return buildURL(path: path)
    }

    func downloadURL(for asset: Asset) -> URL? {
        URL(string: "\(baseURL)/api/assets/\(asset.id)/download")
    }

    /// 原始文件直接访问（支持 Range 请求，用于视频流式播放）
    func rawURL(for asset: Asset) -> URL? {
        buildURL(path: asset.filePath)
    }

    /// 统一 URL 构造：正确处理中文/特殊字符的 path 编码
    /// 之前用 `addingPercentEncoding(.urlPathAllowed)` 在某些 iOS 版本对中文
    /// 编码不一致（导致详情页图片 404 黑屏）。改用 URLComponents。
    private func buildURL(path: String) -> URL? {
        // 优先 URLComponents（按 RFC 3986 自动逐段转义）
        if var comps = URLComponents(string: baseURL) {
            comps.path = comps.path + path
            if let url = comps.url { return url }
        }
        // fallback: 每个 segment 单独 encoding 再拼回
        let segments = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let encoded = segments.map {
            $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? $0
        }.joined(separator: "/")
        return URL(string: "\(baseURL)\(encoded)")
    }

    func folderCoverURL(for folder: Folder) -> URL? {
        guard let path = folder.coverThumbPath, !path.isEmpty else { return nil }
        return buildURL(path: path)
    }

    // MARK: - Private

    private func get<T: Decodable>(_ path: String) async throws -> T {
        guard let url = makeURL(path) else { throw APIError.invalidURL }
        let (data, response) = try await session.data(from: url)
        try validateResponse(response)
        return try decoder.decode(T.self, from: data)
    }

    private func post<T: Decodable, B: Encodable>(_ path: String, body: B) async throws -> T {
        guard let url = makeURL(path) else { throw APIError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        request.httpBody = try encoder.encode(body)

        let (data, response) = try await session.data(for: request)
        try validateResponse(response)
        return try decoder.decode(T.self, from: data)
    }

    private func validateResponse(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            throw APIError.httpError(statusCode: http.statusCode)
        }
    }
}

// MARK: - Errors

enum APIError: LocalizedError {
    case invalidURL
    case invalidResponse
    case httpError(statusCode: Int)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "服务器地址无效"
        case .invalidResponse: return "服务器响应异常"
        case .httpError(let code): return "请求失败 (\(code))"
        }
    }
}

// MARK: - Helpers

private struct UploadWrapper: Decodable {
    let deduped: Bool
    let asset: Asset
}

extension Data {
    mutating func appendMultipart(boundary: String, name: String, value: String) {
        append("--\(boundary)\r\n".data(using: .utf8)!)
        append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
        append("\(value)\r\n".data(using: .utf8)!)
    }

    mutating func appendMultipart(boundary: String, name: String, filename: String, data: Data) {
        append("--\(boundary)\r\n".data(using: .utf8)!)
        append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        append("Content-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
        append(data)
        append("\r\n".data(using: .utf8)!)
    }
}
