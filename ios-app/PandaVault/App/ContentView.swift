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

    // MARK: - Discovery Screen (未连接时)

    private var discoveryView: some View {
        ZStack {
            PV.bg.ignoresSafeArea()

            VStack(spacing: 28) {
                Spacer()

                CPandaHi(size: 96)

                VStack(spacing: 4) {
                    Text("PandaVault")
                        .font(PVFont.display(34, weight: .semibold))
                        .foregroundStyle(PV.ink)
                    Text("私有媒体库")
                        .font(PVFont.body(13))
                        .foregroundStyle(PV.sub)
                }

                if bonjour.isSearching {
                    VStack(spacing: 10) {
                        ProgressView().tint(PV.caramel)
                        Text("正在搜索局域网…")
                            .font(PVFont.body(12))
                            .foregroundStyle(PV.sub)
                    }
                    .padding(.top, 12)
                } else if !appState.isConnected {
                    VStack(spacing: 14) {
                        Text("暂时没找到服务器")
                            .font(PVFont.body(14, weight: .medium))
                            .foregroundStyle(PV.berry)
                        Text("确认电脑已启动 PandaVault\n且手机与电脑在同一 WiFi")
                            .font(PVFont.body(12))
                            .foregroundStyle(PV.muted)
                            .multilineTextAlignment(.center)

                        HStack(spacing: 12) {
                            Button("重新搜索") { bonjour.startSearch() }
                                .buttonStyle(CButtonStyle(tone: PV.caramel, filled: true, height: 44))
                                .frame(maxWidth: 140)
                            Button("手动输入") { showManualInput = true }
                                .buttonStyle(CButtonStyle(tone: PV.bean, filled: false, height: 44))
                                .frame(maxWidth: 140)
                        }
                        .padding(.top, 8)
                    }
                    .padding(.horizontal, 32)
                }

                Spacer(); Spacer()
            }
        }
        .sheet(isPresented: $showManualInput) {
            ManualInputSheet()
                .environmentObject(appState)
        }
    }
}

// MARK: - 手动输入

struct ManualInputSheet: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var serverInput = ""
    @State private var isTesting = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ZStack {
                PV.bg.ignoresSafeArea()
                Form {
                    Section {
                        TextField("http://192.168.1.x:8080", text: $serverInput)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .font(PVFont.mono(14))
                    } footer: {
                        Text("输入电脑的局域网 IP 地址和端口")
                            .foregroundStyle(PV.sub)
                    }

                    if let err = errorMessage {
                        Section {
                            Text(err).foregroundStyle(PV.berry).font(.caption)
                        }
                    }

                    Section {
                        Button {
                            Task { await connect() }
                        } label: {
                            HStack {
                                Spacer()
                                if isTesting { ProgressView().tint(PV.caramel) } else {
                                    Text("连接").font(PVFont.body(15, weight: .semibold))
                                }
                                Spacer()
                            }
                        }
                        .disabled(serverInput.isEmpty || isTesting)
                    }
                }
                .scrollContentBackground(.hidden)
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

// MARK: - 主 Tab 容器（自绘浮动 tab bar）

struct MainTabView: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedTab: MainTab = .library

    var body: some View {
        ZStack(alignment: .bottom) {
            // 内容区
            Group {
                switch selectedTab {
                case .library:  GalleryView()
                case .upload:   UploadView()
                case .settings: SettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(PV.bg.ignoresSafeArea())

            // 浮动 tab bar
            CTabBar(selected: $selectedTab)
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
        }
    }
}

enum MainTab: Hashable {
    case library, upload, settings
}

/// 浮动胶囊 tab bar — 白底圆角 24 + 焦糖选中
struct CTabBar: View {
    @Binding var selected: MainTab

    private let items: [(MainTab, String, String)] = [
        (.library,  "square.grid.2x2.fill", "素材库"),
        (.upload,   "arrow.up",             "上传"),
        (.settings, "gearshape.fill",       "设置"),
    ]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(items, id: \.0) { (tab, icon, label) in
                let active = selected == tab
                Button {
                    selected = tab
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: icon)
                            .font(.system(size: 20, weight: .regular))
                        Text(label).font(PVFont.body(10.5, weight: .semibold))
                    }
                    .foregroundStyle(active ? Color.white : PV.sub)
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(active ? PV.caramel : Color.clear)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(6)
        .frame(height: 66)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color.white)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(PV.line, lineWidth: 1)
        )
        .shadow(color: PV.bean.opacity(0.08), radius: 12, x: 0, y: 8)
    }
}
