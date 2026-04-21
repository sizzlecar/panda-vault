import Foundation

struct Asset: Codable, Identifiable, Equatable {
    let id: UUID
    let filename: String
    let filePath: String
    let proxyPath: String?
    let thumbPath: String?
    let fileHash: String
    let sizeBytes: Int64
    let shootAt: Date?
    let createdAt: Date
    let durationSec: Int?
    let width: Int?
    let height: Int?
    let deletedAt: Date?
    /// 用户自定义备注（详情页底部编辑）
    let note: String?

    // deletedAt 是可选的，普通列表接口不返回
    enum CodingKeys: String, CodingKey {
        case id, filename, filePath, proxyPath, thumbPath, fileHash, sizeBytes
        case shootAt, createdAt, durationSec, width, height, deletedAt, note
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        filename = try c.decode(String.self, forKey: .filename)
        filePath = try c.decode(String.self, forKey: .filePath)
        proxyPath = try c.decodeIfPresent(String.self, forKey: .proxyPath)
        thumbPath = try c.decodeIfPresent(String.self, forKey: .thumbPath)
        fileHash = try c.decode(String.self, forKey: .fileHash)
        sizeBytes = try c.decode(Int64.self, forKey: .sizeBytes)
        shootAt = try c.decodeIfPresent(Date.self, forKey: .shootAt)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        durationSec = try c.decodeIfPresent(Int.self, forKey: .durationSec)
        width = try c.decodeIfPresent(Int.self, forKey: .width)
        height = try c.decodeIfPresent(Int.self, forKey: .height)
        deletedAt = try c.decodeIfPresent(Date.self, forKey: .deletedAt)
        note = try c.decodeIfPresent(String.self, forKey: .note)
    }

    var isVideo: Bool {
        let ext = (filename as NSString).pathExtension.lowercased()
        return ["mp4", "mov", "m4v", "avi", "mkv", "3gp", "wmv"].contains(ext)
    }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }

    var formattedDuration: String? {
        guard let sec = durationSec else { return nil }
        let m = sec / 60
        let s = sec % 60
        return String(format: "%d:%02d", m, s)
    }

    var resolution: String? {
        guard let w = width, let h = height else { return nil }
        return "\(w) x \(h)"
    }
}

struct AssetPage: Codable {
    let items: [Asset]
    let total: Int
}

struct TimelineGroup: Codable, Identifiable {
    let day: String
    let count: Int

    var id: String { day }

    /// "2026-04-03" → "2026-04"
    var month: String {
        String(day.prefix(7))
    }

    var displayMonth: String {
        let parts = month.split(separator: "-")
        guard parts.count == 2,
              let y = parts.first,
              let mStr = parts.last,
              let m = Int(mStr) else { return month }
        return "\(y)年\(m)月"
    }
}
