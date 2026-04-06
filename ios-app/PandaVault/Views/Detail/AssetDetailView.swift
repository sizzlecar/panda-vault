import SwiftUI
import AVKit

struct AssetDetailView: View {
    let assets: [Asset]
    let initialAsset: Asset
    let api: APIService
    var onDelete: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var currentIndex: Int
    @State private var showDeleteConfirm = false
    @State private var showSaveAlert = false
    @State private var saveMessage = ""
    @State private var isSaving = false

    init(assets: [Asset], initialAsset: Asset, api: APIService, onDelete: (() -> Void)? = nil) {
        self.assets = assets
        self.initialAsset = initialAsset
        self.api = api
        self.onDelete = onDelete
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
                        FullVideoPlayer(url: api.proxyURL(for: current) ?? api.rawURL(for: current))
                            .id(currentIndex)
                    } else {
                        ZoomableImageView(url: api.rawURL(for: current))
                            .id(currentIndex)
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
        HStack(spacing: 16) {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.body.bold())
                    .padding(10)
                    .background(.ultraThinMaterial, in: Circle())
            }

            if assets.count > 1 {
                Text("\(currentIndex + 1)/\(assets.count)")
                    .font(.caption.monospacedDigit().bold())
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.ultraThinMaterial, in: Capsule())
            }

            Spacer()

            Button { Task { await saveToPhotos(asset) } } label: {
                Image(systemName: "square.and.arrow.down")
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

    // MARK: - Image Bottom Bar

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
        }
        .padding()
        .padding(.bottom, 4)
        .background(.ultraThinMaterial)
    }

    // MARK: - Saving Overlay

    private var savingOverlay: some View {
        Color.black.opacity(0.6).ignoresSafeArea()
            .overlay {
                VStack(spacing: 12) {
                    ProgressView().tint(.white)
                    Text("保存中...").font(.subheadline).foregroundStyle(.white)
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
