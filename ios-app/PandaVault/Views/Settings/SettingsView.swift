import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var serverInput = ""
    @State private var isTesting = false
    @State private var testResult: TestResult?
    @State private var autoSyncEnabled = UserDefaults.standard.bool(forKey: "autoSyncEnabled")
    @State private var folders: [Folder] = []

    var body: some View {
        NavigationStack {
            ZStack {
                PV.bg.ignoresSafeArea()

                List {
                    // 服务器
                    Section {
                        HStack {
                            TextField("http://192.168.1.x:8080", text: $serverInput)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .keyboardType(.URL)
                                .font(.system(.body, design: .monospaced))
                            if isTesting {
                                ProgressView().tint(PV.cyan)
                            } else {
                                Button("TEST") { Task { await testConnection() } }
                                    .font(.system(.caption, design: .monospaced).bold())
                                    .foregroundStyle(PV.cyan)
                                    .disabled(serverInput.isEmpty)
                            }
                        }
                        .listRowBackground(PV.cardBg)

                        if let result = testResult {
                            Label(result.message, systemImage: result.icon)
                                .foregroundStyle(result.isSuccess ? PV.green : PV.pink)
                                .font(.system(.caption, design: .monospaced))
                                .listRowBackground(PV.cardBg)
                        }

                        if appState.isConnected {
                            HStack {
                                Text("STATUS")
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(PV.textMuted)
                                Spacer()
                                PixelTag(text: "CONNECTED", color: PV.green)
                            }
                            .listRowBackground(PV.cardBg)
                        }
                    } header: {
                        PixelSectionHeader(title: "服务器")
                    }

                    // 同步
                    Section {
                        Toggle(isOn: $autoSyncEnabled) {
                            Text("自动备份相册")
                                .font(.system(.body, design: .monospaced))
                        }
                        .tint(PV.cyan)
                        .onChange(of: autoSyncEnabled) { _, enabled in
                            UserDefaults.standard.set(enabled, forKey: "autoSyncEnabled")
                            if enabled { BackgroundSyncManager.shared.scheduleSync() }
                        }
                        .listRowBackground(PV.cardBg)

                        // 同步目标文件夹
                        Picker(selection: Binding(
                            get: { SyncEngine.shared.syncFolderId },
                            set: { SyncEngine.shared.syncFolderId = $0 }
                        )) {
                            Text("/ 根目录").tag(UUID?.none)
                            ForEach(folders) { Text("/ \($0.name)").tag(Optional($0.id)) }
                        } label: {
                            Text("同步到")
                                .font(.system(.body, design: .monospaced))
                        }
                        .listRowBackground(PV.cardBg)

                        // 手动同步
                        Button {
                            Task { await SyncEngine.shared.performSync() }
                        } label: {
                            HStack {
                                Text("立即同步")
                                    .font(.system(.body, design: .monospaced))
                                Spacer()
                                if SyncEngine.shared.isSyncing { ProgressView().tint(PV.cyan) }
                            }
                        }
                        .disabled(SyncEngine.shared.isSyncing)
                        .listRowBackground(PV.cardBg)

                        // 统计
                        Group {
                            statRow("相册总数", value: "\(SyncEngine.shared.totalInLibrary)")
                            statRow("已同步", value: "\(SyncEngine.shared.syncedIds.count)", color: PV.green)
                            statRow("待同步", value: "\(SyncEngine.shared.unsyncedCount)",
                                    color: SyncEngine.shared.unsyncedCount > 0 ? PV.orange : PV.textMuted)
                        }

                        if let date = SyncEngine.shared.lastSyncDate {
                            HStack {
                                Text("上次同步")
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(PV.textMuted)
                                Spacer()
                                Text(date, style: .relative)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(PV.textSecondary)
                            }
                            .listRowBackground(PV.cardBg)
                        }

                        if SyncEngine.shared.isSyncing {
                            HStack {
                                Text("SYNCING")
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(PV.textMuted)
                                Spacer()
                                PixelTag(text: "\(SyncEngine.shared.syncedCount)/\(SyncEngine.shared.totalToSync)", color: PV.cyan)
                            }
                            .listRowBackground(PV.cardBg)
                        }

                        if !SyncEngine.shared.lastSyncResult.isEmpty {
                            Text(SyncEngine.shared.lastSyncResult)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(PV.textMuted)
                                .listRowBackground(PV.cardBg)
                        }
                    } header: {
                        PixelSectionHeader(title: "同步")
                    }

                    // 关于
                    Section {
                        statRow("VERSION", value: "1.0.0")
                    } header: {
                        PixelSectionHeader(title: "关于")
                    }

                    // 断开
                    if !appState.serverURL.isEmpty {
                        Section {
                            Button {
                                appState.updateServerURL("")
                                serverInput = ""
                                testResult = nil
                            } label: {
                                Text("断开服务器")
                                    .font(.system(.body, design: .monospaced))
                                    .foregroundStyle(PV.pink)
                                    .frame(maxWidth: .infinity)
                            }
                            .listRowBackground(PV.cardBg)
                        }
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("设置")
            .onAppear { serverInput = appState.serverURL }
            .task {
                if appState.isConnected {
                    folders = (try? await appState.api.getFolders()) ?? []
                }
            }
        }
    }

    private func statRow(_ label: String, value: String, color: Color = PV.textSecondary) -> some View {
        HStack {
            Text(label)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(PV.textMuted)
            Spacer()
            Text(value)
                .font(.system(.caption, design: .monospaced).bold())
                .foregroundStyle(color)
        }
        .listRowBackground(PV.cardBg)
    }

    private func testConnection() async {
        isTesting = true
        defer { isTesting = false }
        let testAPI = APIService(baseURL: serverInput)
        do {
            let ok = try await testAPI.ping()
            if ok {
                testResult = TestResult(isSuccess: true, message: "CONNECTED")
                appState.updateServerURL(serverInput)
                appState.isConnected = true
            } else {
                testResult = TestResult(isSuccess: false, message: "BAD STATUS")
            }
        } catch {
            testResult = TestResult(isSuccess: false, message: "FAILED")
        }
    }
}

private struct TestResult {
    let isSuccess: Bool
    let message: String
    var icon: String { isSuccess ? "checkmark.circle.fill" : "xmark.circle.fill" }
}
