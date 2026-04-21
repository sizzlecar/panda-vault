import SwiftUI

/// 剪辑工程包导出 —— cream sheet
/// 流程：用户选一批 asset → 输包名 → 打包 → 下载到手机 → 弹 iOS 系统分享
/// 系统分享里：AirDrop / 微信 / 存到文件 app / 剪映直接接收 随意选
struct ExportSheet: View {
    let api: APIService
    let assetIds: [UUID]

    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    @State private var name = ""
    @State private var phase: Phase = .idle
    @State private var errorMsg: String?

    @State private var exportInfo: ExportInfo?
    @State private var localZipURL: URL?
    @State private var showShareSheet = false

    enum Phase {
        case idle
        case packaging      // 后端打 zip 中
        case downloading    // 后端 zip 已好，下载到手机
        case ready          // 本地 zip 就位，可分享
        case failed
    }

    var body: some View {
        ZStack {
            PV.bg.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 16) {
                header
                switch phase {
                case .idle:           inputView
                case .packaging:      progressView(step: "打包中", subtitle: "素材多可能要一会儿")
                case .downloading:    progressView(step: "下载到手机", subtitle: exportInfo.map { "\($0.filename)  ·  \($0.sizeBytes.humanReadableBytes)" } ?? "")
                case .ready:          successView
                case .failed:         failedView
                }
                Spacer()
                bottomCTA
            }
            .padding(20)
        }
        .presentationDetents([.medium, .large])
        .onAppear {
            let df = DateFormatter()
            df.dateFormat = "yyyyMMdd"
            name = "剪辑_\(df.string(from: Date()))"
            if phase == .idle { focused = true }
        }
        .sheet(isPresented: $showShareSheet, onDismiss: cleanupLocalZip) {
            if let url = localZipURL {
                ActivityView(items: [url])
            }
        }
    }

    // MARK: - Subviews

    private var header: some View {
        HStack {
            Text(phaseTitle)
                .font(PVFont.display(22, weight: .medium))
                .foregroundStyle(PV.ink)
            Spacer()
            Button { cleanupLocalZip(); dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(PV.sub)
                    .frame(width: 30, height: 30)
                    .background(PV.ink.opacity(0.06), in: Circle())
            }
        }
        .padding(.top, 2)
    }

    private var phaseTitle: String {
        switch phase {
        case .idle, .failed:  return "导出"
        case .packaging:      return "打包中…"
        case .downloading:    return "下载中…"
        case .ready:          return "可以分享了"
        }
    }

    private var inputView: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "photo.stack")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(PV.caramel)
                Text("\(assetIds.count) 个素材")
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
                    Text("剪辑_2026春节").font(PVFont.body(14.5)).foregroundStyle(PV.muted))
                    .font(PVFont.body(15))
                    .tint(PV.caramel)
                    .focused($focused)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(PV.line, lineWidth: 1)
                    )
            }

            Text("打包好会弹系统分享，可 AirDrop / 微信 / 存到文件。")
                .font(PVFont.body(11.5))
                .foregroundStyle(PV.sub)
        }
    }

    private func progressView(step: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                ProgressView().tint(PV.caramel).scaleEffect(1.1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(step)
                        .font(PVFont.body(14.5, weight: .medium))
                        .foregroundStyle(PV.ink)
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(PVFont.mono(11))
                            .foregroundStyle(PV.sub)
                            .lineLimit(2)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(PV.line, lineWidth: 1)
            )
        }
    }

    private var successView: some View {
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
                    Text(exportInfo?.filename ?? "导出完成")
                        .font(PVFont.mono(12.5, weight: .medium))
                        .foregroundStyle(PV.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let info = exportInfo {
                        Text("\(info.sizeBytes.humanReadableBytes)\(info.assetCount.map { " · \($0) 个素材" } ?? "")")
                            .font(PVFont.mono(11))
                            .foregroundStyle(PV.sub)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(PV.line, lineWidth: 1)
            )

        }
    }

    private var failedView: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(PV.berry)
                Text(errorMsg ?? "导出失败")
                    .font(PVFont.body(13))
                    .foregroundStyle(PV.berry)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(PV.berry.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private var bottomCTA: some View {
        Group {
            switch phase {
            case .idle, .failed:
                Button {
                    Task { await runPipeline() }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "shippingbox.fill")
                        Text(phase == .failed ? "重试" : "开始")
                    }
                }
                .buttonStyle(CButtonStyle(tone: PV.caramel, filled: true, height: 48))
                .disabled(assetIds.isEmpty)

            case .packaging, .downloading:
                Button {} label: {
                    HStack(spacing: 8) {
                        ProgressView().tint(.white)
                        Text("请稍候").font(PVFont.body(14, weight: .medium))
                    }
                }
                .buttonStyle(CButtonStyle(tone: PV.caramel, filled: true, height: 48))
                .disabled(true)
                .opacity(0.7)

            case .ready:
                Button {
                    showShareSheet = true
                    PVLog.upload("export[share-sheet] 打开系统分享")
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "square.and.arrow.up.fill")
                        Text("分享")
                    }
                }
                .buttonStyle(CButtonStyle(tone: PV.caramel, filled: true, height: 48))
            }
        }
    }

    // MARK: - Pipeline

    private func runPipeline() async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        PVLog.upload("export[tap] assetIds=\(assetIds.count) name=\(trimmed.isEmpty ? "(默认)" : trimmed)")

        // 1. 打包
        phase = .packaging
        errorMsg = nil
        let info: ExportInfo
        do {
            info = try await api.createExport(
                assetIds: assetIds,
                name: trimmed.isEmpty ? nil : trimmed
            )
            exportInfo = info
            PVLog.upload("export[packaged] \(info.filename) size=\(info.sizeBytes.humanReadableBytes) backendMs=\(info.durationMs ?? 0)")
        } catch {
            phase = .failed
            errorMsg = "打包失败: \(error.localizedDescription)"
            PVLog.uploadError("export[package-fail] \(error.localizedDescription)")
            return
        }

        // 2. 下载到手机 tmp
        phase = .downloading
        do {
            let t0 = Date()
            let local = try await api.downloadExport(info: info)
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            localZipURL = local
            PVLog.upload("export[downloaded] \(info.filename) → \(local.lastPathComponent) \(ms)ms")
        } catch {
            phase = .failed
            errorMsg = "下载到手机失败: \(error.localizedDescription)"
            PVLog.uploadError("export[download-fail] \(error.localizedDescription)")
            return
        }

        // 3. 就绪 —— 等用户点"分享工程包"
        phase = .ready
    }

    /// 分享完（或用户取消 ExportSheet）清掉本地 tmp zip
    private func cleanupLocalZip() {
        if let url = localZipURL {
            try? FileManager.default.removeItem(at: url)
            localZipURL = nil
            PVLog.upload("export[cleanup] 本地 zip 已删")
        }
    }
}
