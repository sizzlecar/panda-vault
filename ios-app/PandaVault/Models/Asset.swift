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
