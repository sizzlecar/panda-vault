import SwiftUI
import PhotosUI

struct GalleryView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var vm: GalleryViewModel
    @State private var selectedAsset: Asset?
    @State private var viewMode: ViewMode = .timeline
    @State private var selectedFolder: Folder?
    @State private var isSelecting = false
    @State private var selectedIds: Set<UUID> = []
    @State private var showDeleteConfirm = false
    @State private var imageSearchItem: PhotosPickerItem?

    enum ViewMode: String, CaseIterable {
        case timeline = "时间"
        case folders = "文件夹"
    }

    init() {
        _vm = StateObject(wrappedValue: GalleryViewModel(api: APIService(baseURL: "")))
    }

    private let columns = [
        GridItem(.adaptive(minimum: 110, maximum: 200), spacing: 2)
    ]

    var body: some View {
        NavigationStack {
            ZStack {
                PV.bg.ignoresSafeArea()

                VStack(spacing: 0) {
                    // 模式切换
                    HStack(spacing: 0) {
                        ForEach(ViewMode.allCases, id: \.self) { mode in
                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) { viewMode = mode }
                            } label: {
                                Text(mode.rawValue.uppercased())
                                    .font(.system(.caption, design: .monospaced).bold())
                                    .tracking(2)
                                    .foregroundStyle(viewMode == mode ? PV.cyan : PV.textMuted)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 10)
                                    .background(viewMode == mode ? PV.surfaceBg : .clear, in: RoundedRectangle(cornerRadius: 3))
                            }
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 6)

                    switch viewMode {
                    case .timeline: timelineView
                    case .folders: foldersView
                    }
                }
            }
            .navigationTitle("素材库")
            .searchable(text: $vm.searchText, prompt: "搜索素材...")
            .onSubmit(of: .search) { Task { await vm.search() } }
            .onChange(of: vm.searchText) { _, val in
                if val.isEmpty { Task { await vm.loadAssets(refresh: true) } }
            }
            .toolbar {
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
                            .font(.system(.caption, design: .monospaced).bold())
                            .foregroundStyle(PV.cyan)
                    }
                }
            }
            .onChange(of: imageSearchItem) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self) {
                        await vm.imageSearch(data: data)
                    }
                    imageSearchItem = nil
                }
            }
            .refreshable {
                await vm.loadTimeline()
                await vm.loadAssets(refresh: true)
                await vm.loadFolders()
            }
            .fullScreenCover(item: $selectedAsset) { asset in
                AssetDetailView(assets: vm.allAssetsOrdered, initialAsset: asset, api: appState.api)
            }
            .navigationDestination(item: $selectedFolder) { folder in
                FolderDetailView(folder: folder, api: appState.api)
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 0) {
                    if !appState.downloadManager.tasks.isEmpty {
                        downloadProgressBar
                    }
                    if isSelecting && !selectedIds.isEmpty {
                        batchToolbar
                    }
                }
            }
            .confirmationDialog("确定删除 \(selectedIds.count) 个素材？", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
                Button("删除", role: .destructive) { Task { await batchDelete() } }
            }
        }
        .onAppear { vm.updateAPI(appState.api) }
        .onChange(of: appState.serverURL) { _, _ in
            vm.updateAPI(appState.api)
            Task { await vm.loadTimeline(); await vm.loadAssets(refresh: true); await vm.loadFolders() }
        }
        .task {
            guard !appState.serverURL.isEmpty else { return }
            vm.updateAPI(appState.api)
            await vm.loadTimeline()
            await vm.loadAssets(refresh: true)
            await vm.loadFolders()
        }
    }

    // MARK: - Download Progress

    private var downloadProgressBar: some View {
        let dm = appState.downloadManager
        return VStack(spacing: 4) {
            PixelProgressBar(progress: dm.overallProgress, color: dm.failedCount > 0 ? PV.orange : PV.green)
            HStack {
                Text("SAVE \(dm.completedCount)/\(dm.totalCount)")
                    .font(.system(.caption2, design: .monospaced).bold())
                    .foregroundStyle(PV.textPrimary)
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
        .background(PV.cardBg)
    }

    // MARK: - Batch Toolbar

    private var batchToolbar: some View {
        HStack(spacing: 0) {
            Button { batchSaveToPhotos() } label: {
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
        .background(PV.cardBg)
        .overlay(alignment: .top) {
            Text("已选 \(selectedIds.count) 项")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(PV.textMuted)
                .padding(.top, -14)
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
        await vm.loadTimeline()
        await vm.loadAssets(refresh: true)
    }

    // MARK: - Timeline

    private var timelineView: some View {
        ScrollView {
            if !vm.searchText.isEmpty {
                assetsGrid(vm.assets)
            } else if vm.timeline.isEmpty && !vm.isLoading {
                emptyState
            } else {
                LazyVStack(alignment: .leading, spacing: 12, pinnedViews: .sectionHeaders) {
                    ForEach(vm.timeline) { group in
                        Section {
                            assetsGrid(vm.assetsForMonth(group.month))
                        } header: {
                            HStack {
                                Text(group.displayMonth)
                                    .font(.system(.caption, design: .monospaced).bold())
                                    .foregroundStyle(PV.textPrimary)
                                Spacer()
                                Text("\(group.count)")
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(PV.textMuted)
                            }
                            .padding(.horizontal)
                            .padding(.vertical, 6)
                            .background(PV.bg.opacity(0.95))
                        }
                    }
                    if vm.isLoading {
                        ProgressView().tint(PV.cyan).frame(maxWidth: .infinity).padding()
                    }
                }
            }
        }
    }

    private func assetsGrid(_ assets: [Asset]) -> some View {
        LazyVGrid(columns: columns, spacing: 2) {
            ForEach(assets) { asset in
                Button {
                    if isSelecting {
                        if selectedIds.contains(asset.id) { selectedIds.remove(asset.id) }
                        else { selectedIds.insert(asset.id) }
                    } else {
                        selectedAsset = asset
                    }
                } label: {
                    AssetThumbnail(asset: asset, api: appState.api)
                        .overlay(alignment: .topTrailing) {
                            if isSelecting {
                                Image(systemName: selectedIds.contains(asset.id) ? "checkmark.square.fill" : "square")
                                    .font(.body)
                                    .foregroundStyle(selectedIds.contains(asset.id) ? PV.cyan : .white.opacity(0.6))
                                    .shadow(radius: 2)
                                    .padding(5)
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 2)
    }

    // MARK: - Folders

    private var foldersView: some View {
        ScrollView {
            if vm.folders.isEmpty && !vm.isLoading {
                VStack(spacing: 12) {
                    Text("[ EMPTY ]")
                        .font(.system(.title3, design: .monospaced))
                        .foregroundStyle(PV.textMuted)
                    Text("在「上传」页面创建文件夹")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(PV.textMuted)
                }
                .padding(.top, 80)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 12)], spacing: 12) {
                    ForEach(vm.folders) { folder in
                        Button { selectedFolder = folder } label: {
                            FolderCard(folder: folder, api: appState.api)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding()
            }
        }
        .task { await vm.loadFolders() }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Text("[ NO DATA ]")
                .font(.system(.title2, design: .monospaced).bold())
                .foregroundStyle(PV.textMuted)
            Text("从「上传」页面添加视频或图片")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(PV.textMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 100)
    }
}

// MARK: - Folder Card

struct FolderCard: View {
    let folder: Folder
    let api: APIService

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let coverURL = api.folderCoverURL(for: folder) {
                AsyncImage(url: coverURL) { phase in
                    if let image = phase.image {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else { PV.surfaceBg }
                }
                .frame(height: 90)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 3))
            } else {
                RoundedRectangle(cornerRadius: 3)
                    .fill(PV.surfaceBg)
                    .frame(height: 90)
                    .overlay {
                        Image(systemName: "folder.fill")
                            .font(.title3)
                            .foregroundStyle(PV.textMuted)
                    }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(folder.name)
                    .font(.system(.caption, design: .monospaced).bold())
                    .foregroundStyle(PV.textPrimary)
                    .lineLimit(1)
                if let count = folder.assetCount {
                    Text("\(count) items")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(PV.textMuted)
                }
            }
        }
        .padding(6)
        .background(PV.cardBg, in: RoundedRectangle(cornerRadius: 4))
    }
}

// MARK: - ViewModel Extensions

extension GalleryViewModel {
    func updateAPI(_ api: APIService) {
        self.api = api
    }
}
