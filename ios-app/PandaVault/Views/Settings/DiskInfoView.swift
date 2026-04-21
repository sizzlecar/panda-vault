import SwiftUI

// 奶油软萌风 · 对应 design/cream.jsx CreamDiskInfo
struct DiskInfoView: View {
    let api: APIService

    @State private var volumes: [VolumeInfo] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                if let err = errorMessage {
                    Text(err)
                        .font(PVFont.body(13))
                        .foregroundStyle(PV.berry)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(PV.berry.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .padding(.horizontal, 20)
                }

                if !volumes.isEmpty {
                    summaryHeroCard
                }

                ForEach(volumes) { vol in
                    volumeCard(vol)
                }

                if volumes.isEmpty && !isLoading && errorMessage == nil {
                    Text("没有存储卷")
                        .font(PVFont.body(13))
                        .foregroundStyle(PV.muted)
                        .padding(.vertical, 40)
                }

                Spacer(minLength: 30)
            }
            .padding(.vertical, 14)
        }
        .background(PV.bg.ignoresSafeArea())
        .toolbarBackground(PV.bg, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .navigationTitle("磁盘信息")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await load() }
                } label: {
                    if isLoading {
                        ProgressView().tint(PV.caramel)
                    } else {
                        Image(systemName: "arrow.clockwise").foregroundStyle(PV.caramel)
                    }
                }
                .disabled(isLoading)
            }
        }
        .task { await load() }
        .refreshable { await load() }
    }

    // MARK: - Summary hero（Fraunces 大数字）

    private var summaryHeroCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .lastTextBaseline, spacing: 10) {
                Text(aggregateAssetsBytes.humanReadableBytes)
                    .font(PVFont.display(42, weight: .medium))
                    .foregroundStyle(PV.ink)
                    .kerning(-0.8)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text("媒体库占用")
                    .font(PVFont.body(11.5))
                    .foregroundStyle(PV.sub)
                    .padding(.bottom, 6)
                Spacer()
            }

            HStack(spacing: 14) {
                heroStat(label: "卷", value: "\(volumes.count)", tone: PV.caramel)
                Rectangle().fill(PV.divider).frame(width: 1, height: 24)
                heroStat(label: "资产数", value: "\(aggregateAssetCount)", tone: PV.mint)
                Rectangle().fill(PV.divider).frame(width: 1, height: 24)
                heroStat(label: "整盘已用", value: aggregateDiskUsed, tone: PV.peach)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(PV.line, lineWidth: 1)
        )
        .padding(.horizontal, 20)
    }

    private func heroStat(label: String, value: String, tone: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(PVFont.mono(14, weight: .medium))
                .foregroundStyle(tone)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(PVFont.body(11))
                .foregroundStyle(PV.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Volume Card

    @ViewBuilder
    private func volumeCard(_ vol: VolumeInfo) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header: 卷名 + tags
            HStack(spacing: 8) {
                Text(vol.label)
                    .font(PVFont.display(18, weight: .semibold))
                    .foregroundStyle(PV.ink)
                Spacer()
                if vol.isDefault { tag("默认", tone: PV.caramel) }
                if !vol.isActive { tag("停用", tone: PV.berry) }
                if vol.isLowSpace { tag("空间不足", tone: PV.berry) }
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 10)

            // 路径
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: "folder")
                    .font(.system(size: 12))
                    .foregroundStyle(PV.muted)
                    .padding(.top, 2)
                Text(vol.basePath)
                    .font(PVFont.mono(11))
                    .foregroundStyle(PV.sub)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 12)

            // 媒体库占用 + 资产数
            HStack(spacing: 10) {
                metricCell(label: "媒体库占用", value: vol.usedByAssets.humanReadableBytes, tone: PV.berry)
                metricCell(label: "资产数", value: "\(vol.assetCount)", tone: PV.mint)
            }
            .padding(.horizontal, 18)

            Rectangle().fill(PV.divider).frame(height: 0.5).padding(.top, 14).padding(.bottom, 12)

            // 整盘
            VStack(spacing: 8) {
                if let total = vol.totalBytes {
                    diskLine(label: "整盘容量", value: total.humanReadableBytes)
                }
                if let used = vol.diskUsedBytes {
                    diskLine(label: "整盘已用", value: used.humanReadableBytes)
                }
                if let free = vol.freeBytes {
                    diskLine(
                        label: "整盘剩余",
                        value: free.humanReadableBytes,
                        tone: vol.isLowSpace ? PV.berry : PV.ink
                    )
                }
            }
            .padding(.horizontal, 18)

            // 使用率
            if let pct = vol.diskUsagePercent {
                VStack(alignment: .leading, spacing: 6) {
                    CProgressBar(
                        progress: pct,
                        color: pct > 0.9 ? PV.berry : (pct > 0.7 ? PV.peach : PV.caramel),
                        height: 5
                    )
                    Text("整盘 \(Int(pct * 100))% 已使用")
                        .font(PVFont.body(11))
                        .foregroundStyle(PV.sub)
                }
                .padding(.horizontal, 18)
                .padding(.top, 12)
            }

            // Footer
            Text("「整盘」包括 macOS 系统和其他 app 的占用；「媒体库占用」只统计本应用导入的资产。剩余 ≤ \(vol.minFreeBytes.humanReadableBytes) 时停止写入这块卷。")
                .font(PVFont.body(10.5))
                .foregroundStyle(PV.sub)
                .lineSpacing(2)
                .padding(.horizontal, 18)
                .padding(.top, 12)
                .padding(.bottom, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(PV.line, lineWidth: 1)
        )
        .padding(.horizontal, 20)
    }

    private func metricCell(label: String, value: String, tone: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(PVFont.body(11))
                .foregroundStyle(PV.muted)
            Text(value)
                .font(PVFont.mono(14, weight: .medium))
                .foregroundStyle(tone)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tone.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func diskLine(label: String, value: String, tone: Color = PV.ink) -> some View {
        HStack {
            Text(label)
                .font(PVFont.body(13))
                .foregroundStyle(PV.sub)
            Spacer()
            Text(value)
                .font(PVFont.mono(13))
                .foregroundStyle(tone)
        }
    }

    private func tag(_ text: String, tone: Color) -> some View {
        Text(text)
            .font(PVFont.body(10.5, weight: .semibold))
            .foregroundStyle(tone)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(tone.opacity(0.15), in: Capsule())
    }

    // MARK: - Aggregates

    private var aggregateAssetsBytes: Int64 {
        volumes.reduce(0) { $0 + $1.usedByAssets }
    }

    private var aggregateAssetCount: Int64 {
        volumes.reduce(0) { $0 + $1.assetCount }
    }

    private var aggregateDiskUsed: String {
        let used = volumes.compactMap(\.diskUsedBytes).reduce(0, +)
        return used > 0 ? used.humanReadableBytes : "—"
    }

    // MARK: - Load

    private func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            volumes = try await api.getVolumes()
        } catch {
            errorMessage = "加载失败: \(error.localizedDescription)"
        }
    }
}
