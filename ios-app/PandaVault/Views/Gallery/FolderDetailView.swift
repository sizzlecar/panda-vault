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

    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        FolderDetailContent(
            subfolders: subfolders,
            filteredAssets: displayedAssets,
            isLoading: isLoading,
            searchText: searchText,
            api: api,
            selectedAsset: $selectedAsset
        )
        .navigationTitle(folder.name)
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "在「\(folder.name)」中搜索...")
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
                    folderName: folder.name,
                    renameText: $renameText,
                    showRenameAlert: $showRenameAlert,
                    showDeleteConfirm: $showDeleteConfirm
                )
            }
        }
        .fullScreenCover(item: $selectedAsset) { asset in
            AssetDetailView(assets: displayedAssets, initialAsset: asset, api: api) {
                Task { await loadFolderAssets() }
            }
        }
        .confirmationDialog(
            "删除文件夹「\(folder.name)」？",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) { Task { await deleteFolder() } }
        }
        .alert("重命名文件夹", isPresented: $showRenameAlert) {
            TextField("文件夹名称", text: $renameText)
            Button("确定") { Task { await renameFolder() } }
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
            subfolders = try await api.getFolders(parentId: folder.id)
        } catch {
            print("[PandaVault] Subfolders error: \(error)")
        }
    }

    private func loadFolderAssets() async {
        isLoading = true
        defer { isLoading = false }
        do {
            assets = try await api.getFolderAssets(folderId: folder.id)
            displayedAssets = assets
        } catch {
            print("[PandaVault] Error: \(error)")
        }
    }

    private func searchInFolder(query: String) async {
        isLoading = true
        defer { isLoading = false }
        do {
            displayedAssets = try await api.getFolderAssets(folderId: folder.id, query: query)
        } catch {
            print("[PandaVault] Search error: \(error)")
        }
    }

    private func deleteFolder() async {
        do {
            try await api.deleteFolder(id: folder.id)
            dismiss()
        } catch {
            print("[PandaVault] Error: \(error)")
        }
    }

    private func renameFolder() async {
        guard !renameText.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        do {
            try await api.renameFolder(id: folder.id, name: renameText)
        } catch {
            print("[PandaVault] Error: \(error)")
        }
    }
}

// MARK: - Content

private struct FolderDetailContent: View {
    let subfolders: [Folder]
    let filteredAssets: [Asset]
    let isLoading: Bool
    let searchText: String
    let api: APIService
    @Binding var selectedAsset: Asset?

    private let columns = [
        GridItem(.adaptive(minimum: 110, maximum: 200), spacing: 2)
    ]

    var body: some View {
        ScrollView {
            // 子文件夹
            if !subfolders.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 12)], spacing: 12) {
                    ForEach(subfolders) { subfolder in
                        NavigationLink(destination: FolderDetailView(folder: subfolder, api: api)) {
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

    var body: some View {
        Menu {
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
