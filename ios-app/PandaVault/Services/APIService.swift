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

    func getAsset(id: UUID) async throws -> Asset {
        try await get("/api/assets/\(id)")
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

    func semanticSearch(text: String, limit: Int = 20) async throws -> [Asset] {
        struct SearchRequest: Codable { let text: String; let limit: Int }
        struct SearchResult: Decodable { let asset: Asset; let similarity: Double }
        struct SearchResponse: Decodable { let results: [SearchResult] }
        let resp: SearchResponse = try await post("/api/search/semantic", body: SearchRequest(text: text, limit: limit))
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

    // MARK: - Duplicate Check

    func checkDuplicate(fingerprint: String) async throws -> Bool {
        struct Req: Codable { let fingerprint: String }
        struct Resp: Decodable { let exists: Bool }
        let resp: Resp = try await post("/api/assets/check-duplicate", body: Req(fingerprint: fingerprint))
        return resp.exists
    }

    // MARK: - Folders

    func getFolders(parentId: UUID? = nil) async throws -> [Folder] {
        var path = "/api/folders"
        if let pid = parentId { path += "?parent_id=\(pid)" }
        return try await get(path)
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

    func getFolderAssets(folderId: UUID, limit: Int = 200, offset: Int = 0) async throws -> [Asset] {
        try await get("/api/folders/\(folderId)/assets?limit=\(limit)&offset=\(offset)")
    }

    // MARK: - Upload (simple multipart)

    func uploadFile(fileURL: URL, folderId: UUID? = nil) async throws -> Asset {
        guard let url = makeURL("/api/upload") else { throw APIError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"

        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let data = try Data(contentsOf: fileURL)
        var body = Data()

        if let fid = folderId {
            body.appendMultipart(boundary: boundary, name: "folder_id", value: fid.uuidString)
        }
        body.appendMultipart(boundary: boundary, name: "file", filename: fileURL.lastPathComponent, data: data)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        request.httpBody = body

        let (responseData, response) = try await session.data(for: request)
        try validateResponse(response)
        let wrapper = try decoder.decode(UploadWrapper.self, from: responseData)
        return wrapper.asset
    }

    // MARK: - Chunked Upload

    func initChunkedUpload(filename: String, fileSize: Int64) async throws -> UploadInitResponse {
        struct InitRequest: Codable { let filename: String; let fileSize: Int64 }
        return try await post("/api/upload/init", body: InitRequest(filename: filename, fileSize: fileSize))
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
        return URL(string: "\(baseURL)\(path)")
    }

    func proxyURL(for asset: Asset) -> URL? {
        guard let path = asset.proxyPath else { return nil }
        return URL(string: "\(baseURL)\(path)")
    }

    func downloadURL(for asset: Asset) -> URL? {
        URL(string: "\(baseURL)/api/assets/\(asset.id)/download")
    }

    func folderCoverURL(for folder: Folder) -> URL? {
        guard let path = folder.coverThumbPath, !path.isEmpty else { return nil }
        return URL(string: "\(baseURL)\(path)")
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
