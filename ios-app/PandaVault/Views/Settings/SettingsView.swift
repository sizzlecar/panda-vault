import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var syncEngine = SyncEngine.shared

    @State private var serverInput = ""
    @State private var isTesting = false
    @State private var folders: [Folder] = []
    @State private var autoBackup = UserDefaults.standard.bool(forKey: "autoBackup")
    @State private var trashCount = 0

    private static let lastSyncFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f
    }()

    var body: some View {
        NavigationStack {
            Form {
                // MARK: - Server
                Section {
                    HStack {
                        TextField("http://192.168.1.x:8080", text: $serverInput)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)

                        if appState.isConnected {
                            PixelTag(text: "CONNECTED", color: PV.green)
                        }
                    }

                    Button {
                        Task { await testConnection() }
                    } label: {
                        HStack {
                            Spacer()
                            if isTesting {
                                ProgressView().tint(PV.cyan)
                            } else {
                                Text("TEST")
                                    .font(.system(.caption, design: .monospaced).bold())
                                    .tracking(2)
                            }
                            Spacer()
                        }
                    }
                    .disabled(serverInput.isEmpty || isTesting)
                } header: {
                    PixelSectionHeader(title: "SERVER")
                }

                // MARK: - Sync
                Section {
                    Toggle("自动备份", isOn: $autoBackup)
                        .tint(PV.cyan)
                        .onChange(of: autoBackup) { _, newValue in
                            UserDefaults.standard.set(newValue, forKey: "autoBackup")
                            if newValue {
                                BackgroundSyncManager.shared.scheduleSync()
                            }
                        }

                    Picker("同步文件夹", selection: $syncEngine.syncFolderId) {
                        Text("默认").tag(UUID?.none)
                        ForEach(folders) { folder in
                            Text(folder.name).tag(UUID?.some(folder.id))
                        }
                    }

                    if syncEngine.isSyncing {
                        // 同步进度详情
                        VStack(spacing: 8) {
                            HStack {
                                Text("\(syncEngine.syncedCount)/\(syncEngine.totalToSync)")
                                    .font(.system(.caption, design: .monospaced).bold())
                                    .foregroundStyle(PV.cyan)
                                Spacer()
                                if syncEngine.failedCount > 0 {
                                    Text("\(syncEngine.failedCount) 失败")
                                        .font(.system(.caption2, design: .monospaced))
                                        .foregroundStyle(PV.orange)
                                }
                            }

                            if !syncEngine.currentFileName.isEmpty {
                                Text(syncEngine.currentFileName)
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: .leading)

                                ProgressView(value: syncEngine.currentProgress)
                                    .tint(PV.cyan)
                            }
                        }
                    }

                    Button {
                        Task { await syncEngine.performSync() }
                    } label: {
                        HStack {
                            Spacer()
                            if syncEngine.isSyncing {
                                ProgressView().tint(PV.cyan)
                                Text("同步中...")
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .padding(.leading, 6)
                            } else {
                                Text("立即同步")
                                    .font(.system(.caption, design: .monospaced).bold())
                                    .tracking(1)
                            }
                            Spacer()
                        }
                    }
                    .disabled(syncEngine.isSyncing || !appState.isConnected)
                } header: {
                    PixelSectionHeader(title: "SYNC")
                }

                // MARK: - Stats
                Section {
                    statRow(label: "相册总数", value: "\(syncEngine.totalInLibrary)", color: PV.cyan)
                    statRow(label: "已同步", value: "\(syncEngine.syncedIds.count)", color: PV.green)
                    statRow(label: "待同步", value: "\(syncEngine.unsyncedCount)", color: PV.orange)
                    statRow(label: "上次同步", value: lastSyncText, color: PV.pink)
                }

                // MARK: - Storage Management
                Section {
                    NavigationLink {
                        TrashView(api: appState.api)
                    } label: {
                        HStack {
                            Label("最近删除", systemImage: "trash")
                            Spacer()
                            Text("\(trashCount)")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                    NavigationLink {
                        DiskInfoView(api: appState.api)
                    } label: {
                        Label("磁盘信息", systemImage: "internaldrive")
                    }
                } header: {
                    PixelSectionHeader(title: "存储管理")
                }

                // MARK: - About
                Section {
                    HStack {
                        Text("VERSION")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Spacer()
                        PixelTag(text: "1.0.0", color: PV.cyan)
                    }
                } header: {
                    PixelSectionHeader(title: "ABOUT")
                }

                // MARK: - Disconnect
                Section {
                    Button(role: .destructive) {
                        disconnect()
                    } label: {
                        HStack {
                            Spacer()
                            Text("断开连接")
                                .font(.system(.caption, design: .monospaced).bold())
                                .tracking(1)
                            Spacer()
                        }
                    }
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                serverInput = appState.serverURL
                await loadFolders()
                trashCount = (try? await appState.api.getTrash(limit: 1000))?.count ?? 0
            }
        }
    }

    // MARK: - Helpers

    private var lastSyncText: String {
        guard let date = syncEngine.lastSyncDate else { return "从未" }
        return Self.lastSyncFormatter.string(from: date)
    }

    private func statRow(label: String, value: String, color: Color) -> some View {
        HStack {
            Text(label)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
            Spacer()
            PixelTag(text: value, color: color)
        }
    }

    private func testConnection() async {
        isTesting = true
        defer { isTesting = false }

        appState.updateServerURL(serverInput)
        await appState.checkConnection()
        if appState.isConnected {
            await loadFolders()
        }
    }

    private func loadFolders() async {
        guard appState.isConnected else { return }
        do {
            folders = try await appState.api.getFolders()
        } catch {
            folders = []
        }
    }

    private func disconnect() {
        appState.isConnected = false
        appState.updateServerURL("")
        serverInput = ""
    }
}
