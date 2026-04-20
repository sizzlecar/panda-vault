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
    @State private var showBatchMove = false
    @State private var showMoveAlert = false
    @State private var moveMessage = ""
    @State private var shareItems: [Any] = []
    @State private var showShareSheet = false
    @State private var isSharing = false
    @State private var shareProgress = ""
    @State private var imageSearchItem: PhotosPickerItem?
    @State private var isImageSearching = false

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
                // 搜索/图搜图时详情页只在搜索结果里滑；否则用 timeline 全量顺序
                let source = (!vm.searchText.isEmpty || vm.isImageSearchResult)
                    ? vm.assets
                    : vm.allAssetsOrdered
                AssetDetailView(assets: source, initialAsset: asset, api: appState.api) {
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
                    showDeleteConfirm: $showDeleteConfirm,
                    showBatchMove: $showBatchMove,
                    onSave: { batchSaveToPhotos() },
                    onShare: { Task { await batchShare() } }
                )
            }
            .confirmationDialog(
                "确定删除 \(selectedIds.count) 个素材？",
                isPresented: $showDeleteConfirm,
                titleVisibility: .visible
            ) {
                Button("删除", role: .destructive) { Task { await batchDelete() } }
            }
            .sheet(isPresented: $showBatchMove) {
                MoveToFolderView(api: appState.api, assetIds: Array(selectedIds)) { msg in
                    moveMessage = msg
                    showMoveAlert = true
                    selectedIds.removeAll()
                    isSelecting = false
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
            .overlay {
                if isImageSearching {
                    ZStack {
                        Color.black.opacity(0.4).ignoresSafeArea()
                        VStack(spacing: 12) {
                            ProgressView().tint(.white).scaleEffect(1.2)
                            Text("以图搜图中…")
                                .font(.system(.caption, design: .monospaced).bold())
                                .foregroundStyle(.white)
                        }
                        .padding(24)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                        .environment(\.colorScheme, .dark)
                    }
                }
            }
        }
        .onAppear { vm.updateAPI(appState.api) }
        .onChange(of: appState.serverURL) { _, _ in
            vm.updateAPI(appState.api)
            Task {
                async let t: Void = vm.loadTimelineAndAssets()
                async let f: Void = vm.loadFolders()
                _ = await (t, f)
            }
        }
        .task {
            guard !appState.serverURL.isEmpty else { return }
            vm.updateAPI(appState.api)
            // 并行，降低首屏总耗时（主线程 hang 检测器会把串行等待也算进 ms）
            async let t: Void = vm.loadTimeline()
            async let f: Void = vm.loadFolders()
            _ = await (t, f)
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
            HStack(spacing: 12) {
                if isSelecting {
                    Button {
                        let allIds = Set(vm.allAssetsOrdered.map(\.id))
                        if selectedIds == allIds {
                            selectedIds.removeAll()
                        } else {
                            selectedIds = allIds
                        }
                    } label: {
                        Text(selectedIds.count == vm.allAssetsOrdered.count ? "取消全选" : "全选")
                            .foregroundStyle(PV.cyan)
                    }
                }
                Button {
                    isSelecting.toggle()
                    if !isSelecting { selectedIds.removeAll() }
                } label: {
                    Text(isSelecting ? "完成" : "选择")
                        .foregroundStyle(PV.cyan)
                }
            }
        }
    }

    // MARK: - Actions

    private func handleImageSearch(_ item: PhotosPickerItem?) {
        guard let item else { return }
        Task {
            await MainActor.run { isImageSearching = true }
            defer { Task { @MainActor in isImageSearching = false } }
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

    private func cleanupShareFiles() {
        for item in shareItems {
            if let url = item as? URL {
                try? FileManager.default.removeItem(at: url)
            }
        }
        shareItems = []
    }

    private func batchShare() async {
        let assets = vm.allAssetsOrdered.filter { selectedIds.contains($0.id) }
        isSharing = true
        defer { isSharing = false }

        var localFiles: [Any] = []
        for (i, asset) in assets.enumerated() {
            shareProgress = "下载中 \(i + 1)/\(assets.count)..."
            do {
                let tempURL = try await appState.api.downloadAsset(id: asset.id) { _ in }
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

// MARK: - Activity View (Share Sheet)

struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
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

    @Namespace private var scrollSpace
    @State private var scrollTarget: String?
    @State private var selectedYear: String?
    @State private var activeMonth: String?
    /// 当前屏幕上可见的所有月份 section（通过 onAppear/onDisappear 维护）
    /// max(visibleMonths) = 时间线上最新的可见月份 = 页面最顶部那块
    @State private var visibleMonths: Set<String> = []
    /// 用户上次主动 tap 的时间戳 —— 短时间内抑制 visibleMonths 的 onChange 自动更新，
    /// 避免 LazyVStack 残留的上一屏 onAppear 把 activeMonth 拉错
    @State private var lastManualTap = Date.distantPast

    private var years: [String] {
        // timeline 按月倒序排，取唯一的年，保持顺序（最新年在前）
        var seen: Set<String> = []
        var ordered: [String] = []
        for g in vm.timeline {
            let y = String(g.month.prefix(4))
            if seen.insert(y).inserted { ordered.append(y) }
        }
        return ordered
    }

    private var effectiveYear: String? {
        selectedYear ?? years.first
    }

    private var monthsOfSelectedYear: [TimelineGroup] {
        guard let y = effectiveYear else { return [] }
        return vm.timeline.filter { $0.month.hasPrefix(y) }
    }

    var body: some View {
        VStack(spacing: 0) {
            // 图搜图结果横幅：带退出按钮
            if vm.isImageSearchResult {
                HStack(spacing: 8) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .foregroundStyle(PV.cyan)
                    Text("以图搜图结果 \(vm.assets.count) 张")
                        .font(.system(.caption, design: .monospaced).bold())
                        .foregroundStyle(PV.cyan)
                    Spacer()
                    Button {
                        vm.clearImageSearch()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "xmark.circle.fill")
                            Text("退出").font(.system(.caption, design: .monospaced).bold())
                        }
                        .foregroundStyle(PV.cyan)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(PV.cyan.opacity(0.08))
            }
            // 月份快速跳转栏：年 + 月 两行
            if !vm.timeline.isEmpty && vm.searchText.isEmpty && !vm.isImageSearchResult {
                VStack(spacing: 4) {
                    // 年行
                    if years.count > 1 {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(years, id: \.self) { y in
                                    let active = effectiveYear == y
                                    Button {
                                        lastManualTap = Date()
                                        selectedYear = y
                                        // 切换年时滚动到该年最新月份
                                        if let first = vm.timeline.first(where: { $0.month.hasPrefix(y) }) {
                                            activeMonth = first.month
                                            scrollTarget = first.month
                                        }
                                    } label: {
                                        Text(y + "年")
                                            .font(.system(.caption2, design: .monospaced).bold())
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 5)
                                            .background(active ? PV.cyan : PV.cyan.opacity(0.08), in: Capsule())
                                            .foregroundStyle(active ? .white : PV.cyan)
                                    }
                                }
                            }
                            .padding(.horizontal)
                        }
                    }
                    // 月份行（根据所选年过滤）
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(monthsOfSelectedYear) { group in
                                let active = activeMonth == group.month
                                Button {
                                    lastManualTap = Date()
                                    activeMonth = group.month
                                    selectedYear = String(group.month.prefix(4))
                                    scrollTarget = group.month
                                } label: {
                                    Text(shortMonthOnly(group.month))
                                        .font(.system(.caption2, design: .monospaced).bold())
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 5)
                                        .background(active ? PV.cyan : PV.cyan.opacity(0.1), in: Capsule())
                                        .foregroundStyle(active ? .white : PV.cyan)
                                }
                            }
                        }
                        .padding(.horizontal)
                    }
                }
                .padding(.vertical, 6)
                .background(Color(.systemBackground))
            }

            ScrollViewReader { proxy in
                ScrollView {
                    if !vm.searchText.isEmpty || vm.isImageSearchResult {
                        GalleryAssetsGrid(
                            assets: vm.assets,
                            api: api,
                            isSelecting: $isSelecting,
                            selectedIds: $selectedIds,
                            selectedAsset: $selectedAsset
                        )
                    } else if let err = vm.errorMessage {
                        GalleryErrorState(message: err) {
                            Task { await vm.loadTimelineAndAssets() }
                        }
                    } else if vm.timeline.isEmpty && !vm.isLoading {
                        GalleryEmptyState()
                    } else {
                        timelineContent
                    }
                }
                .onChange(of: scrollTarget) { _, target in
                    guard let target else { return }
                    withAnimation {
                        proxy.scrollTo(target, anchor: .top)
                    }
                    scrollTarget = nil
                }
                .onChange(of: visibleMonths) { _, new in
                    // tap 触发的滚动期间抑制自动更新 —— 避免 LazyVStack 残留的旧 section
                    // 短暂出现在 visibleMonths 里，把 activeMonth 拉错
                    guard Date().timeIntervalSince(lastManualTap) > 0.8 else { return }
                    // 页面最顶部 section = 时间线上最新的可见月份（timeline 按月倒序）
                    guard let top = new.max() else { return }
                    if activeMonth != top { activeMonth = top }
                    let y = String(top.prefix(4))
                    if selectedYear != y { selectedYear = y }
                }
            }
        }
    }

    private func shortMonth(_ month: String) -> String {
        // "2026-03" → "3月"
        let parts = month.split(separator: "-")
        guard parts.count == 2, let m = Int(parts[1]) else { return month }
        let y = String(parts[0].suffix(2))
        return "\(y).\(m)月"
    }

    /// "2026-03" → "3月"（已在外层选定年，月份行不再重复显示年份）
    private func shortMonthOnly(_ month: String) -> String {
        let parts = month.split(separator: "-")
        guard parts.count == 2, let m = Int(parts[1]) else { return month }
        return "\(m)月"
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
                        .id(group.month)
                        .onAppear {
                            vm.ensureMonthLoaded(group.month)
                            visibleMonths.insert(group.month)
                        }
                        .onDisappear {
                            visibleMonths.remove(group.month)
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

struct GalleryAssetsGrid: View {
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

struct GalleryAssetCell: View {
    let asset: Asset
    let api: APIService
    @Binding var isSelecting: Bool
    @Binding var selectedIds: Set<UUID>
    @Binding var selectedAsset: Asset?

    var body: some View {
        let isSelected = isSelecting && selectedIds.contains(asset.id)
        Button {
            if isSelecting {
                toggleSelection()
            } else {
                selectedAsset = asset
            }
        } label: {
            AssetThumbnail(asset: asset, api: api)
                .overlay {
                    if isSelected {
                        Color.black.opacity(0.2)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if isSelecting {
                        ZStack {
                            Circle()
                                .fill(isSelected ? PV.cyan : .black.opacity(0.3))
                                .frame(width: 22, height: 22)
                            if isSelected {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(.white)
                            } else {
                                Circle()
                                    .strokeBorder(.white, lineWidth: 1.5)
                                    .frame(width: 22, height: 22)
                            }
                        }
                        .shadow(color: .black.opacity(0.3), radius: 2)
                        .padding(6)
                    }
                }
                .border(isSelected ? PV.cyan : .clear, width: 2)
        }
        .buttonStyle(.plain)
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

    @State private var sortOption: FolderSortOption = .nameAsc

    var body: some View {
        VStack(spacing: 0) {
            sortBar
            ScrollView {
                if vm.folders.isEmpty && !vm.isLoading {
                    GalleryFoldersEmptyState()
                } else {
                    foldersGrid
                }
            }
            .refreshable { await vm.loadFolders() }
        }
        .task { await vm.loadFolders() }
    }

    private var sortBar: some View {
        HStack {
            Menu {
                ForEach(FolderSortOption.allCases) { opt in
                    Button {
                        sortOption = opt
                    } label: {
                        if opt == sortOption {
                            Label(opt.rawValue, systemImage: "checkmark")
                        } else {
                            Text(opt.rawValue)
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up.arrow.down.square")
                    Text(sortOption.rawValue)
                        .font(.system(.caption, design: .monospaced).bold())
                }
                .foregroundStyle(PV.cyan)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(PV.cyan.opacity(0.08), in: Capsule())
            }
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
    }

    private var foldersGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 12)], spacing: 12) {
            ForEach(vm.folders.sorted(by: sortOption)) { folder in
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

private struct GalleryErrorState: View {
    let message: String
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text(message)
                .font(.system(.caption, design: .monospaced).bold())
                .foregroundStyle(.secondary)
            Button(action: onRetry) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.clockwise")
                    Text("重试")
                }
                .font(.system(.subheadline, design: .monospaced).bold())
                .foregroundStyle(PV.cyan)
            }
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

struct GalleryBottomInset: View {
    let appState: AppState
    let isSelecting: Bool
    let selectedIds: Set<UUID>
    @Binding var showDeleteConfirm: Bool
    @Binding var showBatchMove: Bool
    let onSave: () -> Void
    let onShare: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if !appState.downloadManager.tasks.isEmpty {
                GalleryDownloadProgress(dm: appState.downloadManager)
            }
            if isSelecting && !selectedIds.isEmpty {
                GalleryBatchToolbar(
                    count: selectedIds.count,
                    showDeleteConfirm: $showDeleteConfirm,
                    showBatchMove: $showBatchMove,
                    onSave: onSave,
                    onShare: onShare
                )
            }
        }
    }
}

// MARK: - Download Progress Bar

struct GalleryDownloadProgress: View {
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

struct GalleryBatchToolbar: View {
    let count: Int
    @Binding var showDeleteConfirm: Bool
    @Binding var showBatchMove: Bool
    let onSave: () -> Void
    let onShare: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            Text("已选 \(count) 项")
                .font(.system(.caption2, design: .monospaced).bold())
                .foregroundStyle(.secondary)
                .padding(.top, 8)

            HStack(spacing: 0) {
                batchButton(icon: "square.and.arrow.down", label: "保存", color: PV.cyan) { onSave() }
                batchButton(icon: "folder.badge.plus", label: "移动", color: PV.cyan) { showBatchMove = true }
                batchButton(icon: "square.and.arrow.up", label: "分享", color: PV.cyan) { onShare() }
                batchButton(icon: "trash", label: "删除", color: PV.pink) { showDeleteConfirm = true }
            }
            .padding(.vertical, 8)
        }
        .background(.regularMaterial)
    }

    private func batchButton(icon: String, label: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.title3)
                Text(label).font(.system(.caption2, design: .monospaced))
            }
            .frame(maxWidth: .infinity)
            .foregroundStyle(color)
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
            HStack(spacing: 6) {
                if folder.assetCount == nil || folder.totalBytes == nil {
                    // 后端懒计算中
                    Text("计算中…")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.tertiary)
                } else {
                    Text("\(folder.assetCount ?? 0) items")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    if let total = folder.totalBytes, total > 0 {
                        Text("·")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.tertiary)
                        Text(total.humanReadableBytes)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

// MARK: - Folder Sort

enum FolderSortOption: String, CaseIterable, Identifiable {
    case nameAsc = "名称 ↑"
    case nameDesc = "名称 ↓"
    case sizeDesc = "大小 ↓"
    case sizeAsc = "大小 ↑"
    case updatedDesc = "最近修改 ↓"
    case updatedAsc = "最近修改 ↑"
    var id: String { rawValue }
}

extension Array where Element == Folder {
    func sorted(by option: FolderSortOption) -> [Folder] {
        switch option {
        case .nameAsc:     return sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .nameDesc:    return sorted { $0.name.localizedStandardCompare($1.name) == .orderedDescending }
        case .sizeDesc:    return sorted { ($0.totalBytes ?? -1) > ($1.totalBytes ?? -1) }
        case .sizeAsc:     return sorted { ($0.totalBytes ?? Int64.max) < ($1.totalBytes ?? Int64.max) }
        case .updatedDesc: return sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
        case .updatedAsc:  return sorted { ($0.updatedAt ?? .distantFuture) < ($1.updatedAt ?? .distantFuture) }
        }
    }
}

// MARK: - ViewModel Extensions

extension GalleryViewModel {
    func updateAPI(_ api: APIService) {
        self.api = api
    }
}
