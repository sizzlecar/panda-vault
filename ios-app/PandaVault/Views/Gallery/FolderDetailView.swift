import SwiftUI

struct FolderDetailView: View {
    let folder: Folder
    let api: APIService

    @Environment(\.dismiss) private var dismiss
    @State private var assets: [Asset] = []
    @State private var isLoading = false
    @State private var searchText = ""
    @State private var selectedAsset: Asset?
    @State private var showDeleteConfirm = false
    @State private var showRenameAlert = false
    @State private var renameText = ""

    private let columns = [
        GridItem(.adaptive(minimum: 110, maximum: 200), spacing: 2)
    ]

    var filteredAssets: [Asset] {
        if searchText.isEmpty { return assets }
        return assets.filter { $0.filename.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        ZStack {
            PV.bg.ignoresSafeArea()

            ScrollView {
                if filteredAssets.isEmpty && !isLoading {
                    VStack(spacing: 12) {
                        Text(searchText.isEmpty ? "[ EMPTY ]" : "[ NO MATCH ]")
                            .font(.system(.title3, design: .monospaced))
                            .foregroundStyle(PV.textMuted)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 80)
                } else {
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

                if isLoading {
                    ProgressView().tint(PV.cyan).padding()
                }
            }
        }
        .navigationTitle(folder.name)
        .searchable(text: $searchText, prompt: "在「\(folder.name)」中搜索...")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        renameText = folder.name
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
        .fullScreenCover(item: $selectedAsset) { asset in
            AssetDetailView(assets: filteredAssets, initialAsset: asset, api: api)
        }
        .confirmationDialog("删除文件夹「\(folder.name)」？", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("删除", role: .destructive) { Task { await deleteFolder() } }
        }
        .alert("重命名文件夹", isPresented: $showRenameAlert) {
            TextField("文件夹名称", text: $renameText)
            Button("确定") { Task { await renameFolder() } }
            Button("取消", role: .cancel) {}
        }
        .task { await loadFolderAssets() }
        .refreshable { await loadFolderAssets() }
    }

    private func loadFolderAssets() async {
        isLoading = true
        defer { isLoading = false }
        do {
            assets = try await api.getFolderAssets(folderId: folder.id)
        } catch { print("[PandaVault] Error: \(error)") }
    }

    private func deleteFolder() async {
        do {
            try await api.deleteFolder(id: folder.id)
            dismiss()
        } catch { print("[PandaVault] Error: \(error)") }
    }

    private func renameFolder() async {
        guard !renameText.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        do {
            try await api.renameFolder(id: folder.id, name: renameText)
        } catch { print("[PandaVault] Error: \(error)") }
    }
}
