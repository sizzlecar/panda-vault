import SwiftUI

// 奶油软萌风 · 对应 design/cream.jsx CreamSettings
struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var syncEngine = SyncEngine.shared

    @State private var serverInput = ""
    @State private var isTesting = false
    @State private var folders: [Folder] = []
    @State private var autoBackup = UserDefaults.standard.bool(forKey: "autoBackup")
    @State private var trashCount = 0
    @State private var showSyncFolderPicker = false

    private static let lastSyncFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f
    }()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    CLargeTitle("设置")
                        .padding(.top, 2)

                    serverSection
                    syncSection
                    statsSection
                    storageSection
                    aboutSection
                    disconnectSection

                    Spacer(minLength: 100) // 给浮动 tab bar 让位
                }
                .padding(.bottom, 16)
            }
            .background(PV.bg.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .task {
                serverInput = appState.serverURL
                await loadFolders()
                trashCount = (try? await appState.api.getTrash(limit: 1000))?.count ?? 0
            }
        }
    }

    // MARK: - Sections

    private var serverSection: some View {
        creamSection(header: "SERVER") {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    TextField("http://192.168.1.x:8080", text: $serverInput)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .font(PVFont.mono(13.5))
                        .foregroundStyle(PV.ink)
                        .tint(PV.caramel)
                    if appState.isConnected {
                        statusChip("已连接", color: PV.mint)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 13)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(PV.divider).frame(height: 0.5).padding(.horizontal, 16)
                }

                Button {
                    Task { await testConnection() }
                } label: {
                    HStack {
                        Spacer()
                        if isTesting {
                            ProgressView().tint(PV.caramel)
                        } else {
                            Text("测试连接")
                                .font(PVFont.body(14, weight: .semibold))
                                .foregroundStyle(PV.caramel)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 13)
                }
                .disabled(serverInput.isEmpty || isTesting)
            }
        }
    }

    private var syncSection: some View {
        creamSection(header: "SYNC") {
            VStack(spacing: 0) {
                toggleRow(
                    title: "自动备份",
                    subtitle: "后台增量同步相册",
                    isOn: $autoBackup
                ) { newValue in
                    UserDefaults.standard.set(newValue, forKey: "autoBackup")
                    if newValue { BackgroundSyncManager.shared.scheduleSync() }
                }
                divider

                // 同步文件夹选择
                Button {
                    showSyncFolderPicker = true
                } label: {
                    HStack {
                        Text("同步到")
                            .font(PVFont.body(14.5))
                            .foregroundStyle(PV.ink)
                        Spacer()
                        Text(syncFolderLabel)
                            .font(PVFont.body(13))
                            .foregroundStyle(PV.sub)
                            .lineLimit(1)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(PV.muted)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 13)
                }
                .buttonStyle(.plain)

                if syncEngine.isSyncing {
                    divider
                    syncProgressRow
                }

                divider

                Button {
                    Task { await syncEngine.performSync() }
                } label: {
                    HStack {
                        Spacer()
                        if syncEngine.isSyncing {
                            ProgressView().tint(PV.caramel)
                            Text("同步中…")
                                .font(PVFont.body(14))
                                .foregroundStyle(PV.sub)
                                .padding(.leading, 6)
                        } else {
                            Text("立即同步")
                                .font(PVFont.body(14, weight: .semibold))
                                .foregroundStyle(PV.caramel)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 13)
                }
                .disabled(syncEngine.isSyncing || !appState.isConnected)
            }
        }
        .confirmationDialog(
            "同步到哪个文件夹？",
            isPresented: $showSyncFolderPicker,
            titleVisibility: .visible
        ) {
            Button("默认（不指定文件夹）") { syncEngine.syncFolderId = nil }
            ForEach(folders) { f in
                Button(f.name) { syncEngine.syncFolderId = f.id }
            }
            Button("取消", role: .cancel) {}
        }
    }

    private var statsSection: some View {
        creamSection {
            VStack(spacing: 0) {
                statRow(label: "相册总数", value: "\(syncEngine.totalInLibrary)", tone: PV.caramel)
                divider
                statRow(label: "已同步", value: "\(syncEngine.syncedIds.count)", tone: PV.mint)
                divider
                statRow(label: "待同步", value: "\(syncEngine.unsyncedCount)", tone: PV.peach)
                divider
                statRow(label: "上次同步", value: lastSyncText, tone: PV.bean)
            }
        }
    }

    private var storageSection: some View {
        creamSection(header: "存储管理") {
            VStack(spacing: 0) {
                navRow(
                    icon: "trash",
                    iconTint: PV.berry,
                    title: "最近删除",
                    value: trashCount > 0 ? "\(trashCount)" : nil
                ) {
                    TrashView(api: appState.api)
                }
                divider
                navRow(
                    icon: "internaldrive",
                    iconTint: PV.caramel,
                    title: "磁盘信息",
                    value: nil
                ) {
                    DiskInfoView(api: appState.api)
                }
            }
        }
    }

    private var aboutSection: some View {
        creamSection(header: "ABOUT") {
            HStack {
                Text("版本")
                    .font(PVFont.body(14.5))
                    .foregroundStyle(PV.ink)
                Spacer()
                Text("1.0.0")
                    .font(PVFont.mono(13))
                    .foregroundStyle(PV.sub)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
        }
    }

    private var disconnectSection: some View {
        VStack(spacing: 0) {
            Button {
                disconnect()
            } label: {
                HStack {
                    Spacer()
                    Text("断开连接")
                        .font(PVFont.body(14.5, weight: .semibold))
                        .foregroundStyle(PV.berry)
                    Spacer()
                }
                .padding(.vertical, 15)
            }
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(PV.line, lineWidth: 1)
            )
        }
        .padding(.horizontal, 20)
    }

    // MARK: - Row builders

    @ViewBuilder
    private func creamSection<Content: View>(
        header: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let header {
                Text(header.uppercased())
                    .font(PVFont.sectionHeader)
                    .tracking(1.5)
                    .foregroundStyle(PV.muted)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 8)
            }
            content()
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(PV.line, lineWidth: 1)
                )
                .padding(.horizontal, 20)
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(PV.divider)
            .frame(height: 0.5)
            .padding(.leading, 16)
    }

    private func toggleRow(
        title: String,
        subtitle: String? = nil,
        isOn: Binding<Bool>,
        onChange: @escaping (Bool) -> Void
    ) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(PVFont.body(14.5))
                    .foregroundStyle(PV.ink)
                if let subtitle {
                    Text(subtitle)
                        .font(PVFont.body(11.5))
                        .foregroundStyle(PV.sub)
                }
            }
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
                .tint(PV.caramel)
                .onChange(of: isOn.wrappedValue) { _, newValue in
                    onChange(newValue)
                }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    private func statRow(label: String, value: String, tone: Color) -> some View {
        HStack {
            Text(label)
                .font(PVFont.body(14))
                .foregroundStyle(PV.sub)
            Spacer()
            Text(value)
                .font(PVFont.mono(13, weight: .medium))
                .foregroundStyle(tone)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(tone.opacity(0.13), in: Capsule())
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    private func navRow<Destination: View>(
        icon: String,
        iconTint: Color,
        title: String,
        value: String?,
        @ViewBuilder destination: () -> Destination
    ) -> some View {
        NavigationLink {
            destination()
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous).fill(iconTint.opacity(0.13))
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(iconTint)
                }
                .frame(width: 30, height: 30)

                Text(title)
                    .font(PVFont.body(14.5))
                    .foregroundStyle(PV.ink)
                Spacer()
                if let value {
                    Text(value)
                        .font(PVFont.mono(13))
                        .foregroundStyle(PV.sub)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(PV.muted)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
        }
        .buttonStyle(.plain)
    }

    private func statusChip(_ text: String, color: Color) -> some View {
        Text(text)
            .font(PVFont.body(11, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.15), in: Capsule())
    }

    // MARK: - Sync progress

    @ViewBuilder
    private var syncProgressRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(syncEngine.syncedCount)/\(syncEngine.totalToSync)")
                    .font(PVFont.mono(13, weight: .medium))
                    .foregroundStyle(PV.caramel)
                Spacer()
                if syncEngine.failedCount > 0 {
                    Text("\(syncEngine.failedCount) 失败")
                        .font(PVFont.mono(11))
                        .foregroundStyle(PV.berry)
                }
            }
            if !syncEngine.currentFileName.isEmpty {
                Text(syncEngine.currentFileName)
                    .font(PVFont.mono(11))
                    .foregroundStyle(PV.sub)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                CProgressBar(progress: syncEngine.currentProgress, color: PV.caramel, height: 4)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    // MARK: - Helpers

    private var syncFolderLabel: String {
        guard let fid = syncEngine.syncFolderId else { return "默认" }
        return folders.first(where: { $0.id == fid })?.name ?? "未知"
    }

    private var lastSyncText: String {
        guard let date = syncEngine.lastSyncDate else { return "从未" }
        return Self.lastSyncFormatter.string(from: date)
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
