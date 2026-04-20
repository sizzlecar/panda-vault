import SwiftUI

struct DiskInfoView: View {
    let api: APIService

    @State private var volumes: [VolumeInfo] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        List {
            if let err = errorMessage {
                Section {
                    Label(err, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(PV.pink)
                        .font(.system(.caption, design: .monospaced))
                }
            }

            if !volumes.isEmpty {
                Section {
                    HStack(spacing: 0) {
                        statBlock(label: "卷数", value: "\(volumes.count)", color: PV.cyan)
                        Divider().frame(height: 36)
                        statBlock(label: "媒体库占用", value: aggregateAssets, color: PV.pink)
                        Divider().frame(height: 36)
                        statBlock(label: "资产数", value: "\(aggregateAssetCount)", color: PV.green)
                    }
                    .padding(.vertical, 6)
                } header: {
                    PixelSectionHeader(title: "汇总")
                }
            }

            ForEach(volumes) { vol in
                Section {
                    volumeBody(vol)
                } header: {
                    HStack {
                        Text(vol.label).font(.system(.caption, design: .monospaced).bold())
                        Spacer()
                        if vol.isDefault {
                            PixelTag(text: "默认", color: PV.cyan)
                        }
                        if !vol.isActive {
                            PixelTag(text: "停用", color: PV.pink)
                        }
                        if vol.isLowSpace {
                            PixelTag(text: "空间不足", color: PV.pink)
                        }
                    }
                } footer: {
                    Text("「整盘已用」包含 macOS 系统、其他应用占用；「媒体库占用」只统计本应用导入的资产。剩余 ≤ \(vol.minFreeBytes.humanReadableBytes) 时停止写入这块卷。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            if volumes.isEmpty && !isLoading && errorMessage == nil {
                Section {
                    Text("没有存储卷")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)
                }
            }
        }
        .navigationTitle("磁盘信息")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await load() }
                } label: {
                    if isLoading {
                        ProgressView().tint(PV.cyan)
                    } else {
                        Image(systemName: "arrow.clockwise").foregroundStyle(PV.cyan)
                    }
                }
                .disabled(isLoading)
            }
        }
        .task { await load() }
        .refreshable { await load() }
    }

    // MARK: - Cell

    @ViewBuilder
    private func volumeBody(_ vol: VolumeInfo) -> some View {
        // 路径
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "folder")
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            Text(vol.basePath)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }

        // —— 本应用占用 ——
        metricRow(label: "媒体库占用", value: vol.usedByAssets.humanReadableBytes, color: PV.pink)
        metricRow(label: "资产数", value: "\(vol.assetCount)", color: PV.cyan)

        // —— 整盘 ——
        if let total = vol.totalBytes {
            metricRow(label: "整盘容量", value: total.humanReadableBytes, color: PV.green)
        }
        if let used = vol.diskUsedBytes {
            metricRow(label: "整盘已用", value: used.humanReadableBytes, color: PV.orange)
        }
        if let free = vol.freeBytes {
            metricRow(label: "整盘剩余", value: free.humanReadableBytes, color: vol.isLowSpace ? PV.pink : PV.cyan)
        }

        // 整盘使用率进度条
        if let pct = vol.diskUsagePercent {
            VStack(alignment: .leading, spacing: 4) {
                PixelProgressBar(progress: pct, color: pct > 0.9 ? PV.pink : (pct > 0.7 ? PV.orange : PV.cyan))
                Text("整盘 \(Int(pct * 100))% 已使用")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
        }
    }

    private func metricRow(label: String, value: String, color: Color) -> some View {
        HStack {
            Text(label)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
            Spacer()
            PixelTag(text: value, color: color)
        }
    }

    private func statBlock(label: String, value: String, color: Color) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(.subheadline, design: .monospaced).bold())
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Aggregates

    private var aggregateAssets: String {
        let sum: Int64 = volumes.reduce(0) { $0 + $1.usedByAssets }
        return sum > 0 ? sum.humanReadableBytes : "0 B"
    }

    private var aggregateAssetCount: Int64 {
        volumes.reduce(0) { $0 + $1.assetCount }
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
