import SwiftUI

@main
struct PandaVaultApp: App {
    @StateObject private var appState = AppState()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        BackgroundSyncManager.shared.registerTasks()
        // 限制 URL 缓存，防止缩略图撑爆内存
        URLCache.shared.memoryCapacity = 50 * 1024 * 1024  // 50MB
        URLCache.shared.diskCapacity = 200 * 1024 * 1024    // 200MB
        // 启动远程日志上报（serverURL 由 AppState 写入；这里先空跑，后续 AppState 触发 update）
        let savedServerURL = UserDefaults.standard.string(forKey: "serverURL") ?? ""
        LogReporter.shared.start(serverURL: savedServerURL)
        PVLog.lifecycle("App 启动")
        // 启动时：记录磁盘快照 + 清理 10 分钟以上没动的 tmp 孤儿
        // （app 被 jetsam 杀后，UploadManager/PhotoLibraryService 的 defer 清理不会跑，
        //  留下的导出副本会一直堆在 tmp —— 实测可达 14GB）
        DispatchQueue.global(qos: .utility).async {
            PVLog.disk("App 启动")
            let r = DiskDiagnostics.cleanTemp(olderThan: 600)
            if r.removed > 0 {
                PVLog.info("启动清理 tmp 孤儿: 删 \(r.removed) 个文件 / 释放 \(r.bytes.humanReadableBytes)")
                PVLog.disk("tmp 清理后")
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .environmentObject(appState.uploadManager) // Share Extension 也喂这同一个
                .preferredColorScheme(.light)
                .tint(PV.caramel)
                .background(PV.bg.ignoresSafeArea())
                .task {
                    // 启动时扫 Share Extension 投进来的文件
                    let n = await appState.ingestShareInbox()
                    PVLog.lifecycle("启动扫 shareInbox: 入队 \(n) 项")
                }
        }
        .onChange(of: scenePhase) { _, newPhase in
            // 从后台回前台：扫一次 inbox，捕获刚从微信/剪映分享过来的
            if newPhase == .active {
                Task {
                    let n = await appState.ingestShareInbox()
                    if n > 0 { PVLog.lifecycle("前台回归扫 shareInbox: 入队 \(n) 项") }
                }
            }
        }
    }
}
