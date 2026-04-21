import SwiftUI

/// 剪辑工程包导出 —— cream sheet
/// 场景：Gallery / FolderDetail 选一批资产 → 批量栏 ⋯ → 导出剪辑工程包
/// 后端生成 zip（无上限，支持 GB 级），Mac 用户在 Finder 里直接打开 exports/ 目录即可用
struct ExportSheet: View {
    let api: APIService
    let assetIds: [UUID]

    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    @State private var name = ""
    @State private var isExporting = false
    @State private var result: ExportInfo?
    @State private var errorMsg: String?

    var body: some View {
        ZStack {
            PV.bg.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 16) {
                header
                if let result {
                    successView(info: result)
                } else {
                    inputView
                }
                Spacer()
                bottomCTA
            }
            .padding(20)
        }
        .presentationDetents([.medium, .large])
        .onAppear {
            // 填个默认名（当前年月日）方便用户直接点导出
            let df = DateFormatter()
            df.dateFormat = "yyyyMMdd"
            name = "剪辑_\(df.string(from: Date()))"
            if result == nil { focused = true }
        }
    }

    // MARK: - Parts

    private var header: some View {
        HStack {
            Text(result == nil ? "导出剪辑工程包" : "导出完成")
                .font(PVFont.display(22, weight: .medium))
                .foregroundStyle(PV.ink)
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(PV.sub)
                    .frame(width: 30, height: 30)
                    .background(PV.ink.opacity(0.06), in: Circle())
            }
        }
        .padding(.top, 2)
    }

    private var inputView: some View {
        VStack(alignment: .leading, spacing: 14) {
            // 素材数预览
            HStack(spacing: 8) {
                Image(systemName: "photo.stack")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(PV.caramel)
                Text("将打包 \(assetIds.count) 个素材")
                    .font(PVFont.body(13))
                    .foregroundStyle(PV.sub)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(PV.caramel.opacity(0.09))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text("包名")
                    .font(PVFont.sectionHeader)
                    .tracking(1.5)
                    .foregroundStyle(PV.muted)
                TextField("", text: $name, prompt:
                    Text("例如：剪辑_2026春节").font(PVFont.body(14.5)).foregroundStyle(PV.muted))
                    .font(PVFont.body(15))
                    .tint(PV.caramel)
                    .focused($focused)
                    .disabled(isExporting)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(PV.line, lineWidth: 1)
                    )
            }

            Text("打包内容：每张原图 + `metadata.json`（文件名/拍摄时间/所属文件夹/备注）— 解压后直接拖进剪辑软件可用。")
                .font(PVFont.body(11.5))
                .foregroundStyle(PV.sub)
                .lineSpacing(2)

            if let err = errorMsg {
                Text(err)
                    .font(PVFont.body(12))
                    .foregroundStyle(PV.berry)
            }
        }
    }

    private func successView(info: ExportInfo) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(PV.mint.opacity(0.22))
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(PV.mint)
                }
                .frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(info.filename)
                        .font(PVFont.mono(12.5, weight: .medium))
                        .foregroundStyle(PV.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("\(info.sizeBytes.humanReadableBytes)\(info.assetCount.map { " · \($0) 个素材" } ?? "")\(info.durationMs.map { " · 耗时 \($0) ms" } ?? "")")
                        .font(PVFont.mono(11))
                        .foregroundStyle(PV.sub)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Mac 服务端路径")
                    .font(PVFont.sectionHeader)
                    .tracking(1.5)
                    .foregroundStyle(PV.muted)
                HStack {
                    Text(info.absolutePath)
                        .font(PVFont.mono(11.5))
                        .foregroundStyle(PV.caramel)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        UIPasteboard.general.string = info.absolutePath
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(PV.caramel)
                            .padding(6)
                            .background(PV.caramel.opacity(0.1), in: Circle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(PV.caramel.opacity(0.09))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            Text("在 Mac 上：在 Finder 用 ⌘⇧G 粘贴上面的路径即可定位；也可通过 \(info.downloadPath) 浏览器下载。")
                .font(PVFont.body(11.5))
                .foregroundStyle(PV.sub)
                .lineSpacing(2)
        }
    }

    private var bottomCTA: some View {
        Group {
            if result == nil {
                Button {
                    Task { await doExport() }
                } label: {
                    HStack(spacing: 8) {
                        if isExporting {
                            ProgressView().tint(.white)
                            Text("正在打包… (GB 级文件可能耗时数分钟)")
                                .font(PVFont.body(13, weight: .medium))
                        } else {
                            Image(systemName: "shippingbox.fill")
                            Text("开始导出")
                        }
                    }
                }
                .buttonStyle(CButtonStyle(tone: PV.caramel, filled: true, height: 48))
                .disabled(isExporting || assetIds.isEmpty)
            } else {
                Button {
                    dismiss()
                } label: {
                    Text("完成")
                }
                .buttonStyle(CButtonStyle(tone: PV.caramel, filled: true, height: 48))
            }
        }
    }

    // MARK: - Actions

    private func doExport() async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        isExporting = true
        errorMsg = nil
        defer { isExporting = false }

        PVLog.upload("export[tap] 开始打包 assetIds=\(assetIds.count) name=\(trimmed.isEmpty ? "(默认)" : trimmed)")
        do {
            let info = try await api.createExport(
                assetIds: assetIds,
                name: trimmed.isEmpty ? nil : trimmed
            )
            result = info
            PVLog.upload("export[done] \(info.filename) size=\(info.sizeBytes.humanReadableBytes) \(info.durationMs ?? 0)ms")
        } catch {
            errorMsg = "导出失败: \(error.localizedDescription)"
            PVLog.uploadError("export[fail] \(error.localizedDescription)")
        }
    }
}
