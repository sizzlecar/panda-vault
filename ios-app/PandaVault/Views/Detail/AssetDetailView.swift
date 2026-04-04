import SwiftUI
import AVKit

struct AssetDetailView: View {
    let assets: [Asset]
    let initialAsset: Asset
    let api: APIService

    @Environment(\.dismiss) private var dismiss
    @State private var currentIndex: Int
    @State private var showDeleteConfirm = false
    @State private var showSaveAlert = false
    @State private var saveMessage = ""
    @State private var isSaving = false
    @State private var saveProgress: Double = 0

    init(assets: [Asset], initialAsset: Asset, api: APIService) {
        self.assets = assets
        self.initialAsset = initialAsset
        self.api = api
        _currentIndex = State(initialValue: max(0, assets.firstIndex(of: initialAsset) ?? 0))
    }

    private var current: Asset? {
        guard currentIndex >= 0, currentIndex < assets.count else { return nil }
        return assets[currentIndex]
    }

    var body: some View {
        ZStack {
            PV.bg.ignoresSafeArea()

            if let current {
                TabView(selection: $currentIndex) {
                    ForEach(Array(assets.enumerated()), id: \.element.id) { index, asset in
                        Group {
                            if asset.isVideo {
                                FullVideoPlayer(url: api.proxyURL(for: asset) ?? api.downloadURL(for: asset))
                            } else {
                                ZoomableImageView(url: api.thumbnailURL(for: asset))
                            }
                        }
                        .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .ignoresSafeArea()

                // 顶部
                VStack {
                    HStack {
                        Button { dismiss() } label: {
                            Image(systemName: "xmark")
                                .font(.body.bold())
                                .foregroundStyle(.white)
                                .frame(width: 36, height: 36)
                                .background(PV.bg.opacity(0.6), in: RoundedRectangle(cornerRadius: 3))
                        }
                        Spacer()
                        Text("\(currentIndex + 1)/\(assets.count)")
                            .font(.system(.caption2, design: .monospaced).bold())
                            .foregroundStyle(PV.textSecondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(PV.bg.opacity(0.6), in: RoundedRectangle(cornerRadius: 3))
                        Spacer()
                        Button { showDeleteConfirm = true } label: {
                            Image(systemName: "trash")
                                .font(.body)
                                .foregroundStyle(PV.pink)
                                .frame(width: 36, height: 36)
                                .background(PV.bg.opacity(0.6), in: RoundedRectangle(cornerRadius: 3))
                        }
                    }
                    .padding(.horizontal)
                    .padding(.top, 8)

                    Spacer()

                    // 底部
                    VStack(spacing: 8) {
                        // 文件信息
                        HStack(spacing: 12) {
                            Text(current.filename)
                                .lineLimit(1)
                            Spacer()
                            Text(current.formattedSize)
                            if let res = current.resolution { Text(res) }
                            if let dur = current.formattedDuration { Text(dur) }
                        }
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(PV.textMuted)

                        // 保存按钮
                        Button {
                            Task { await saveToPhotos(current) }
                        } label: {
                            HStack {
                                Image(systemName: "square.and.arrow.down")
                                Text("SAVE TO ALBUM")
                            }
                            .font(.system(.caption, design: .monospaced).bold())
                            .tracking(1)
                            .foregroundStyle(PV.bg)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
                            .background(PV.green, in: RoundedRectangle(cornerRadius: 3))
                        }
                    }
                    .padding()
                    .padding(.bottom, 4)
                    .background(
                        LinearGradient(colors: [.clear, PV.bg.opacity(0.8)], startPoint: .top, endPoint: .bottom)
                            .ignoresSafeArea(edges: .bottom)
                    )
                }

                if isSaving {
                    PV.bg.opacity(0.7).ignoresSafeArea()
                    VStack(spacing: 12) {
                        ProgressView().tint(PV.cyan)
                        Text("SAVING...")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(PV.textSecondary)
                    }
                }
            }
        }
        .confirmationDialog("确定删除？", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("删除", role: .destructive) { Task { await deleteCurrent() } }
        }
        .alert("保存", isPresented: $showSaveAlert) {
            Button("OK") {}
        } message: {
            Text(saveMessage)
        }
    }

    private func saveToPhotos(_ asset: Asset) async {
        isSaving = true
        defer { isSaving = false }
        do {
            let tempURL = try await api.downloadAsset(id: asset.id) { p in
                Task { @MainActor in saveProgress = p }
            }
            defer { try? FileManager.default.removeItem(at: tempURL) }
            if asset.isVideo {
                try await PhotoLibraryService.saveVideoToAlbum(fileURL: tempURL)
            } else {
                try await PhotoLibraryService.saveImageToAlbum(fileURL: tempURL)
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
            dismiss()
        } catch { print("[PandaVault] Error: \(error)") }
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
                Image(systemName: "photo")
                    .font(.largeTitle)
                    .foregroundStyle(PV.textMuted)
            } else {
                ProgressView().tint(PV.cyan)
            }
        }
    }
}
