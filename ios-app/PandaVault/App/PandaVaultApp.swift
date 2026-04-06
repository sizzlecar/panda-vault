import SwiftUI

@main
struct PandaVaultApp: App {
    @StateObject private var appState = AppState()

    init() {
        BackgroundSyncManager.shared.registerTasks()
        // 限制 URL 缓存，防止缩略图撑爆内存
        URLCache.shared.memoryCapacity = 50 * 1024 * 1024  // 50MB
        URLCache.shared.diskCapacity = 200 * 1024 * 1024    // 200MB
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .preferredColorScheme(.light)
        }
    }
}
