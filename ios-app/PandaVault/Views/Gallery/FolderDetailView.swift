import SwiftUI

// MARK: - Asset Sort

enum AssetSortOption: String, CaseIterable, Identifiable {
    case timeDesc = "最新 ↓"
    case timeAsc = "最早 ↑"
    case sizeDesc = "大小 ↓"
    case sizeAsc = "大小 ↑"
    case nameAsc = "名称 ↑"
    case nameDesc = "名称 ↓"
    var id: String { rawValue }
}

extension Array where Element == Asset {
    func sorted(by option: AssetSortOption) -> [Asset] {
        func effectiveDate(_ a: Asset) -> Date { a.shootAt ?? a.createdAt }
        switch option {
        case .timeDesc: return sorted { effectiveDate($0) > effectiveDate($1) }
        case .timeAsc:  return sorted { effectiveDate($0) < effectiveDate($1) }
        case .sizeDesc: return sorted { $0.sizeBytes > $1.sizeBytes }
        case .sizeAsc:  return sorted { $0.sizeBytes < $1.sizeBytes }
        case .nameAsc:  return sorted { $0.filename.localizedStandardCompare($1.filename) == .orderedAscending }
        case .nameDesc: return sorted { $0.filename.localizedStandardCompare($1.filename) == .orderedDescending }
        }
    }
}

// MARK: - FolderDetailView

struct FolderDetailView: View {
    let folder: Folder
    let api: APIService

    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var assets: [Asset] = []
    @State private var subfolders: [Folder] = []
    @State private var isLoading = false
    @State private var searchText = ""
    @State private var displayedAssets: [Asset] = []
    @State private var selectedAsset: Asset?
    @State private var showDeleteConfirm = false
    @State private var showRenameAlert = false
    @State private var renameText = ""
    @State private var showCreateFolder = false
    @State private var deleteBlockMessage = ""
    @State private var showDeleteBlocked = false

    // 批量选择
    @State private var isSelecting = false
    @State private var selectedIds: Set<UUID> = []
    @State private var showBatchDeleteConfirm = false
    @State private var showBatchMove = false
    @State private var showMoveAlert = false
    @State private var moveMessage = ""
    @State private var shareItems: [Any] = []
    @State private var showShareSheet = false
    @State private var isSharing = false
    @State private var shareProgress = ""

    @State private var searchTask: Task<Void, Never>?

    // 排序
    @State private var subfolderSort: FolderSortOption = .nameAsc
    @State private var assetSort: AssetSortOption = .timeDesc

    // 导出工程包
    @State private var showExport = false

    // 面包屑导航
    @State private var breadcrumbs: [(name: String, id: UUID)] = []
    @State private var currentFolder: Folder?

    private var activeFolder: Folder { currentFolder ?? folder }

    /// 面包屑路径（用于 NewSubfolderSheet 预览）
    /// 根：`/2026春节/`  嵌套：`/2026春节/子1/`
    private var breadcrumbPath: String {
        var parts = [folder.name]
        parts.append(contentsOf: breadcrumbs.map(\.name))
        return "/" + parts.joined(separator: "/") + "/"
    }

    var body: some View {
        FolderDetailContent(
            breadcrumbs: breadcrumbs,
            rootFolderName: folder.name,
            activeFolderName: activeFolder.name,
            subfolders: subfolders.sorted(by: subfolderSort),
            filteredAssets: displayedAssets.sorted(by: assetSort),
            isLoading: isLoading,
            searchText: $searchText,
            api: api,
            selectedAsset: $selectedAsset,
            isSelecting: $isSelecting,
            selectedIds: $selectedIds,
            subfolderSort: $subfolderSort,
            assetSort: $assetSort,
            onSubfolderTap: { subfolder in
                breadcrumbs.append((subfolder.name, subfolder.id))
                currentFolder = subfolder
                Task { await navigateToFolder(subfolder) }
            },
            onBreadcrumbTap: { index in
                if index < 0 {
                    breadcrumbs.removeAll()
                    currentFolder = nil
                    Task { await navigateToFolder(folder) }
                } else {
                    breadcrumbs = Array(breadcrumbs.prefix(index + 1))
                    if let target = breadcrumbs.last {
                        Task { await navigateById(target.id) }
                    }
                }
            }
        )
        .background(PV.bg.ignoresSafeArea())
        .toolbarBackground(PV.bg, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .navigationTitle(activeFolder.name)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .onChange(of: searchText) { _, newValue in
            searchTask?.cancel()
            if newValue.isEmpty {
                displayedAssets = assets
            } else {
                searchTask = Task {
                    try? await Task.sleep(nanoseconds: 300_000_000) // 300ms 防抖
                    guard !Task.isCancelled else { return }
                    await searchInFolder(query: newValue)
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { dismiss() } label: {
                    HStack(spacing: 2) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 16, weight: .semibold))
                        Text("返回")
                            .font(PVFont.body(15))
                    }
                    .foregroundStyle(PV.caramel)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 12) {
                    if isSelecting {
                        Button {
                            let allIds = Set(displayedAssets.map(\.id))
                            if selectedIds == allIds {
                                selectedIds.removeAll()
                            } else {
                                selectedIds = allIds
                            }
                        } label: {
                            Text(selectedIds.count == displayedAssets.count && !displayedAssets.isEmpty ? "取消全选" : "全选")
                                .foregroundStyle(PV.cyan)
                        }
                        Button {
                            isSelecting = false
                            selectedIds.removeAll()
                        } label: {
                            Text("完成").foregroundStyle(PV.cyan)
                        }
                    } else {
                        Button {
                            isSelecting = true
                        } label: {
                            Text("选择").foregroundStyle(PV.cyan)
                        }
                        FolderDetailMenu(
                            folderName: activeFolder.name,
                            renameText: $renameText,
                            showRenameAlert: $showRenameAlert,
                            showDeleteConfirm: $showDeleteConfirm,
                            showCreateFolder: $showCreateFolder
                        )
                    }
                }
            }
        }
        .fullScreenCover(item: $selectedAsset) { asset in
            AssetDetailView(
                assets: displayedAssets,
                initialAsset: asset,
                api: api,
                onDelete: {
                    Task { await loadFolderAssets() }
                },
                onAssetUpdated: { updated in
                    if let idx = assets.firstIndex(where: { $0.id == updated.id }) {
                        assets[idx] = updated
                    }
                    if let idx = displayedAssets.firstIndex(where: { $0.id == updated.id }) {
                        displayedAssets[idx] = updated
                    }
                }
            )
        }
        .safeAreaInset(edge: .bottom) {
            GalleryBottomInset(
                appState: appState,
                isSelecting: isSelecting,
                selectedIds: selectedIds,
                showDeleteConfirm: $showBatchDeleteConfirm,
                showBatchMove: $showBatchMove,
                onSave: { batchSaveToPhotos() },
                onShare: { Task { await batchShare() } }
            )
        }
        .overlay(alignment: .bottom) {
            if isSelecting && !selectedIds.isEmpty {
                FloatingBatchBar(
                    count: selectedIds.count,
                    showDeleteConfirm: $showBatchDeleteConfirm,
                    showBatchMove: $showBatchMove,
                    onSave: { batchSaveToPhotos() },
                    onShare: { Task { await batchShare() } },
                    onExport: { showExport = true }
                )
            }
        }
        .sheet(isPresented: $showExport) {
            ExportSheet(api: api, assetIds: Array(selectedIds))
        }
        .onChange(of: isSelecting) { _, newValue in
            appState.tabBarHidden = newValue && !selectedIds.isEmpty
        }
        .onChange(of: selectedIds) { _, newValue in
            appState.tabBarHidden = isSelecting && !newValue.isEmpty
        }
        .onDisappear { appState.tabBarHidden = false }
        .confirmationDialog(
            "确定删除 \(selectedIds.count) 个素材？",
            isPresented: $showBatchDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) { Task { await batchDelete() } }
        }
        .sheet(isPresented: $showBatchMove) {
            MoveToFolderView(api: api, assetIds: Array(selectedIds)) { msg in
                moveMessage = msg
                showMoveAlert = true
                selectedIds.removeAll()
                isSelecting = false
                Task { await loadFolderAssets() }
            }
        }
        .alert("", isPresented: $showMoveAlert) {
            Button("好") {}
        } message: {
            Text(moveMessage)
        }
        .sheet(isPresented: $showShareSheet, onDismiss: cleanupShareFiles) {
            ActivityView(items: shareItems)
        }
        .overlay {
            if isSharing {
                ZStack {
                    Color.black.opacity(0.4).ignoresSafeArea()
                    VStack(spacing: 12) {
                        ProgressView().tint(.white).scaleEffect(1.2)
                        Text(shareProgress)
                            .font(.system(.caption, design: .monospaced).bold())
                            .foregroundStyle(.white)
                    }
                    .padding(24)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .environment(\.colorScheme, .dark)
                }
            }
        }
        .confirmationDialog(
            "删除文件夹「\(activeFolder.name)」？",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) { Task { await checkAndDeleteFolder() } }
        }
        .alert("无法删除", isPresented: $showDeleteBlocked) {
            Button("好") {}
        } message: {
            Text(deleteBlockMessage)
        }
        .alert("重命名文件夹", isPresented: $showRenameAlert) {
            TextField("文件夹名称", text: $renameText)
            Button("确定") { Task { await renameFolder() } }
            Button("取消", role: .cancel) {}
        }
        .sheet(isPresented: $showCreateFolder) {
            NewSubfolderSheet(
                parentName: activeFolder.name,
                parentPath: breadcrumbPath,
                api: api,
                parentId: activeFolder.id
            ) {
                await loadSubfolders()
            }
            .presentationDetents([.medium])
        }
        .task {
            await loadSubfolders()
            await loadFolderAssets()
        }
        .refreshable {
            await loadSubfolders()
            await loadFolderAssets()
        }
    }

    // MARK: - Actions

    private func loadSubfolders() async {
        do {
            subfolders = try await api.getFolders(parentId: activeFolder.id)
        } catch {
            print("[PandaVault] Subfolders error: \(error)")
        }
    }

    private func loadFolderAssets() async {
        isLoading = true
        defer { isLoading = false }
        do {
            assets = try await api.getFolderAssets(folderId: activeFolder.id)
            displayedAssets = assets
        } catch {
            print("[PandaVault] Error: \(error)")
        }
    }

    private func navigateToFolder(_ target: Folder) async {
        searchText = ""
        await loadSubfolders()
        await loadFolderAssets()
    }

    private func navigateById(_ id: UUID) async {
        // 简单起见直接用 id 加载
        searchText = ""
        do {
            subfolders = try await api.getFolders(parentId: id)
            assets = try await api.getFolderAssets(folderId: id)
            displayedAssets = assets
        } catch {
            print("[PandaVault] Navigate error: \(error)")
        }
    }

    private func searchInFolder(query: String) async {
        isLoading = true
        defer { isLoading = false }

        // 后端已支持 folder_id 参数：在当前文件夹 + 所有子文件夹子树内做向量检索
        do {
            let semanticResults = try await api.semanticSearch(text: query, folderId: activeFolder.id)
            if !semanticResults.isEmpty {
                displayedAssets = semanticResults
                return
            }
        } catch {
            PVLog.error("folder semantic search 失败 folder=\(activeFolder.id) err=\(error.localizedDescription)")
        }

        // 语义搜索没结果 / AI 服务不可用 → 降级到后端文件名搜索
        do {
            let fileResults = try await api.getFolderAssets(folderId: activeFolder.id, query: query)
            displayedAssets = fileResults
        } catch {
            PVLog.error("folder filename search 失败 folder=\(activeFolder.id) err=\(error.localizedDescription)")
            displayedAssets = []
        }
    }

    private func checkAndDeleteFolder() async {
        let hasAssets = !assets.isEmpty
        let hasSubs = !subfolders.isEmpty
        if hasAssets || hasSubs {
            var parts: [String] = []
            if hasSubs { parts.append("\(subfolders.count) 个子文件夹") }
            if hasAssets { parts.append("\(assets.count) 个文件") }
            deleteBlockMessage = "「\(activeFolder.name)」内还有 \(parts.joined(separator: " 和 "))，请先清空后再删除"
            showDeleteBlocked = true
            return
        }
        do {
            try await api.deleteFolder(id: activeFolder.id)
            dismiss()
        } catch {
            print("[PandaVault] Error: \(error)")
        }
    }

    private func renameFolder() async {
        guard !renameText.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        do {
            try await api.renameFolder(id: activeFolder.id, name: renameText)
        } catch {
            print("[PandaVault] Error: \(error)")
        }
    }

    // MARK: - Batch Actions

    private func batchSaveToPhotos() {
        let selected = displayedAssets.filter { selectedIds.contains($0.id) }
        appState.downloadManager.updateAPI(api)
        appState.downloadManager.addAssets(selected)
        selectedIds.removeAll()
        isSelecting = false
    }

    private func batchDelete() async {
        for id in selectedIds {
            try? await api.deleteAsset(id: id)
        }
        selectedIds.removeAll()
        isSelecting = false
        await loadFolderAssets()
    }

    private func cleanupShareFiles() {
        for item in shareItems {
            if let url = item as? URL {
                try? FileManager.default.removeItem(at: url)
            }
        }
        shareItems = []
    }

    private func batchShare() async {
        let selected = displayedAssets.filter { selectedIds.contains($0.id) }
        isSharing = true
        defer { isSharing = false }

        var localFiles: [Any] = []
        for (i, asset) in selected.enumerated() {
            shareProgress = "下载中 \(i + 1)/\(selected.count)..."
            do {
                let tempURL = try await api.downloadAsset(id: asset.id) { _ in }
                let ext = (asset.filename as NSString).pathExtension
                let dest = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension(ext.isEmpty ? "bin" : ext)
                try FileManager.default.moveItem(at: tempURL, to: dest)
                localFiles.append(dest)
            } catch {
                print("[PandaVault] Download for share failed: \(error)")
            }
        }
        if !localFiles.isEmpty {
            shareItems = localFiles
            showShareSheet = true
        }
        selectedIds.removeAll()
        isSelecting = false
    }
}

// MARK: - Content

private struct FolderDetailContent: View {
    let breadcrumbs: [(name: String, id: UUID)]
    let rootFolderName: String
    let activeFolderName: String
    let subfolders: [Folder]
    let filteredAssets: [Asset]
    let isLoading: Bool
    @Binding var searchText: String
    let api: APIService
    @Binding var selectedAsset: Asset?
    @Binding var isSelecting: Bool
    @Binding var selectedIds: Set<UUID>
    @Binding var subfolderSort: FolderSortOption
    @Binding var assetSort: AssetSortOption
    var onSubfolderTap: ((Folder) -> Void)?
    var onBreadcrumbTap: ((Int) -> Void)?

    var body: some View {
        ScrollView {
            // Cream 搜索胶囊（替代系统 .searchable —— 和 cream.jsx 第 3 屏一致）
            CSearchPill(text: $searchText, prompt: "在「\(activeFolderName)」中搜索…")
                .padding(.horizontal, 20)
                .padding(.top, 4)

            // 面包屑导航（对应 cream.jsx 第 3 屏）
            if !breadcrumbs.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        Button(rootFolderName) {
                            onBreadcrumbTap?(-1)
                        }
                        .font(PVFont.mono(11.5))
                        .foregroundStyle(PV.sub)

                        ForEach(Array(breadcrumbs.enumerated()), id: \.offset) { idx, crumb in
                            Text("/")
                                .font(PVFont.mono(11.5))
                                .foregroundStyle(PV.muted)
                            let last = idx == breadcrumbs.count - 1
                            Button(crumb.name) {
                                onBreadcrumbTap?(idx)
                            }
                            .font(PVFont.mono(11.5, weight: last ? .medium : .regular))
                            .foregroundStyle(last ? PV.caramel : PV.sub)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                }
                .background(Color.white.opacity(0.5))
            }

            // 排序条（非搜索态才显示）
            if searchText.isEmpty {
                sortBar
            }

            if !subfolders.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 108, maximum: 150), spacing: 10)], spacing: 10) {
                    ForEach(subfolders) { subfolder in
                        Button {
                            onSubfolderTap?(subfolder)
                        } label: {
                            subfolderCard(subfolder)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 4)
                .padding(.bottom, 8)
            }

            // 资产网格
            if filteredAssets.isEmpty && subfolders.isEmpty && !isLoading {
                FolderDetailEmptyState(hasSearch: !searchText.isEmpty)
            } else if !filteredAssets.isEmpty {
                GalleryAssetsGrid(
                    assets: filteredAssets,
                    api: api,
                    isSelecting: $isSelecting,
                    selectedIds: $selectedIds,
                    selectedAsset: $selectedAsset
                )
            }
            if isLoading {
                ProgressView().tint(PV.caramel).padding()
            }
        }
    }

    /// cream.jsx 第 3 屏的子文件夹卡片：半透明白底 + 焦糖 folder icon + mono 名称/计数
    private func subfolderCard(_ subfolder: Folder) -> some View {
        VStack(spacing: 3) {
            Image(systemName: "folder.fill")
                .font(.system(size: 26))
                .foregroundStyle(PV.caramel)
                .padding(.top, 4)
            Text(subfolder.name)
                .font(PVFont.mono(12))
                .foregroundStyle(PV.ink)
                .lineLimit(1)
                .padding(.top, 2)
            if subfolder.assetCount == nil || subfolder.totalBytes == nil {
                Text("计算中…")
                    .font(PVFont.mono(10))
                    .foregroundStyle(PV.muted)
            } else {
                Text("\(subfolder.assetCount ?? 0) items")
                    .font(PVFont.mono(10))
                    .foregroundStyle(PV.sub)
                if let total = subfolder.totalBytes, total > 0 {
                    Text(total.humanReadableBytes)
                        .font(PVFont.mono(10))
                        .foregroundStyle(PV.muted)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .padding(.horizontal, 10)
        .background(Color.white.opacity(0.7))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(PV.line, lineWidth: 1)
        )
    }

    // 排序条：子文件夹 + 资产各一个 Menu（cream 风格 — 焦糖淡底 chip）
    private var sortBar: some View {
        HStack(spacing: 8) {
            if !subfolders.isEmpty {
                Menu {
                    ForEach(FolderSortOption.allCases) { opt in
                        Button {
                            subfolderSort = opt
                        } label: {
                            if opt == subfolderSort {
                                Label(opt.rawValue, systemImage: "checkmark")
                            } else {
                                Text(opt.rawValue)
                            }
                        }
                    }
                } label: {
                    sortChip(icon: "folder", text: "文件夹 \(subfolderSort.rawValue)")
                }
            }
            if !filteredAssets.isEmpty {
                Menu {
                    ForEach(AssetSortOption.allCases) { opt in
                        Button {
                            assetSort = opt
                        } label: {
                            if opt == assetSort {
                                Label(opt.rawValue, systemImage: "checkmark")
                            } else {
                                Text(opt.rawValue)
                            }
                        }
                    }
                } label: {
                    sortChip(icon: "photo.on.rectangle", text: "照片 \(assetSort.rawValue)")
                }
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }

    private func sortChip(icon: String, text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 10, weight: .semibold))
            Text(text).font(PVFont.body(11, weight: .semibold))
        }
        .foregroundStyle(PV.caramel)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(PV.caramel.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - Empty State

private struct FolderDetailEmptyState: View {
    let hasSearch: Bool

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: hasSearch ? "magnifyingglass" : "tray")
                .font(.system(size: 26))
                .foregroundStyle(PV.muted)
            Text(hasSearch ? "没有找到匹配的素材" : "这个文件夹还是空的")
                .font(PVFont.body(13))
                .foregroundStyle(PV.sub)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }
}

// MARK: - New Subfolder Sheet (cream · 对应菜单"新建子文件夹"→ sheet)

struct NewSubfolderSheet: View {
    let parentName: String
    let parentPath: String       // 如 "/2026春节/"
    let api: APIService
    let parentId: UUID
    var onCreated: (() async -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var folderName = ""
    @FocusState private var focused: Bool
    @State private var isCreating = false
    @State private var statusMsg = ""
    @State private var isError = false

    private var trimmedName: String {
        folderName.trimmingCharacters(in: .whitespaces)
    }

    private var previewPath: String {
        trimmedName.isEmpty ? parentPath : "\(parentPath)\(trimmedName)/"
    }

    var body: some View {
        ZStack {
            PV.bg.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("新建子文件夹")
                        .font(PVFont.display(22, weight: .medium))
                        .foregroundStyle(PV.ink)
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(PV.sub)
                            .frame(width: 30, height: 30)
                            .background(PV.ink.opacity(0.06), in: Circle())
                    }
                }
                .padding(.top, 6)

                VStack(alignment: .leading, spacing: 4) {
                    Text("创建位置")
                        .font(PVFont.sectionHeader)
                        .tracking(1.5)
                        .foregroundStyle(PV.muted)
                    Text(previewPath)
                        .font(PVFont.mono(12, weight: .medium))
                        .foregroundStyle(PV.caramel)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(PV.caramel.opacity(0.09))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("文件夹名称")
                        .font(PVFont.sectionHeader)
                        .tracking(1.5)
                        .foregroundStyle(PV.muted)
                    TextField("", text: $folderName, prompt:
                        Text("比如 花絮").font(PVFont.body(14.5)).foregroundStyle(PV.muted))
                        .font(PVFont.body(15))
                        .tint(PV.caramel)
                        .focused($focused)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(PV.line, lineWidth: 1)
                        )
                }

                if !statusMsg.isEmpty {
                    Text(statusMsg)
                        .font(PVFont.body(12))
                        .foregroundStyle(isError ? PV.berry : PV.caramel)
                        .padding(.horizontal, 4)
                }

                Spacer()

                Button {
                    Task { await doCreate() }
                } label: {
                    HStack {
                        if isCreating { ProgressView().tint(.white) }
                        else { Text("创建") }
                    }
                }
                .buttonStyle(CButtonStyle(tone: PV.caramel, filled: true, height: 48))
                .disabled(trimmedName.isEmpty || isCreating)
                .opacity(trimmedName.isEmpty ? 0.5 : 1)
            }
            .padding(20)
        }
        .onAppear { focused = true }
    }

    private func doCreate() async {
        guard !trimmedName.isEmpty else { return }
        isCreating = true
        statusMsg = ""
        defer { isCreating = false }
        do {
            _ = try await api.createFolder(name: trimmedName, parentId: parentId)
            await onCreated?()
            dismiss()
        } catch let error as APIError {
            isError = true
            if case .httpError(let code) = error, code == 409 {
                statusMsg = "同名文件夹已存在"
            } else {
                statusMsg = "创建失败: \(error.localizedDescription)"
            }
        } catch {
            isError = true
            statusMsg = "创建失败: \(error.localizedDescription)"
        }
    }
}

// MARK: - Toolbar Menu

private struct FolderDetailMenu: View {
    let folderName: String
    @Binding var renameText: String
    @Binding var showRenameAlert: Bool
    @Binding var showDeleteConfirm: Bool
    @Binding var showCreateFolder: Bool

    var body: some View {
        Menu {
            Button {
                showCreateFolder = true
            } label: {
                Label("新建子文件夹", systemImage: "folder.badge.plus")
            }
            Button {
                renameText = folderName
                showRenameAlert = true
            } label: {
                Label("重命名", systemImage: "pencil")
            }
            Button(role: .destructive) {
                showDeleteConfirm = true
            } label: {
                Label("删除文件夹", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis").foregroundStyle(PV.cyan)
        }
    }
}
