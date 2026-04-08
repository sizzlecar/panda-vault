import Foundation
import CryptoKit

struct FileFingerprint {
    let size: Int64
    let headHash: String
    let tailHash: String

    /// 在后台线程计算文件指纹：大小 + 首 1MB SHA256 + 尾 1MB SHA256
    static func compute(url: URL, size: Int64) async -> FileFingerprint? {
        await Task.detached {
            guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? handle.close() }

            let chunkSize = 1024 * 1024 // 1MB

            // 首 1MB
            let headSize = min(chunkSize, Int(size))
            guard let headData = try? handle.read(upToCount: headSize) else { return nil }
            let headHash = SHA256.hash(data: headData).compactMap { String(format: "%02x", $0) }.joined()

            // 尾 1MB
            let tailStart = max(0, Int64(size) - Int64(chunkSize))
            try? handle.seek(toOffset: UInt64(tailStart))
            guard let tailData = try? handle.read(upToCount: chunkSize) else { return nil }
            let tailHash = SHA256.hash(data: tailData).compactMap { String(format: "%02x", $0) }.joined()

            return FileFingerprint(size: size, headHash: headHash, tailHash: tailHash)
        }.value
    }
}
