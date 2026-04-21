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
    @State private var newFolderName = ""
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

    // 面包屑导航
    @State private var breadcrumbs: [(name: String, id: UUID)] = []
    @State private var currentFolder: Folder?

    private var activeFolder: Folder { currentFolder ?? folder }

    var body: some View {
        FolderDetailContent(
            breadcrumbs: breadcrumbs,
            rootFolderName: folder.name,
            subfolders: subfolders.sorted(by: subfolderSort),
            filteredAssets: displayedAssets.sorted(by: assetSort),
            isLoading: isLoading,
            searchText: searchText,
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
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "在「\(activeFolder.name)」中搜索…")
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
                            showCreateFolder: $showCreateFolder,
                            newFolderName: $newFolderName
                        )
                    }
                }
            }
        }
        .fullScreenCover(item: $selectedAsset) { asset in
            AssetDetailView(assets: displayedAssets, initialAsset: asset, api: api) {
                Task { await loadFolderAssets() }
            }
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
        .alert("新建文件夹", isPresented: $showCreateFolder) {
            TextField("文件夹名称", text: $newFolderName)
            Button("创建") { Task { await createSubfolder() } }
            Button("取消", role: .cancel) {}
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

    private func createSubfolder() async {
        let name = newFolderName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        do {
            let _ = try await api.createFolder(name: name, parentId: activeFolder.id)
            await loadSubfolders()
        } catch {
            print("[PandaVault] Create subfolder error: \(error)")
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
    let subfolders: [Folder]
    let filteredAssets: [Asset]
    let isLoading: Bool
    let searchText: String
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
            // 面包屑导航
            if !breadcrumbs.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        Button(rootFolderName) {
                            onBreadcrumbTap?(-1)
                        }
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)

                        ForEach(Array(breadcrumbs.enumerated()), id: \.offset) { idx, crumb in
                            Text("/").font(.caption2).foregroundStyle(.tertiary)
                            Button(crumb.name) {
                                onBreadcrumbTap?(idx)
                            }
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(idx == breadcrumbs.count - 1 ? PV.cyan : .secondary)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 6)
                }
                .background(Color(.secondarySystemGroupedBackground))
            }

            // 排序条（非搜索态才显示）
            if searchText.isEmpty {
                sortBar
            }

            if !subfolders.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 12)], spacing: 12) {
                    ForEach(subfolders) { subfolder in
                        Button {
                            onSubfolderTap?(subfolder)
                        } label: {
                            VStack(spacing: 6) {
                                Image(systemName: "folder.fill")
                                    .font(.title)
                                    .foregroundStyle(PV.cyan)
                                Text(subfolder.name)
                                    .font(.system(.caption, design: .monospaced))
                                    .lineLimit(1)
                                    .foregroundStyle(.primary)
                                if subfolder.assetCount == nil || subfolder.totalBytes == nil {
                                    Text("计算中…")
                                        .font(.system(.caption2, design: .monospaced))
                                        .foregroundStyle(.tertiary)
                                } else {
                                    Text("\(subfolder.assetCount ?? 0) items")
                                        .font(.system(.caption2, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                    if let total = subfolder.totalBytes, total > 0 {
                                        Text(total.humanReadableBytes)
                                            .font(.system(.caption2, design: .monospaced))
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
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
                ProgressView().tint(PV.cyan).padding()
            }
        }
    }

    // 排序条：子文件夹 + 资产各一个 Menu
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
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func sortChip(icon: String, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
            Text(text).font(.system(.caption2, design: .monospaced).bold())
        }
        .foregroundStyle(PV.cyan)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(PV.cyan.opacity(0.08), in: Capsule())
    }
}

// MARK: - Empty State

private struct FolderDetailEmptyState: View {
    let hasSearch: Bool

    var body: some View {
        VStack(spacing: 12) {
            Text(hasSearch ? "[ NO MATCH ]" : "[ EMPTY ]")
                .font(.system(.title3, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }
}

// MARK: - Toolbar Menu

private struct FolderDetailMenu: View {
    let folderName: String
    @Binding var renameText: String
    @Binding var showRenameAlert: Bool
    @Binding var showDeleteConfirm: Bool
    @Binding var showCreateFolder: Bool
    @Binding var newFolderName: String

    var body: some View {
        Menu {
            Button {
                newFolderName = ""
                showCreateFolder = true
            } label: {
                Label("新建文件夹", systemImage: "folder.badge.plus")
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
