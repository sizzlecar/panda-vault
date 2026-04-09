import Foundation
import os

/// 统一日志，输出到 Xcode Console 且可通过 Console.app 查看
enum PVLog {
    private static let logger = Logger(subsystem: "com.pandavault.app", category: "PandaVault")

    static func info(_ msg: String, file: String = #fileID, line: Int = #line) {
        logger.info("[\(file):\(line)] \(msg)")
    }

    static func error(_ msg: String, file: String = #fileID, line: Int = #line) {
        logger.error("[\(file):\(line)] \(msg)")
    }

    static func mem(_ context: String, file: String = #fileID, line: Int = #line) {
        let used = Self.memoryUsageMB()
        let level: String
        if used > 500 { level = "CRITICAL" }
        else if used > 300 { level = "HIGH" }
        else { level = "OK" }
        logger.warning("[\(file):\(line)] MEM \(level): \(used)MB — \(context)")
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
