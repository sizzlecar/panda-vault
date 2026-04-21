import Foundation

/// 共享收件箱 —— Share Extension 写入、主 app 读取消费
/// 位于 App Group 共享沙箱（两个 target 都能访问）
/// 主 app 启动 / 前台激活时扫一遍 → 喂给 UploadManager
enum ShareInbox {
    static let appGroupID = "group.com.pandavault.app"

    /// Inbox 目录（App Group/inbox）
    /// - Parameter createIfMissing: 不存在时自动创建
    /// - Returns: URL 或 nil（App Group 未配置时）
    static func inboxURL(createIfMissing: Bool = false) -> URL? {
        let fm = FileManager.default
        guard let container = fm.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else {
            return nil
        }
        let dir = container.appendingPathComponent("inbox", isDirectory: true)
        if createIfMissing {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    /// 把 Share Extension 收到的文件写进 inbox
    /// 命名规则：`<UUID>__<原始文件名>`，避免同名覆盖 + 保留原文件名用于 UI 显示
    @discardableResult
    static func write(sourceURL: URL, originalFilename: String?) throws -> URL {
        guard let dir = inboxURL(createIfMissing: true) else {
            throw NSError(domain: "ShareInbox", code: 1, userInfo: [NSLocalizedDescriptionKey: "App Group 未配置"])
        }
        let name = originalFilename ?? sourceURL.lastPathComponent
        let safeName = sanitize(name)
        let dest = dir.appendingPathComponent("\(UUID().uuidString)__\(safeName)")
        try FileManager.default.copyItem(at: sourceURL, to: dest)
        return dest
    }

    /// 扫描 inbox 目录里所有文件（按 mtime 升序）
    static func listPending() -> [URL] {
        guard let dir = inboxURL() else { return [] }
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey, .fileSizeKey]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        )) ?? []
        let files = urls.filter {
            ((try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false)
        }
        return files.sorted { a, b in
            let ad = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let bd = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return ad < bd
        }
    }

    /// 消费一个 inbox 文件：搬到主 app 的 tmp 目录，从 inbox 里移除
    /// 返回 (tmp 里的新 URL, 原始文件名, 字节数)
    static func consume(_ inboxItemURL: URL) -> (url: URL, filename: String, size: Int64)? {
        let fm = FileManager.default
        let rawName = inboxItemURL.lastPathComponent
        // 解析出原始文件名：`<uuid>__<name>` → `<name>`
        let filename: String
        if let range = rawName.range(of: "__") {
            filename = String(rawName[range.upperBound...])
        } else {
            filename = rawName
        }
        let dest = fm.temporaryDirectory.appendingPathComponent("inbox_\(UUID().uuidString)_\(filename)")
        do {
            try fm.moveItem(at: inboxItemURL, to: dest)
        } catch {
            return nil
        }
        let size = (try? fm.attributesOfItem(atPath: dest.path)[.size] as? Int64) ?? 0
        return (dest, filename, size)
    }

    // MARK: - Helpers

    /// 去掉 `/` 等文件名中的非法字符
    private static func sanitize(_ name: String) -> String {
        let bad: Set<Character> = ["/", "\\", ":", "*", "?", "\"", "<", ">", "|"]
        return String(name.map { bad.contains($0) ? "_" : $0 })
    }
}
