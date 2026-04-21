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
    @State private var showExport = false

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
                selectedFolder: $selectedFolder,
                imageSearchItem: $imageSearchItem,
                onRecentFolderTap: { folder in
                    selectedFolder = folder
                }
            )
            .background(PV.bg.ignoresSafeArea())
            .scrollContentBackground(.hidden)
            .toolbar(.hidden, for: .navigationBar)
            .onChange(of: vm.searchText) { _, val in
                if val.isEmpty { vm.clearImageSearch() }
            }
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
                AssetDetailView(
                    assets: source,
                    initialAsset: asset,
                    api: appState.api,
                    onDelete: {
                        Task { await vm.loadTimelineAndAssets() }
                    },
                    onAssetUpdated: { updated in
                        vm.replaceAsset(updated)
                    }
                )
                .onAppear { PVLog.perf("打开素材详情") }
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
            // 批量工具栏单独 overlay — 配合 appState.tabBarHidden 让 CTabBar 让位
            .overlay(alignment: .bottom) {
                if isSelecting && !selectedIds.isEmpty {
                    FloatingBatchBar(
                        count: selectedIds.count,
                        showDeleteConfirm: $showDeleteConfirm,
                        showBatchMove: $showBatchMove,
                        onSave: { batchSaveToPhotos() },
                        onShare: { Task { await batchShare() } },
                        onExport: { showExport = true }
                    )
                }
            }
            .sheet(isPresented: $showExport) {
                ExportSheet(api: appState.api, assetIds: Array(selectedIds))
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
            // 并行拉 timeline / folders / recentFolders，降低首屏总耗时
            async let t: Void = vm.loadTimeline()
            async let f: Void = vm.loadFolders()
            async let r: Void = vm.loadRecentFolders()
            _ = await (t, f, r)
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
    @Binding var imageSearchItem: PhotosPickerItem?
    var onRecentFolderTap: (Folder) -> Void

    var body: some View {
        VStack(spacing: 0) {
            // 顶部 actions：图搜图 / 选择
            HStack(spacing: 14) {
                PhotosPicker(selection: $imageSearchItem, matching: .images) {
                    Image(systemName: "camera.viewfinder")
                        .font(.system(size: 19))
                        .foregroundStyle(PV.caramel)
                        .frame(width: 34, height: 34)
                }
                Spacer()
                if isSelecting {
                    Button {
                        let allIds = Set(vm.allAssetsOrdered.map(\.id))
                        if selectedIds == allIds { selectedIds.removeAll() }
                        else { selectedIds = allIds }
                    } label: {
                        Text(selectedIds.count == vm.allAssetsOrdered.count ? "取消全选" : "全选")
                            .font(PVFont.body(14.5, weight: .medium))
                            .foregroundStyle(PV.caramel)
                    }
                }
                Button {
                    PVLog.perf("Tap \(isSelecting ? "完成" : "选择")")
                    isSelecting.toggle()
                    if !isSelecting { selectedIds.removeAll() }
                } label: {
                    Text(isSelecting ? "完成" : "选择")
                        .font(PVFont.body(14.5, weight: .medium))
                        .foregroundStyle(PV.caramel)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 4)
            .frame(height: 44)

            // 大标题 "素材库" Fraunces 34pt
            HStack {
                Text("素材库")
                    .font(PVFont.display(34, weight: .medium))
                    .foregroundStyle(PV.ink)
                    .kerning(-0.6)
                Spacer()
            }
            .padding(.horizontal, 20)

            // 搜索胶囊
            CSearchPill(text: $vm.searchText, prompt: "搜索素材…") {
                Task { await vm.search() }
            }
            .padding(.horizontal, 20)
            .padding(.top, 10)

            // Tab 切换（时间 / 文件夹）
            CreamSegmented(selection: $viewMode)
                .padding(.horizontal, 20)
                .padding(.top, 12)

            switch viewMode {
            case .timeline:
                GalleryTimelineView(
                    vm: vm,
                    api: appState.api,
                    isSelecting: $isSelecting,
                    selectedIds: $selectedIds,
                    selectedAsset: $selectedAsset,
                    onRecentFolderTap: onRecentFolderTap
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

/// 奶油风格 segmented — 32pt 高，底层米色胶囊，选中白底带软阴影
private struct CreamSegmented: View {
    @Binding var selection: GalleryViewMode

    var body: some View {
        HStack(spacing: 2) {
            ForEach(GalleryViewMode.allCases, id: \.self) { mode in
                let on = selection == mode
                Button { selection = mode } label: {
                    Text(mode.rawValue)
                        .font(PVFont.body(13, weight: .medium))
                        .foregroundStyle(on ? PV.ink : PV.sub)
                        .frame(maxWidth: .infinity)
                        .frame(height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(on ? Color.white : Color.clear)
                                .shadow(color: on ? PV.bean.opacity(0.06) : .clear, radius: 2, y: 1)
                        )
                        .contentShape(Rectangle()) // 让整个 segment 区域都能点击，不只是文字
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .frame(height: 32)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(PV.ink.opacity(0.08))
        )
    }
}

// MARK: - Timeline View

private struct GalleryTimelineView: View {
    @ObservedObject var vm: GalleryViewModel
    let api: APIService
    @Binding var isSelecting: Bool
    @Binding var selectedIds: Set<UUID>
    @Binding var selectedAsset: Asset?
    var onRecentFolderTap: (Folder) -> Void

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
            // 月份快速跳转栏：年 + 月 两行（cream CChip — 焦糖选中）
            if !vm.timeline.isEmpty && vm.searchText.isEmpty && !vm.isImageSearchResult {
                VStack(spacing: 6) {
                    if years.count > 1 {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(years, id: \.self) { y in
                                    Button {
                                        lastManualTap = Date()
                                        selectedYear = y
                                        if let first = vm.timeline.first(where: { $0.month.hasPrefix(y) }) {
                                            activeMonth = first.month
                                            scrollTarget = first.month
                                        }
                                    } label: {
                                        CChip(text: y + "年", active: effectiveYear == y, mono: true)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 20)
                        }
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(monthsOfSelectedYear) { group in
                                Button {
                                    lastManualTap = Date()
                                    activeMonth = group.month
                                    selectedYear = String(group.month.prefix(4))
                                    scrollTarget = group.month
                                } label: {
                                    CChip(text: shortMonthOnly(group.month), active: activeMonth == group.month, mono: true)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 20)
                    }
                }
                .padding(.vertical, 6)
                .background(PV.bg)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    // ★ 问候 + 最近在整理放进 ScrollView 顶部 —— 下滑时一起滑走让出视野
                    //   只在非搜索非图搜图态显示；搜索时页面直接进入结果
                    if vm.searchText.isEmpty && !vm.isImageSearchResult {
                        PandaGreeting()
                            .padding(.horizontal, 20)
                            .padding(.top, 6)
                            .padding(.bottom, 10)
                        if !vm.recentFolders.isEmpty {
                            RecentFoldersCarousel(folders: vm.recentFolders, api: api, onTap: onRecentFolderTap)
                                .padding(.bottom, 8)
                        }
                    }

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
        HStack(alignment: .lastTextBaseline) {
            Text(group.displayMonth)
                .font(PVFont.mono(13, weight: .medium))
                .foregroundStyle(PV.ink)
            Spacer()
            Text("\(group.count)")
                .font(PVFont.mono(11))
                .foregroundStyle(PV.muted)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(PV.bg)
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
        HStack(spacing: 8) {
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
                HStack(spacing: 5) {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: 11, weight: .semibold))
                    Text(sortOption.rawValue)
                        .font(PVFont.body(12, weight: .semibold))
                }
                .foregroundStyle(PV.caramel)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(PV.caramel.opacity(0.13), in: Capsule())
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 6)
    }

    private var foldersGrid: some View {
        LazyVGrid(
            columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
            spacing: 12
        ) {
            ForEach(vm.folders.sorted(by: sortOption)) { folder in
                Button { selectedFolder = folder } label: {
                    FolderCard(folder: folder, api: api)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
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

// MARK: - 熊猫管家问候（Timeline 顶部）

struct PandaGreeting: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var sync = SyncEngine.shared

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        switch h {
        case 5..<11: return "早上好呀～"
        case 11..<14: return "中午好呀～"
        case 14..<18: return "下午好～"
        case 18..<23: return "晚上好～"
        default: return "夜深啦～"
        }
    }

    private var subtitle: String {
        let unsynced = sync.unsyncedCount
        if unsynced == 0 { return "今天的素材都同步好啦" }
        return "相册里还有 \(unsynced) 件没同步"
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            CPandaHi(size: 42)
            VStack(alignment: .leading, spacing: 1) {
                Text(greeting)
                    .font(PVFont.display(22, weight: .medium))
                    .foregroundStyle(PV.ink)
                    .lineLimit(1)
                Text(subtitle)
                    .font(PVFont.body(11.5))
                    .foregroundStyle(PV.sub)
                    .lineLimit(1)
            }
            Spacer()
        }
    }
}

// MARK: - 最近在整理（横滚卡）

struct RecentFoldersCarousel: View {
    let folders: [Folder]
    let api: APIService
    var onTap: (Folder) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("最近在整理")
                    .font(PVFont.sectionHeader)
                    .tracking(1.5)
                    .foregroundStyle(PV.muted)
                Spacer()
            }
            .padding(.horizontal, 20)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(folders) { f in
                        Button { onTap(f) } label: {
                            RecentFolderCard(folder: f, api: api)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 2)
            }
        }
    }
}

private struct RecentFolderCard: View {
    let folder: Folder
    let api: APIService

    private func relativeTime(_ date: Date?) -> String {
        guard let date else { return "—" }
        let s = Int(Date().timeIntervalSince(date))
        if s < 3600 { return "刚刚" }
        if s < 86400 { return "今天" }
        if s < 86400 * 2 { return "昨天" }
        if s < 86400 * 7 { return "\(s / 86400) 天前" }
        let fmt = DateFormatter(); fmt.dateFormat = "M月d日"
        return fmt.string(from: date)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            coverImage
            VStack(alignment: .leading, spacing: 1) {
                Text(folder.name)
                    .font(PVFont.body(11.5, weight: .semibold))
                    .foregroundStyle(PV.ink)
                    .lineLimit(1)
                HStack(spacing: 3) {
                    Text(relativeTime(folder.updatedAt))
                        .font(PVFont.body(9.5))
                        .foregroundStyle(PV.sub)
                    Text("·")
                        .font(PVFont.body(9.5))
                        .foregroundStyle(PV.muted)
                    Text("\(folder.assetCount ?? 0)")
                        .font(PVFont.mono(9.5))
                        .foregroundStyle(PV.sub)
                }
            }
            .padding(.horizontal, 3)
            .padding(.bottom, 2)
        }
        .frame(width: 108)
        .padding(5)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(PV.line, lineWidth: 1)
        )
    }

    @ViewBuilder
    private var coverImage: some View {
        let url = api.folderCoverURL(for: folder)
        Group {
            if let url {
                AsyncImage(url: url) { phase in
                    if let img = phase.image {
                        img.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        PV.muted.opacity(0.15)
                    }
                }
            } else {
                PV.muted.opacity(0.15).overlay(Image(systemName: "folder").foregroundStyle(PV.muted))
            }
        }
        .frame(height: 68)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
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

    // 只放下载进度条（轻量，用 safeAreaInset 合适）。
    // 批量工具栏已经挪到调用方的 .overlay(.bottom)，避开 NavigationStack 吞掉 safeAreaInset 的问题
    var body: some View {
        if !appState.downloadManager.tasks.isEmpty {
            GalleryDownloadProgress(dm: appState.downloadManager)
        }
    }
}

/// 供 GalleryView/FolderDetailView 等用 .overlay(alignment: .bottom) 浮在底部；
/// 它会被 MainTabView 的 CTabBar 往上顶（因为 NavigationStack 的 content 区
/// 就止于 CTabBar 顶边），所以不会重合
struct FloatingBatchBar: View {
    let count: Int
    @Binding var showDeleteConfirm: Bool
    @Binding var showBatchMove: Bool
    let onSave: () -> Void
    let onShare: () -> Void
    /// 可选 —— 有就显示末端"⋯"溢出菜单，点 "导出工程包" 触发
    var onExport: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 0) {
            Text("已选 \(count) 项")
                .font(PVFont.body(10.5, weight: .semibold))
                .foregroundStyle(PV.sub)
                .padding(.top, 10)

            HStack(spacing: 0) {
                barBtn(icon: "square.and.arrow.down", label: "保存", tone: PV.caramel, action: onSave)
                barBtn(icon: "folder.badge.plus",     label: "移动", tone: PV.caramel) { showBatchMove = true }
                barBtn(icon: "square.and.arrow.up",   label: "分享", tone: PV.caramel, action: onShare)
                barBtn(icon: "trash",                 label: "删除", tone: PV.berry)  { showDeleteConfirm = true }
                if let onExport {
                    Menu {
                        Button {
                            onExport()
                        } label: {
                            Label("导出剪辑工程包", systemImage: "shippingbox")
                        }
                    } label: {
                        VStack(spacing: 3) {
                            Image(systemName: "ellipsis").font(.system(size: 18))
                            Text("更多").font(PVFont.body(11, weight: .medium))
                        }
                        .foregroundStyle(PV.sub)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 2)
                    }
                }
            }
            .padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(PV.line, lineWidth: 1)
        )
        .shadow(color: PV.bean.opacity(0.14), radius: 14, y: 4)
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
    }

    private func barBtn(icon: String, label: String, tone: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 18))
                Text(label).font(PVFont.body(11, weight: .medium))
            }
            .foregroundStyle(tone)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 2)
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

// MARK: - Folder Card (Cream 2-col)

struct FolderCard: View {
    let folder: Folder
    let api: APIService

    private func relativeTime(_ date: Date?) -> String {
        guard let date else { return "" }
        let s = Int(Date().timeIntervalSince(date))
        if s < 3600 { return "刚刚" }
        if s < 86400 { return "今天" }
        if s < 86400 * 2 { return "昨天" }
        if s < 86400 * 7 { return "\(s / 86400) 天前" }
        let fmt = DateFormatter(); fmt.dateFormat = "M月d日"
        return fmt.string(from: date)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            folderCover
            VStack(alignment: .leading, spacing: 3) {
                Text(folder.name)
                    .font(PVFont.body(14, weight: .semibold))
                    .foregroundStyle(PV.ink)
                    .kerning(-0.1)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    if folder.assetCount == nil || folder.totalBytes == nil {
                        Text("计算中…")
                            .font(PVFont.mono(11))
                            .foregroundStyle(PV.muted)
                    } else {
                        let when = relativeTime(folder.updatedAt)
                        if !when.isEmpty {
                            Text(when)
                                .font(PVFont.body(11))
                                .foregroundStyle(PV.sub)
                            Text("·")
                                .font(PVFont.body(11))
                                .foregroundStyle(PV.muted.opacity(0.5))
                        }
                        Text("\(folder.assetCount ?? 0)")
                            .font(PVFont.mono(11))
                            .foregroundStyle(PV.sub)
                        if let total = folder.totalBytes, total > 0 {
                            Text("·")
                                .font(PVFont.body(11))
                                .foregroundStyle(PV.muted.opacity(0.5))
                            Text(total.humanReadableBytes)
                                .font(PVFont.mono(11))
                                .foregroundStyle(PV.sub)
                        }
                    }
                }
            }
            .padding(.horizontal, 4)
            .padding(.top, 8)
            .padding(.bottom, 5)
        }
        .padding(6)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(PV.line, lineWidth: 1)
        )
    }

    @ViewBuilder
    private var folderCover: some View {
        if let coverURL = api.folderCoverURL(for: folder) {
            AsyncImage(url: coverURL) { phase in
                if let image = phase.image {
                    image.resizable().aspectRatio(contentMode: .fill)
                } else {
                    PV.muted.opacity(0.12)
                }
            }
            .frame(height: 96)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(PV.muted.opacity(0.12))
                .frame(height: 96)
                .overlay {
                    Image(systemName: "folder")
                        .font(.system(size: 22))
                        .foregroundStyle(PV.muted)
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
