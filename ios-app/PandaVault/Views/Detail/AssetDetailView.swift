import SwiftUI
import AVKit

struct AssetDetailView: View {
    let initialAsset: Asset
    let api: APIService
    var onDelete: (() -> Void)?
    /// 单个资产字段被修改（重命名 / 备注等）后回调，父视图用来同步缓存
    /// —— 避免详情页关闭后再打开看到旧数据
    var onAssetUpdated: ((Asset) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var assets: [Asset]
    @State private var currentIndex: Int
    @State private var showDeleteConfirm = false
    @State private var showSaveAlert = false
    @State private var saveMessage = ""
    @State private var isSaving = false
    @State private var showMovePicker = false
    @State private var showMoveAlert = false
    @State private var showShareSheet = false
    @State private var shareFileURL: URL?
    @State private var moveMessage = ""
    @State private var showNoteEditor = false

    init(
        assets: [Asset],
        initialAsset: Asset,
        api: APIService,
        onDelete: (() -> Void)? = nil,
        onAssetUpdated: ((Asset) -> Void)? = nil
    ) {
        self.initialAsset = initialAsset
        self.api = api
        self.onDelete = onDelete
        self.onAssetUpdated = onAssetUpdated
        _assets = State(initialValue: assets)
        _currentIndex = State(initialValue: max(0, assets.firstIndex(of: initialAsset) ?? 0))
    }

    private var current: Asset? {
        guard currentIndex >= 0, currentIndex < assets.count else { return nil }
        return assets[currentIndex]
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let current {
                // 当前内容
                Group {
                    if current.isVideo {
                        let videoURL = api.proxyURL(for: current) ?? api.rawURL(for: current)
                        FullVideoPlayer(url: videoURL)
                            .id("\(currentIndex)_\(current.filePath)")
                            .onAppear { PVLog.mem("打开视频: \(current.filename) size=\(current.sizeBytes) url=\(videoURL?.absoluteString ?? "nil")") }
                    } else {
                        let imageURL = api.rawURL(for: current)
                        ZoomableImageView(url: imageURL)
                            .id("\(currentIndex)_\(current.filePath)")
                            .onAppear { PVLog.mem("打开图片: \(current.filename) size=\(current.sizeBytes) url=\(imageURL?.absoluteString ?? "nil")") }
                    }
                }
                .ignoresSafeArea()

                if current.isVideo {
                    // 视频：底部浮动栏（不遮挡系统播放器顶部控件）
                    VStack {
                        Spacer()
                        videoBottomBar(current)
                    }
                } else {
                    // 图片：顶部 + 底部按钮
                    VStack {
                        topButtons(current)
                            .padding(.top, 50)
                        Spacer()
                        imageBottomBar(current)
                    }
                }

                // 左右切换箭头
                if assets.count > 1 {
                    HStack(spacing: 0) {
                        // 上一张
                        Button {
                            if currentIndex > 0 { withAnimation { currentIndex -= 1 } }
                        } label: {
                            Color.clear.frame(width: 44)
                                .overlay(alignment: .center) {
                                    if currentIndex > 0 {
                                        Image(systemName: "chevron.left")
                                            .font(.title2.bold())
                                            .foregroundStyle(.white.opacity(0.6))
                                            .padding(8)
                                            .background(.black.opacity(0.3), in: Circle())
                                    }
                                }
                        }
                        Spacer()
                        // 下一张
                        Button {
                            if currentIndex < assets.count - 1 { withAnimation { currentIndex += 1 } }
                        } label: {
                            Color.clear.frame(width: 44)
                                .overlay(alignment: .center) {
                                    if currentIndex < assets.count - 1 {
                                        Image(systemName: "chevron.right")
                                            .font(.title2.bold())
                                            .foregroundStyle(.white.opacity(0.6))
                                            .padding(8)
                                            .background(.black.opacity(0.3), in: Circle())
                                    }
                                }
                        }
                    }
                    .padding(.vertical, 200)
                }

                if isSaving { savingOverlay }
            }
        }
        .confirmationDialog("确定删除？", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("删除", role: .destructive) { Task { await deleteCurrent() } }
        }
        .alert("", isPresented: $showSaveAlert) {
            Button("好") {}
        } message: {
            Text(saveMessage)
        }
        .alert("", isPresented: $showMoveAlert) {
            Button("好") {}
        } message: {
            Text(moveMessage)
        }
        .sheet(isPresented: $showMovePicker) {
            if let asset = current {
                MoveToFolderView(api: api, asset: asset) { message in
                    moveMessage = message
                    showMoveAlert = true
                    // 移动后刷新资产数据（file_path 已变更）
                    Task {
                        if let updated = try? await api.getAsset(id: asset.id) {
                            if let idx = assets.firstIndex(where: { $0.id == asset.id }) {
                                assets[idx] = updated
                            }
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showShareSheet) {
            if let url = shareFileURL {
                ActivityView(items: [url])
            }
        }
        .sheet(isPresented: $showNoteEditor) {
            if let asset = current {
                NoteEditorSheet(asset: asset, api: api) { updated in
                    assets[currentIndex] = updated
                    onAssetUpdated?(updated) // 同步父视图缓存，避免关闭后重打开丢失 note
                }
            }
        }
    }

    // MARK: - Top Buttons

    private func topButtons(_ asset: Asset) -> some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.body.bold())
                    .padding(10)
                    .background(.ultraThinMaterial, in: Circle())
            }
            Spacer()
            if assets.count > 1 {
                Text("\(currentIndex + 1)/\(assets.count)")
                    .font(.caption.monospacedDigit().bold())
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            Spacer()
            Button { showDeleteConfirm = true } label: {
                Image(systemName: "trash")
                    .font(.body)
                    .foregroundStyle(.red)
                    .padding(10)
                    .background(.ultraThinMaterial, in: Circle())
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal)
        .padding(.top, 8)
    }

    // MARK: - Video Bottom Bar

    private func videoBottomBar(_ asset: Asset) -> some View {
        VStack(spacing: 8) {
            // 视频信息行
            HStack(spacing: 8) {
                let date = asset.shootAt ?? asset.createdAt
                Text(Self.dateFormatter.string(from: date))
                if let dur = asset.formattedDuration { Text(dur) }
                Text(asset.formattedSize)
                Spacer()
                if assets.count > 1 {
                    Text("\(currentIndex + 1)/\(assets.count)")
                }
            }
            .font(.system(.caption2, design: .monospaced))
            .foregroundStyle(.white.opacity(0.7))

            // 按钮行
            HStack(spacing: 16) {
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.body.bold())
                        .padding(10)
                        .background(.ultraThinMaterial, in: Circle())
                }

                Spacer()

            Button { Task { await saveToPhotos(asset) } } label: {
                Image(systemName: "square.and.arrow.down")
                    .font(.body)
                    .padding(10)
                    .background(.ultraThinMaterial, in: Circle())
            }

            Button { Task { await shareAsset(asset) } } label: {
                Image(systemName: "square.and.arrow.up")
                    .font(.body)
                    .padding(10)
                    .background(.ultraThinMaterial, in: Circle())
            }

            Button { showMovePicker = true } label: {
                Image(systemName: "folder.badge.plus")
                    .font(.body)
                    .padding(10)
                    .background(.ultraThinMaterial, in: Circle())
            }

            Button { showDeleteConfirm = true } label: {
                Image(systemName: "trash")
                    .font(.body)
                    .foregroundStyle(.red)
                    .padding(10)
                    .background(.ultraThinMaterial, in: Circle())
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal)
        .padding(.bottom, 8)
        }
    }

    // MARK: - Image Bottom Bar

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    private func imageBottomBar(_ asset: Asset) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Text(asset.filename).lineLimit(1)
                Spacer()
                Text(asset.formattedSize)
                if let res = asset.resolution { Text(res) }
            }
            .font(.caption2)
            .foregroundStyle(.white.opacity(0.8))

            HStack(spacing: 12) {
                Image(systemName: "clock")
                let date = asset.shootAt ?? asset.createdAt
                Text(Self.dateFormatter.string(from: date))
                if asset.shootAt != nil {
                    Text("拍摄")
                }
                Spacer()
            }
            .font(.caption2)
            .foregroundStyle(.white.opacity(0.6))

            // ★ 备注条（有内容展示，点击编辑；无内容显示 "+ 添加备注"）
            Button { showNoteEditor = true } label: {
                noteStrip(asset)
            }
            .buttonStyle(.plain)

            HStack(spacing: 10) {
                Button { Task { await saveToPhotos(asset) } } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "square.and.arrow.down")
                        Text("保存到相册")
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(.white.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
                }

                Button { Task { await shareAsset(asset) } } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "square.and.arrow.up")
                        Text("分享")
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(.white.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
                }

                Button { showMovePicker = true } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "folder.badge.plus")
                        Text("移动")
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(.white.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
                }
            }
        }
        .padding()
        .padding(.bottom, 4)
        .background(.ultraThinMaterial)
        .environment(\.colorScheme, .dark)
    }

    private func noteStrip(_ asset: Asset) -> some View {
        HStack(alignment: .top, spacing: 8) {
            if let note = asset.note, !note.isEmpty {
                Text("✍️")
                    .font(.system(size: 14))
                VStack(alignment: .leading, spacing: 2) {
                    Text(note)
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.92))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text("编辑备注 ›")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.5))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Image(systemName: "plus.bubble")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.6))
                Text("添加备注")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.white.opacity(0.6))
                Spacer()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - Saving Overlay

    private var savingOverlay: some View {
        Color.black.opacity(0.6).ignoresSafeArea()
            .overlay {
                VStack(spacing: 12) {
                    ProgressView().tint(.white)
                    Text("下载中...").font(.subheadline).foregroundStyle(.white)
                    if let asset = current {
                        Text(asset.formattedSize)
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
            }
    }

    // MARK: - Actions

    private func saveToPhotos(_ asset: Asset) async {
        isSaving = true
        defer { isSaving = false }
        do {
            let tempURL = try await api.downloadAsset(id: asset.id) { _ in }
            let ext = (asset.filename as NSString).pathExtension.lowercased()
            let destURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(ext.isEmpty ? "jpg" : ext)
            try FileManager.default.moveItem(at: tempURL, to: destURL)
            defer { try? FileManager.default.removeItem(at: destURL) }

            if asset.isVideo {
                try await PhotoLibraryService.saveVideoToAlbum(fileURL: destURL)
            } else {
                try await PhotoLibraryService.saveImageToAlbum(fileURL: destURL)
            }
            saveMessage = "已保存到相册"
        } catch {
            saveMessage = "保存失败: \(error.localizedDescription)"
        }
        showSaveAlert = true
    }

    private func deleteCurrent() async {
        guard let asset = current else { return }
        do {
            try await api.deleteAsset(id: asset.id)
            onDelete?()
            dismiss()
        } catch { print("[PandaVault] Delete error: \(error)") }
    }

    private func shareAsset(_ asset: Asset) async {
        isSaving = true
        defer { isSaving = false }
        do {
            let tempURL = try await api.downloadAsset(id: asset.id) { _ in }
            let ext = (asset.filename as NSString).pathExtension
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent(asset.filename.isEmpty ? UUID().uuidString : asset.filename)
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.moveItem(at: tempURL, to: dest)
            shareFileURL = dest
            showShareSheet = true
        } catch {
            saveMessage = "下载失败: \(error.localizedDescription)"
            showSaveAlert = true
        }
    }
}

// MARK: - Move to Folder

struct MoveToFolderView: View {
    let api: APIService
    let assetIds: [UUID]
    var onComplete: ((String) -> Void)?

    init(api: APIService, asset: Asset, onComplete: ((String) -> Void)? = nil) {
        self.api = api
        self.assetIds = [asset.id]
        self.onComplete = onComplete
    }

    init(api: APIService, assetIds: [UUID], onComplete: ((String) -> Void)? = nil) {
        self.api = api
        self.assetIds = assetIds
        self.onComplete = onComplete
    }

    @Environment(\.dismiss) private var dismiss
    @State private var isMoving = false

    var body: some View {
        NavigationStack {
            MoveFolderLevel(api: api, parentId: nil, parentFolder: nil, pathPrefix: "/", assetIds: assetIds, isMoving: $isMoving) { folder in
                Task { await moveToFolder(folder) }
            }
            .navigationTitle("移动到文件夹")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }

    private func moveToFolder(_ folder: Folder) async {
        isMoving = true
        defer { isMoving = false }
        do {
            for id in assetIds {
                try await api.addAssetToFolder(folderId: folder.id, assetId: id)
            }
            dismiss()
            let count = assetIds.count
            onComplete?(count == 1 ? "已移动到「\(folder.name)」" : "\(count) 个文件已移动到「\(folder.name)」")
        } catch {
            dismiss()
            onComplete?("移动失败: \(error.localizedDescription)")
        }
    }
}

// MARK: - Move Folder Level (hierarchical)

private struct MoveFolderLevel: View {
    let api: APIService
    let parentId: UUID?
    let parentFolder: Folder?
    let pathPrefix: String
    let assetIds: [UUID]
    @Binding var isMoving: Bool
    let onSelect: (Folder) -> Void

    @State private var folders: [Folder] = []
    @State private var isLoading = false
    @State private var drillFolder: Folder?

    var body: some View {
        List {
            if let parentFolder {
                Button {
                    onSelect(parentFolder)
                } label: {
                    HStack {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(PV.cyan)
                        Text("移动到此处").foregroundStyle(PV.cyan).fontWeight(.medium)
                        Spacer()
                        if isMoving { ProgressView().tint(PV.cyan) }
                    }
                }
                .disabled(isMoving)
            }

            if isLoading {
                HStack { Spacer(); ProgressView().tint(PV.cyan); Spacer() }
            }

            ForEach(folders) { folder in
                HStack {
                    Button {
                        onSelect(folder)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "folder.fill").foregroundStyle(PV.cyan)
                            Text(folder.name).foregroundStyle(.primary)
                            if let count = folder.assetCount, count > 0 {
                                Text("\(count)")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .buttonStyle(.borderless)
                    .disabled(isMoving)

                    Spacer()

                    Button {
                        drillFolder = folder
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.borderless)
                    .frame(width: 30)
                }
            }
        }
        .navigationDestination(item: $drillFolder) { folder in
            MoveFolderLevel(
                api: api,
                parentId: folder.id,
                parentFolder: folder,
                pathPrefix: "\(pathPrefix)\(folder.name)/",
                assetIds: assetIds,
                isMoving: $isMoving,
                onSelect: onSelect
            )
            .navigationTitle(folder.name)
        }
        .task {
            isLoading = true
            defer { isLoading = false }
            do {
                folders = try await api.getFolders(parentId: parentId)
            } catch {
                print("[PandaVault] Load folders error: \(error)")
            }
        }
    }
}

// MARK: - Native Video Player

struct FullVideoPlayer: UIViewControllerRepresentable {
    let url: URL?
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        vc.allowsPictureInPicturePlayback = true
        vc.showsPlaybackControls = true
        vc.videoGravity = .resizeAspect
        if let url {
            let player = AVPlayer(url: url)
            vc.player = player
            player.play()
        }
        return vc
    }
    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {}
    static func dismantleUIViewController(_ vc: AVPlayerViewController, coordinator: ()) {
        vc.player?.pause()
        vc.player?.replaceCurrentItem(with: nil)
        vc.player = nil
    }
}

// MARK: - Zoomable Image

struct ZoomableImageView: View {
    let url: URL?
    @State private var scale: CGFloat = 1.0

    var body: some View {
        AsyncImage(url: url) { phase in
            if let image = phase.image {
                image
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .scaleEffect(scale)
                    .gesture(
                        MagnifyGesture()
                            .onChanged { value in scale = value.magnification }
                            .onEnded { _ in withAnimation { scale = max(1.0, min(scale, 5.0)) } }
                    )
                    .onTapGesture(count: 2) {
                        withAnimation { scale = scale > 1 ? 1 : 3 }
                    }
            } else if phase.error != nil {
                Image(systemName: "photo").font(.largeTitle).foregroundStyle(.white.opacity(0.3))
            } else {
                ProgressView().tint(.white)
            }
        }
    }
}

// MARK: - 备注编辑 Sheet（对应 cream.jsx 的 Asset.note 编辑流）

struct NoteEditorSheet: View {
    let asset: Asset
    let api: APIService
    var onSaved: (Asset) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var isSaving = false
    @State private var errorMessage: String?
    @FocusState private var focused: Bool

    init(asset: Asset, api: APIService, onSaved: @escaping (Asset) -> Void) {
        self.asset = asset
        self.api = api
        self.onSaved = onSaved
        _text = State(initialValue: asset.note ?? "")
    }

    var body: some View {
        NavigationStack {
            ZStack {
                PV.bg.ignoresSafeArea()
                VStack(spacing: 14) {
                    Text(asset.filename)
                        .font(PVFont.mono(12))
                        .foregroundStyle(PV.sub)
                        .lineLimit(1)
                        .padding(.top, 4)

                    TextEditor(text: $text)
                        .font(PVFont.body(15))
                        .scrollContentBackground(.hidden)
                        .padding(10)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(PV.line, lineWidth: 1)
                        )
                        .frame(maxHeight: 200)
                        .focused($focused)

                    if let err = errorMessage {
                        Text(err)
                            .font(PVFont.body(12))
                            .foregroundStyle(PV.berry)
                    }

                    Text("给这张素材加个简短备注 — 方便日后剪辑时快速识别用途。")
                        .font(PVFont.body(11))
                        .foregroundStyle(PV.sub)
                        .multilineTextAlignment(.center)

                    Spacer()

                    Button {
                        Task { await save() }
                    } label: {
                        if isSaving { ProgressView().tint(.white) }
                        else { Text("保存") }
                    }
                    .buttonStyle(CButtonStyle(tone: PV.caramel, filled: true, height: 46))
                    .disabled(isSaving)
                }
                .padding(20)
            }
            .navigationTitle("编辑备注")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .onAppear { focused = true }
        }
    }

    private func save() async {
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            let updated = try await api.updateAsset(id: asset.id, note: text)
            onSaved(updated)
            dismiss()
        } catch {
            errorMessage = "保存失败：\(error.localizedDescription)"
        }
    }
}
