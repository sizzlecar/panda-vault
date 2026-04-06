import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var bonjour = BonjourBrowser()
    @State private var showManualInput = false

    var body: some View {
        Group {
            if appState.isConnected {
                MainTabView()
            } else {
                discoveryView
            }
        }
        .task {
            if !appState.serverURL.isEmpty {
                await appState.checkConnection()
                if appState.isConnected { return }
            }
            bonjour.startSearch()
        }
        .onChange(of: bonjour.discoveredServer) { _, server in
            guard let server else { return }
            appState.updateServerURL(server)
            Task { await appState.checkConnection() }
        }
    }

    private var discoveryView: some View {

            VStack(spacing: 28) {
                Spacer()

                // 像素风标题
                Text("PANDA\nVAULT")
                    .font(.system(size: 42, weight: .black, design: .monospaced))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)
                    .tracking(6)

                Text(">>> 私有媒体库 <<<")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(PV.cyan)
                    .tracking(3)

                if bonjour.isSearching {
                    VStack(spacing: 12) {
                        ProgressView()
                            .tint(PV.cyan)
                        Text("SCANNING LAN...")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .tracking(2)
                    }
                    .padding(.top, 20)
                } else if !appState.isConnected {
                    VStack(spacing: 16) {
                        Text("[ 未找到服务器 ]")
                            .font(.system(.subheadline, design: .monospaced))
                            .foregroundStyle(PV.orange)

                        Text("确认电脑已启动 PandaVault\n且手机与电脑在同一 WiFi")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)

                        HStack(spacing: 12) {
                            Button("重新搜索") { bonjour.startSearch() }
                                .buttonStyle(PixelButtonStyle(color: PV.cyan))

                            Button("手动输入") { showManualInput = true }
                                .buttonStyle(PixelButtonStyle(color: Color(.secondarySystemFill)))
                        }
                        .padding(.top, 8)
                    }
                }

                Spacer()
                Spacer()
            }
        .sheet(isPresented: $showManualInput) {
            ManualInputSheet()
                .environmentObject(appState)
        }
    }
}

struct ManualInputSheet: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var serverInput = ""
    @State private var isTesting = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ZStack {
                Form {
                    Section {
                        TextField("http://192.168.1.x:8080", text: $serverInput)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                    } footer: {
                        Text("输入电脑的局域网 IP 地址和端口")
                    }

                    if let err = errorMessage {
                        Section {
                            Text(err).foregroundStyle(PV.orange).font(.caption)
                        }
                    }

                    Section {
                        Button {
                            Task { await connect() }
                        } label: {
                            HStack {
                                Spacer()
                                if isTesting { ProgressView().tint(PV.cyan) } else { Text("CONNECT").tracking(2) }
                                Spacer()
                            }
                        }
                        .disabled(serverInput.isEmpty || isTesting)
                    }
                }
                
            }
            .navigationTitle("手动连接")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }

    private func connect() async {
        isTesting = true
        errorMessage = nil
        defer { isTesting = false }

        let testAPI = APIService(baseURL: serverInput)
        do {
            let ok = try await testAPI.ping()
            if ok {
                appState.updateServerURL(serverInput)
                appState.isConnected = true
                dismiss()
            } else { errorMessage = "服务状态异常" }
        } catch { errorMessage = "连接失败，请检查地址" }
    }
}

struct MainTabView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        TabView {
            GalleryView()
                .tabItem { Label("素材库", systemImage: "square.grid.2x2") }
            UploadView()
                .tabItem { Label("上传", systemImage: "arrow.up.square") }
            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape") }
        }
        .tint(PV.cyan)
    }
}
