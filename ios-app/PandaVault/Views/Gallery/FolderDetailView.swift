import SwiftUI

// MARK: - FolderDetailView

struct FolderDetailView: View {
    let folder: Folder
    let api: APIService

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

    @State private var searchTask: Task<Void, Never>?

    // 面包屑导航
    @State private var breadcrumbs: [(name: String, id: UUID)] = []
    @State private var currentFolder: Folder?

    private var activeFolder: Folder { currentFolder ?? folder }

    var body: some View {
        FolderDetailContent(
            breadcrumbs: breadcrumbs,
            rootFolderName: folder.name,
            subfolders: subfolders,
            filteredAssets: displayedAssets,
            isLoading: isLoading,
            searchText: searchText,
            api: api,
            selectedAsset: $selectedAsset,
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
        .navigationTitle(activeFolder.name)
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "在「\(activeFolder.name)」中搜索...")
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
        .fullScreenCover(item: $selectedAsset) { asset in
            AssetDetailView(assets: displayedAssets, initialAsset: asset, api: api) {
                Task { await loadFolderAssets() }
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

        let folderAssetIds = Set(assets.map(\.id))
        do {
            let semanticResults = try await api.semanticSearch(text: query)
            let filtered = semanticResults.filter { folderAssetIds.contains($0.id) }
            if !filtered.isEmpty {
                displayedAssets = filtered
                return
            }
        } catch {}

        do {
            let fileResults = try await api.getFolderAssets(folderId: activeFolder.id, query: query)
            displayedAssets = fileResults
        } catch {
            print("[PandaVault] Search error: \(error)")
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
    var onSubfolderTap: ((Folder) -> Void)?
    var onBreadcrumbTap: ((Int) -> Void)?

    private let columns = [
        GridItem(.adaptive(minimum: 110, maximum: 200), spacing: 2)
    ]

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
                                Text("\(subfolder.assetCount ?? 0)")
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.secondary)
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
                assetsGrid
            }
            if isLoading {
                ProgressView().tint(PV.cyan).padding()
            }
        }
    }

    private var assetsGrid: some View {
        LazyVGrid(columns: columns, spacing: 2) {
            ForEach(filteredAssets) { asset in
                Button { selectedAsset = asset } label: {
                    AssetThumbnail(asset: asset, api: api)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 2)
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
