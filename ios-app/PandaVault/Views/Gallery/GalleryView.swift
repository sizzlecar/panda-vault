import SwiftUI
import PhotosUI

// MARK: - GalleryView

struct GalleryView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var vm: GalleryViewModel
    @State private var selectedAsset: Asset?
    @State private var viewMode: GalleryViewMode = .timeline
    @State private var selectedFolder: Folder?
    @State private var isSelecting = false
    @State private var selectedIds: Set<UUID> = []
    @State private var showDeleteConfirm = false
    @State private var imageSearchItem: PhotosPickerItem?

    init() {
        _vm = StateObject(wrappedValue: GalleryViewModel(api: APIService(baseURL: "")))
    }

    var body: some View {
        NavigationStack {
            GalleryContentView(
                viewMode: $viewMode,
                vm: vm,
                appState: appState,
                isSelecting: $isSelecting,
                selectedIds: $selectedIds,
                selectedAsset: $selectedAsset,
                selectedFolder: $selectedFolder
            )
            .navigationTitle("素材库")
            .searchable(text: $vm.searchText, prompt: "搜索素材...")
            .onSubmit(of: .search) { Task { await vm.search() } }
            .onChange(of: vm.searchText) { _, val in
                if val.isEmpty { vm.clearImageSearch() }
            }
            .toolbar { galleryToolbar }
            .onChange(of: imageSearchItem) { _, item in
                handleImageSearch(item)
            }
            .refreshable {
                await vm.loadTimelineAndAssets()
                await vm.loadFolders()
            }
            .fullScreenCover(item: $selectedAsset) { asset in
                AssetDetailView(assets: vm.allAssetsOrdered, initialAsset: asset, api: appState.api) {
                    Task {
                        await vm.loadTimelineAndAssets()
                    }
                }
            }
            .navigationDestination(item: $selectedFolder) { folder in
                FolderDetailView(folder: folder, api: appState.api)
            }
            .safeAreaInset(edge: .bottom) {
                GalleryBottomInset(
                    appState: appState,
                    isSelecting: isSelecting,
                    selectedIds: selectedIds,
                    showDeleteConfirm: $showDeleteConfirm
                ) {
                    batchSaveToPhotos()
                }
            }
            .confirmationDialog(
                "确定删除 \(selectedIds.count) 个素材？",
                isPresented: $showDeleteConfirm,
                titleVisibility: .visible
            ) {
                Button("删除", role: .destructive) { Task { await batchDelete() } }
            }
        }
        .onAppear { vm.updateAPI(appState.api) }
        .onChange(of: appState.serverURL) { _, _ in
            vm.updateAPI(appState.api)
            Task {
                await vm.loadTimelineAndAssets()
                await vm.loadFolders()
            }
        }
        .task {
            guard !appState.serverURL.isEmpty else { return }
            vm.updateAPI(appState.api)
            await vm.loadTimeline()
            await vm.loadFolders()
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var galleryToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            PhotosPicker(selection: $imageSearchItem, matching: .images) {
                Image(systemName: "camera.viewfinder").foregroundStyle(PV.cyan)
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                isSelecting.toggle()
                if !isSelecting { selectedIds.removeAll() }
            } label: {
                Text(isSelecting ? "完成" : "选择")
                    .foregroundStyle(PV.cyan)
            }
        }
    }

    // MARK: - Actions

    private func handleImageSearch(_ item: PhotosPickerItem?) {
        guard let item else { return }
        Task {
            if let data = try? await item.loadTransferable(type: Data.self) {
                await vm.imageSearch(data: data)
            }
            imageSearchItem = nil
        }
    }

    private func batchSaveToPhotos() {
        let assets = vm.allAssetsOrdered.filter { selectedIds.contains($0.id) }
        appState.downloadManager.updateAPI(appState.api)
        appState.downloadManager.addAssets(assets)
        selectedIds.removeAll()
        isSelecting = false
    }

    private func batchDelete() async {
        for id in selectedIds {
            try? await appState.api.deleteAsset(id: id)
        }
        selectedIds.removeAll()
        isSelecting = false
        await vm.loadTimelineAndAssets()
    }
}

// MARK: - View Mode

enum GalleryViewMode: String, CaseIterable {
    case timeline = "时间"
    case folders = "文件夹"
}

// MARK: - Content View (segmented picker + switched content)

private struct GalleryContentView: View {
    @Binding var viewMode: GalleryViewMode
    @ObservedObject var vm: GalleryViewModel
    let appState: AppState
    @Binding var isSelecting: Bool
    @Binding var selectedIds: Set<UUID>
    @Binding var selectedAsset: Asset?
    @Binding var selectedFolder: Folder?

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $viewMode) {
                ForEach(GalleryViewMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)

            switch viewMode {
            case .timeline:
                GalleryTimelineView(
                    vm: vm,
                    api: appState.api,
                    isSelecting: $isSelecting,
                    selectedIds: $selectedIds,
                    selectedAsset: $selectedAsset
                )
            case .folders:
                GalleryFoldersView(
                    vm: vm,
                    api: appState.api,
                    selectedFolder: $selectedFolder
                )
            }
        }
    }
}

// MARK: - Timeline View

private struct GalleryTimelineView: View {
    @ObservedObject var vm: GalleryViewModel
    let api: APIService
    @Binding var isSelecting: Bool
    @Binding var selectedIds: Set<UUID>
    @Binding var selectedAsset: Asset?

    var body: some View {
        ScrollView {
            if !vm.searchText.isEmpty || vm.isImageSearchResult {
                GalleryAssetsGrid(
                    assets: vm.assets,
                    api: api,
                    isSelecting: $isSelecting,
                    selectedIds: $selectedIds,
                    selectedAsset: $selectedAsset
                )
            } else if vm.timeline.isEmpty && !vm.isLoading {
                GalleryEmptyState()
            } else {
                timelineContent
            }
        }
    }

    private var timelineContent: some View {
        LazyVStack(alignment: .leading, spacing: 12, pinnedViews: .sectionHeaders) {
            ForEach(vm.timeline) { group in
                Section {
                    let monthAssets = vm.assetsForMonth(group.month)
                    if monthAssets.isEmpty && vm.isMonthLoading(group.month) {
                        // 该月正在加载，显示占位
                        ProgressView()
                            .tint(PV.cyan)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 20)
                    } else {
                        GalleryAssetsGrid(
                            assets: monthAssets,
                            api: api,
                            isSelecting: $isSelecting,
                            selectedIds: $selectedIds,
                            selectedAsset: $selectedAsset
                        )
                    }
                } header: {
                    TimelineSectionHeader(group: group)
                        .onAppear {
                            vm.ensureMonthLoaded(group.month)
                        }
                }
            }
            if vm.isLoading {
                ProgressView()
                    .tint(PV.cyan)
                    .frame(maxWidth: .infinity)
                    .padding()
            }
        }
    }
}

// MARK: - Timeline Section Header

private struct TimelineSectionHeader: View {
    let group: TimelineGroup

    var body: some View {
        HStack {
            Text(group.displayMonth)
                .font(.system(.caption, design: .monospaced).bold())
                .foregroundStyle(.primary)
            Spacer()
            Text("\(group.count)")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(Color(.systemBackground))
    }
}

// MARK: - Assets Grid

private struct GalleryAssetsGrid: View {
    let assets: [Asset]
    let api: APIService
    @Binding var isSelecting: Bool
    @Binding var selectedIds: Set<UUID>
    @Binding var selectedAsset: Asset?

    private let columns = [
        GridItem(.adaptive(minimum: 110, maximum: 200), spacing: 2)
    ]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 2) {
            ForEach(assets) { asset in
                GalleryAssetCell(
                    asset: asset,
                    api: api,
                    isSelecting: $isSelecting,
                    selectedIds: $selectedIds,
                    selectedAsset: $selectedAsset
                )
            }
        }
        .padding(.horizontal, 2)
    }
}

// MARK: - Single Asset Cell

private struct GalleryAssetCell: View {
    let asset: Asset
    let api: APIService
    @Binding var isSelecting: Bool
    @Binding var selectedIds: Set<UUID>
    @Binding var selectedAsset: Asset?

    var body: some View {
        Button {
            if isSelecting {
                toggleSelection()
            } else {
                selectedAsset = asset
            }
        } label: {
            AssetThumbnail(asset: asset, api: api)
                .overlay(alignment: .topTrailing) {
                    selectionOverlay
                }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var selectionOverlay: some View {
        if isSelecting {
            let isSelected = selectedIds.contains(asset.id)
            Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                .font(.body)
                .foregroundStyle(isSelected ? PV.cyan : .white.opacity(0.6))
                .shadow(radius: 2)
                .padding(5)
        }
    }

    private func toggleSelection() {
        if selectedIds.contains(asset.id) {
            selectedIds.remove(asset.id)
        } else {
            selectedIds.insert(asset.id)
        }
    }
}

// MARK: - Folders View

private struct GalleryFoldersView: View {
    @ObservedObject var vm: GalleryViewModel
    let api: APIService
    @Binding var selectedFolder: Folder?

    var body: some View {
        ScrollView {
            if vm.folders.isEmpty && !vm.isLoading {
                GalleryFoldersEmptyState()
            } else {
                foldersGrid
            }
        }
        .task { await vm.loadFolders() }
    }

    private var foldersGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 12)], spacing: 12) {
            ForEach(vm.folders) { folder in
                Button { selectedFolder = folder } label: {
                    FolderCard(folder: folder, api: api)
                }
                .buttonStyle(.plain)
            }
        }
        .padding()
    }
}

// MARK: - Empty States

private struct GalleryEmptyState: View {
    var body: some View {
        VStack(spacing: 16) {
            Text("[ NO DATA ]")
                .font(.system(.title2, design: .monospaced).bold())
                .foregroundStyle(.tertiary)
            Text("从「上传」页面添加视频或图片")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 100)
    }
}

private struct GalleryFoldersEmptyState: View {
    var body: some View {
        VStack(spacing: 12) {
            Text("[ EMPTY ]")
                .font(.system(.title3, design: .monospaced))
                .foregroundStyle(.tertiary)
            Text("在「上传」页面创建文件夹")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .padding(.top, 80)
    }
}

// MARK: - Bottom Inset (download progress + batch toolbar)

private struct GalleryBottomInset: View {
    let appState: AppState
    let isSelecting: Bool
    let selectedIds: Set<UUID>
    @Binding var showDeleteConfirm: Bool
    let onSave: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if !appState.downloadManager.tasks.isEmpty {
                GalleryDownloadProgress(dm: appState.downloadManager)
            }
            if isSelecting && !selectedIds.isEmpty {
                GalleryBatchToolbar(
                    count: selectedIds.count,
                    showDeleteConfirm: $showDeleteConfirm,
                    onSave: onSave
                )
            }
        }
    }
}

// MARK: - Download Progress Bar

private struct GalleryDownloadProgress: View {
    @ObservedObject var dm: DownloadManager

    var body: some View {
        VStack(spacing: 4) {
            PixelProgressBar(
                progress: dm.overallProgress,
                color: dm.failedCount > 0 ? PV.orange : PV.green
            )
            HStack {
                Text("SAVE \(dm.completedCount)/\(dm.totalCount)")
                    .font(.system(.caption2, design: .monospaced).bold())
                    .foregroundStyle(.primary)
                if dm.failedCount > 0 {
                    PixelTag(text: "\(dm.failedCount) FAIL", color: PV.pink)
                }
                Spacer()
                if dm.isDone {
                    Button("关闭") { dm.clear() }
                        .font(.system(.caption2, design: .monospaced).bold())
                        .foregroundStyle(PV.cyan)
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color(.secondarySystemGroupedBackground))
    }
}

// MARK: - Batch Toolbar

private struct GalleryBatchToolbar: View {
    let count: Int
    @Binding var showDeleteConfirm: Bool
    let onSave: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onSave) {
                VStack(spacing: 3) {
                    Image(systemName: "square.and.arrow.down").font(.body)
                    Text("保存").font(.system(.caption2, design: .monospaced))
                }
                .frame(maxWidth: .infinity)
                .foregroundStyle(PV.green)
            }
            Button { showDeleteConfirm = true } label: {
                VStack(spacing: 3) {
                    Image(systemName: "trash").font(.body)
                    Text("删除").font(.system(.caption2, design: .monospaced))
                }
                .frame(maxWidth: .infinity)
                .foregroundStyle(PV.pink)
            }
        }
        .padding(.vertical, 10)
        .background(Color(.secondarySystemGroupedBackground))
        .overlay(alignment: .top) {
            Text("已选 \(count) 项")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.tertiary)
                .padding(.top, -14)
        }
    }
}

// MARK: - Folder Card

struct FolderCard: View {
    let folder: Folder
    let api: APIService

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            folderCover
            folderInfo
        }
        .padding(6)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 4))
    }

    @ViewBuilder
    private var folderCover: some View {
        if let coverURL = api.folderCoverURL(for: folder) {
            AsyncImage(url: coverURL) { phase in
                if let image = phase.image {
                    image.resizable().aspectRatio(contentMode: .fill)
                } else {
                    Color(.secondarySystemFill)
                }
            }
            .frame(height: 90)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 3))
        } else {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color(.secondarySystemFill))
                .frame(height: 90)
                .overlay {
                    Image(systemName: "folder.fill")
                        .font(.title3)
                        .foregroundStyle(.tertiary)
                }
        }
    }

    private var folderInfo: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(folder.name)
                .font(.system(.caption, design: .monospaced).bold())
                .foregroundStyle(.primary)
                .lineLimit(1)
            if let count = folder.assetCount {
                Text("\(count) items")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

// MARK: - ViewModel Extensions

extension GalleryViewModel {
    func updateAPI(_ api: APIService) {
        self.api = api
    }
}
