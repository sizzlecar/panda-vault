import Foundation

/// 磁盘占用诊断 —— 扫描 tmp / Caches / Documents 三个目录，汇总尺寸并可清理临时文件
enum DiskDiagnostics {

    struct Summary {
        let tempBytes: Int64
        let cachesBytes: Int64
        let documentsBytes: Int64
        var totalBytes: Int64 { tempBytes + cachesBytes + documentsBytes }
    }

    struct FileEntry {
        let url: URL
        let size: Int64
        let modified: Date
    }

    struct Report {
        let summary: Summary
        let topTempFiles: [FileEntry]   // tmp 目录按大小 desc 的 Top N
        let topCachesFiles: [FileEntry]
    }

    // MARK: - Paths

    static var tempDir: URL { FileManager.default.temporaryDirectory }
    static var cachesDir: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
    }
    static var documentsDir: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    }

    // MARK: - Public API

    static func summary() -> Summary {
        Summary(
            tempBytes: directorySize(tempDir),
            cachesBytes: directorySize(cachesDir),
            documentsBytes: directorySize(documentsDir)
        )
    }

    static func fullReport(topN: Int = 10) -> Report {
        Report(
            summary: summary(),
            topTempFiles: topFiles(in: tempDir, limit: topN),
            topCachesFiles: topFiles(in: cachesDir, limit: topN)
        )
    }

    /// 删除 tmp 目录下修改时间早于 N 秒的文件，返回 (删除数, 释放字节数)
    @discardableResult
    static func cleanTemp(olderThan seconds: TimeInterval = 600) -> (removed: Int, bytes: Int64) {
        let cutoff = Date().addingTimeInterval(-seconds)
        var removed = 0
        var freed: Int64 = 0

        let fm = FileManager.default
        guard let iter = fm.enumerator(
            at: tempDir,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isDirectoryKey],
            options: [.skipsSubdirectoryDescendants]
        ) else {
            return (0, 0)
        }

        for case let url as URL in iter {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isDirectoryKey])
            if values?.isDirectory == true { continue }
            guard let modified = values?.contentModificationDate, modified < cutoff else { continue }
            let size = Int64(values?.fileSize ?? 0)
            do {
                try fm.removeItem(at: url)
                removed += 1
                freed += size
            } catch {
                PVLog.error("清理 tmp 失败 \(url.lastPathComponent): \(error)")
            }
        }
        return (removed, freed)
    }

    // MARK: - Helpers

    static func directorySize(_ dir: URL) -> Int64 {
        var total: Int64 = 0
        guard let iter = FileManager.default.enumerator(
            at: dir,
            includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey]
        ) else { return 0 }

        for case let url as URL in iter {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
            if values?.isDirectory == true { continue }
            total += Int64(values?.fileSize ?? 0)
        }
        return total
    }

    private static func topFiles(in dir: URL, limit: Int) -> [FileEntry] {
        var entries: [FileEntry] = []
        guard let iter = FileManager.default.enumerator(
            at: dir,
            includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey, .contentModificationDateKey]
        ) else { return [] }

        for case let url as URL in iter {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey, .contentModificationDateKey])
            if values?.isDirectory == true { continue }
            let size = Int64(values?.fileSize ?? 0)
            let modified = values?.contentModificationDate ?? .distantPast
            entries.append(FileEntry(url: url, size: size, modified: modified))
        }
        return entries.sorted { $0.size > $1.size }.prefix(limit).map { $0 }
    }
}

extension Int64 {
    var humanReadableBytes: String {
        ByteCountFormatter.string(fromByteCount: self, countStyle: .file)
    }
}
