import SwiftUI

@main
struct PandaVaultApp: App {
    @StateObject private var appState = AppState()

    init() {
        BackgroundSyncManager.shared.registerTasks()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
        }
    }
}
