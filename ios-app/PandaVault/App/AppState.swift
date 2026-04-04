import SwiftUI
import Combine

@MainActor
final class AppState: ObservableObject {
    @Published var serverURL: String {
        didSet {
            UserDefaults.standard.set(serverURL, forKey: "serverURL")
            _api = APIService(baseURL: serverURL)
        }
    }
    @Published var isConnected = false

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
