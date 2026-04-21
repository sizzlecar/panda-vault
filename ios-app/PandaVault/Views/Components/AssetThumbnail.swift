import SwiftUI

struct AssetThumbnail: View {
    let asset: Asset
    let api: APIService

    @State private var retryId = 0

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Color(.secondarySystemFill)
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    if let url = api.thumbnailURL(for: asset) {
                        AsyncImage(url: url, transaction: Transaction()) { phase in
                            switch phase {
                            case .success(let image):
                                image
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                            case .failure:
                                Button {
                                    retryId += 1
                                } label: {
                                    VStack(spacing: 4) {
                                        Image(systemName: asset.isVideo ? "video" : "photo")
                                        Image(systemName: "arrow.clockwise")
                                            .font(.system(size: 10))
                                    }
                                    .foregroundStyle(.tertiary)
                                }
                            default:
                                ProgressView().tint(PV.cyan)
                            }
                        }
                        .id(retryId)
                    } else {
                        // 缩略图还没生成（新上传/转码中）
                        VStack(spacing: 4) {
                            Image(systemName: asset.isVideo ? "film" : "photo")
                                .font(.title2)
                                .foregroundStyle(.secondary)
                            Text("处理中")
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .clipped()

            if asset.isVideo {
                HStack(spacing: 3) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 8))
                    if let dur = asset.formattedDuration {
                        Text(dur)
                            .font(.system(.caption2, design: .monospaced))
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Color.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 2))
                .padding(4)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 2))
        .contentShape(Rectangle())
    }
}
