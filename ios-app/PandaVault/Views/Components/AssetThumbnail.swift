import SwiftUI

struct AssetThumbnail: View {
    let asset: Asset
    let api: APIService

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            PV.surfaceBg
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    AsyncImage(url: api.thumbnailURL(for: asset)) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        case .failure:
                            Image(systemName: asset.isVideo ? "video" : "photo")
                                .foregroundStyle(PV.textMuted)
                        default:
                            ProgressView().tint(PV.cyan)
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
                .background(PV.bg.opacity(0.8), in: RoundedRectangle(cornerRadius: 2))
                .padding(4)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 2))
    }
}
