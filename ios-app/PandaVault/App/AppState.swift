import SwiftUI
import Combine

@MainActor
final class AppState: ObservableObject {
    @Published var serverURL: String {
        didSet {
            UserDefaults.standard.set(serverURL, forKey: "serverURL")
            _api = APIService(baseURL: serverURL)
            LogReporter.shared.updateServerURL(serverURL)
        }
    }
    @Published var isConnected = false
    /// 子屏进入批量选择时置 true，MainTabView 据此隐藏浮动 CTabBar，让
    /// FloatingBatchBar 占据底部（避免二者重合）
    @Published var tabBarHidden = false

    let downloadManager = DownloadManager()
    private var _api: APIService!
    var api: APIService { _api }

    init() {
        let url = UserDefaults.standard.string(forKey: "serverURL") ?? ""
        self.serverURL = url
        self._api = APIService(baseURL: url)
    }

    func updateServerURL(_ url: String) {
        serverURL = url
        downloadManager.updateAPI(api)
    }

    func checkConnection() async {
        do {
            isConnected = try await api.ping()
        } catch {
            isConnected = false
        }
    }
}
