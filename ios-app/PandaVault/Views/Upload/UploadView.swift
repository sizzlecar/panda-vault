import SwiftUI
import PhotosUI
import Photos

private enum UploadSheetType: Identifiable {
    case folderPicker
    case newFolder
    var id: Int { hashValue }
}

struct UploadView: View {
    @EnvironmentObject var appState: AppState
    /// 跟 AppState 共用同一个 UploadManager —— Share Extension 投进收件箱的文件也走它
    @EnvironmentObject var uploadManager: UploadManager
    @State private var showPicker = false
    @State private var selectedItems: [PhotosPickerItem] = []
    @State private var folders: [Folder] = []
    @State private var selectedFolderId: UUID?
    @State private var selectedFolderPath: String = "/ 根目录"
    @State private var activeSheet: UploadSheetType?
    @State private var newFolderName = ""
    @State private var isExporting = false
    @State private var exportProgress = ""

    // 删除本地原图（备份完成后的可选动作）
    @State private var isDeletingLocals = false
    @State private var deleteResultMsg: String?
    @State private var showDeleteResult = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    CLargeTitle("上传") {
                        Button { showPicker = true } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(PV.caramel)
                        }
                    }
                    .padding(.top, 2)

                    if isExporting { exportBanner }
                    folderTargetCard
                    pickFromAlbumCard
                    uploadStatusCards

                    Spacer(minLength: 100)
                }
                .padding(.bottom, 16)
            }
            .background(PV.bg.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .sheet(item: $activeSheet) { sheet in
                switch sheet {
                case .folderPicker:
                    FolderPickerView(api: appState.api, selectedFolderId: $selectedFolderId, selectedFolderPath: $selectedFolderPath, onDismiss: { activeSheet = nil })
                case .newFolder:
                    CreateFolderSheet(
                        parentPath: selectedFolderPath == "/ 根目录" ? "/" : selectedFolderPath,
                        api: appState.api,
                        parentId: selectedFolderId,
                        folderName: $newFolderName,
                        selectedFolderId: $selectedFolderId,
                        selectedFolderPath: $selectedFolderPath
                    )
                    .presentationDetents([.medium])
                }
            }
        }
        .photosPicker(
            isPresented: $showPicker,
            selection: $selectedItems,
            maxSelectionCount: 50,
            matching: .any(of: [.videos, .images]),
            photoLibrary: .shared()
        )
        .onChange(of: selectedItems) {
            Task { await handleSelection() }
        }
        .alert("", isPresented: $showDeleteResult) {
            Button("好") {}
        } message: {
            Text(deleteResultMsg ?? "")
        }
        .task {
            // UploadManager 由 AppState 持有 & 维护 API baseURL，这里只拉 folders
            await loadFolders()
        }
    }

    // MARK: - Cream Cards

    private var exportBanner: some View {
        HStack(spacing: 10) {
            ProgressView().tint(PV.caramel)
            Text(exportProgress)
                .font(PVFont.body(13))
                .foregroundStyle(PV.sub)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(PV.caramel.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 20)
    }

    private var folderTargetCard: some View {
        creamCard(header: "目标位置") {
            VStack(spacing: 0) {
                Button { activeSheet = .folderPicker } label: {
                    HStack(spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 9).fill(PV.caramel.opacity(0.13))
                            Image(systemName: "folder")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(PV.caramel)
                        }
                        .frame(width: 30, height: 30)
                        Text("上传到")
                            .font(PVFont.body(14.5))
                            .foregroundStyle(PV.ink)
                        Spacer()
                        Text(selectedFolderPath)
                            .font(PVFont.body(13))
                            .foregroundStyle(PV.sub)
                            .lineLimit(1)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(PV.muted)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 11)
                }
                .buttonStyle(.plain)

                Rectangle().fill(PV.divider).frame(height: 0.5).padding(.leading, 58)

                Button { newFolderName = ""; activeSheet = .newFolder } label: {
                    HStack(spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 9).fill(PV.caramel.opacity(0.13))
                            Image(systemName: "folder.badge.plus")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(PV.caramel)
                        }
                        .frame(width: 30, height: 30)
                        Text("新建文件夹")
                            .font(PVFont.body(14.5))
                            .foregroundStyle(PV.caramel)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 11)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var pickFromAlbumCard: some View {
        VStack(spacing: 0) {
            Button { showPicker = true } label: {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 9).fill(PV.mint.opacity(0.2))
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(PV.bean)
                    }
                    .frame(width: 32, height: 32)
                    Text("从相册选择")
                        .font(PVFont.body(14.5, weight: .medium))
                        .foregroundStyle(PV.ink)
                    Spacer()
                    Text("最多 50 张")
                        .font(PVFont.body(11.5))
                        .foregroundStyle(PV.muted)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(PV.line, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
    }

    @ViewBuilder
    private var uploadStatusCards: some View {
        if !uploadManager.tasks.isEmpty {
            progressSummaryCard

            let active = uploadManager.activeTasks
            if !active.isEmpty {
                creamCard(header: "进行中", headerSuffix: "\(active.count)") {
                    VStack(spacing: 0) {
                        ForEach(Array(active.enumerated()), id: \.element.id) { idx, task in
                            if idx > 0 { Rectangle().fill(PV.divider).frame(height: 0.5).padding(.leading, 44) }
                            UploadTaskRow(task: task)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                        }
                    }
                }
            }

            let failed = uploadManager.failedTasks
            if !failed.isEmpty {
                creamCard(header: "失败", headerSuffix: "\(failed.count)") {
                    VStack(spacing: 0) {
                        ForEach(Array(failed.enumerated()), id: \.element.id) { idx, task in
                            if idx > 0 { Rectangle().fill(PV.divider).frame(height: 0.5).padding(.leading, 44) }
                            UploadTaskRow(task: task)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                        }
                        Rectangle().fill(PV.divider).frame(height: 0.5)
                        Button { uploadManager.retryFailed() } label: {
                            HStack(spacing: 6) {
                                Spacer()
                                Image(systemName: "arrow.clockwise")
                                Text("重试失败项")
                                    .font(PVFont.body(14, weight: .semibold))
                                Spacer()
                            }
                            .foregroundStyle(PV.peach)
                            .padding(.vertical, 13)
                        }
                    }
                }
            }

            let doneItems = uploadManager.tasks.filter {
                if case .completed = $0.status { return true }
                if case .duplicated = $0.status { return true }
                return false
            }

            // 已备份但本地原图还没清理的（系统会弹原生确认框）
            let deletableLocals = uploadManager.tasks.filter { task in
                guard task.localIdentifier != nil, !task.localDeleted else { return false }
                if case .completed = task.status { return true }
                if case .duplicated = task.status { return true }
                return false
            }
            if !deletableLocals.isEmpty {
                deleteLocalsCard(count: deletableLocals.count)
            }

            if !doneItems.isEmpty {
                DoneUploadsCard(tasks: doneItems)
            }
        }
    }

    /// "备份后可选删除本地" cream 卡片
    private func deleteLocalsCard(count: Int) -> some View {
        creamCard(header: "整理空间") {
            Button {
                Task { await deleteLocalsAfterBackup() }
            } label: {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 9).fill(PV.berry.opacity(0.13))
                        Image(systemName: "trash")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(PV.berry)
                    }
                    .frame(width: 30, height: 30)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("删除本地原图")
                            .font(PVFont.body(14.5, weight: .medium))
                            .foregroundStyle(PV.ink)
                        Text("已备份到 NAS · 系统会弹确认框")
                            .font(PVFont.body(11.5))
                            .foregroundStyle(PV.sub)
                    }

                    Spacer()

                    if isDeletingLocals {
                        ProgressView().tint(PV.berry)
                    } else {
                        Text("\(count)")
                            .font(PVFont.mono(12, weight: .medium))
                            .foregroundStyle(PV.berry)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(PV.berry.opacity(0.13))
                            .clipShape(Capsule())
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(PV.muted)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 13)
            }
            .buttonStyle(.plain)
            .disabled(isDeletingLocals)
        }
    }

    private func deleteLocalsAfterBackup() async {
        let targets = uploadManager.tasks.filter { task in
            guard let _ = task.localIdentifier, !task.localDeleted else { return false }
            if case .completed = task.status { return true }
            if case .duplicated = task.status { return true }
            return false
        }
        let ids = targets.compactMap(\.localIdentifier)
        guard !ids.isEmpty else { return }

        PVLog.upload("deleteLocals[tap] 用户点击清理本地原图按钮 N=\(ids.count)")

        isDeletingLocals = true
        defer { isDeletingLocals = false }

        do {
            let deleted = try await PhotoLibraryService.deleteOriginals(localIdentifiers: ids)
            // 打上 localDeleted 标记 —— 再次上传时不会出现在整理入口
            for task in targets { task.localDeleted = true }
            deleteResultMsg = "已清理本地 \(deleted) 张原图"
            showDeleteResult = true
            PVLog.upload("deleteLocals: 成功 \(deleted) / 请求 \(ids.count)")
        } catch PhotoError.userCancelled {
            PVLog.upload("deleteLocals: 用户在系统确认框点了取消")
        } catch {
            deleteResultMsg = "删除失败: \(error.localizedDescription)"
            showDeleteResult = true
            PVLog.uploadError("deleteLocals 失败: \(error.localizedDescription)")
        }
    }

    private var progressSummaryCard: some View {
        creamCard(header: "上传进度") {
            UploadProgressSummary(manager: uploadManager)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
        }
    }

    // MARK: - Card shell

    @ViewBuilder
    private func creamCard<Content: View>(
        header: String? = nil,
        headerSuffix: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let header {
                HStack(alignment: .firstTextBaseline) {
                    Text(header.uppercased())
                        .font(PVFont.sectionHeader)
                        .tracking(1.5)
                        .foregroundStyle(PV.muted)
                    if let suffix = headerSuffix {
                        Text(suffix)
                            .font(PVFont.mono(11))
                            .foregroundStyle(PV.muted)
                    }
                    Spacer()
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 8)
            }
            content()
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(PV.line, lineWidth: 1)
                )
                .padding(.horizontal, 20)
        }
    }

    // MARK: - Actions

    private func loadFolders() async {
        do {
            folders = try await appState.api.getFolders()
        } catch { print("[PandaVault] Error: \(error)") }
    }

    private func handleSelection() async {
        let items = selectedItems
        selectedItems.removeAll()
        guard !items.isEmpty else { return }

        PVLog.upload("handleSelection[start] 选中 \(items.count) 项，folderId=\(selectedFolderId?.uuidString ?? "nil")")
        PVLog.disk("导出前磁盘快照")
        isExporting = true
        var files: [(url: URL, filename: String, size: Int64, shootAt: Date?, localIdentifier: String?)] = []

        var skippedNoIdentifier = 0
        var skippedNoPHAsset = 0
        var exportFailed = 0
        var fallbackLoadFailed = 0

        for (i, item) in items.enumerated() {
            exportProgress = "导出中 \(i + 1)/\(items.count)..."
            // 通过 PHAsset 获取原始资产（直接拿原始文件，不重新编码）
            guard let id = item.itemIdentifier else {
                skippedNoIdentifier += 1
                PVLog.uploadError("handleSelection[skip-no-id] 第 \(i + 1)/\(items.count) 项没有 itemIdentifier")
                continue
            }
            let phAsset = await Task.detached {
                PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject
            }.value
            if let phAsset {
                do {
                    let exported = try await PhotoLibraryService.exportAsset(phAsset)
                    files.append((exported.url, exported.filename, exported.size, phAsset.creationDate, id))
                    PVLog.upload("handleSelection[export-ok] \(i + 1)/\(items.count) name=\(exported.filename) size=\(exported.size.humanReadableBytes)")
                } catch {
                    exportFailed += 1
                    PVLog.uploadError("handleSelection[export-fail] \(i + 1)/\(items.count) id=\(id) err=\(error.localizedDescription)")
                }
            } else if let data = try? await item.loadTransferable(type: Data.self) {
                let name = "image_\(UUID().uuidString.prefix(8)).jpg"
                let tmpURL = FileManager.default.temporaryDirectory.appendingPathComponent(name)
                try? data.write(to: tmpURL)
                files.append((tmpURL, name, Int64(data.count), nil, nil))
                PVLog.upload("handleSelection[fallback] \(i + 1)/\(items.count) PHAsset 丢失，用 transferable 兜底 size=\(Int64(data.count).humanReadableBytes)")
            } else {
                skippedNoPHAsset += 1
                fallbackLoadFailed += 1
                PVLog.uploadError("handleSelection[skip-no-data] \(i + 1)/\(items.count) PHAsset 丢失且 transferable 也失败 id=\(id)")
            }
        }

        isExporting = false
        PVLog.upload("handleSelection[done] 输入=\(items.count) 成功导出=\(files.count) 跳过(无id)=\(skippedNoIdentifier) 跳过(无PHAsset+无data)=\(skippedNoPHAsset) 导出失败=\(exportFailed)")
        PVLog.disk("导出后磁盘快照")
        if !files.isEmpty {
            uploadManager.addFiles(files, folderId: selectedFolderId)
        } else {
            PVLog.uploadError("handleSelection: 0 个文件成功导出，不会触发上传")
        }
    }

}

// MARK: - 已完成上传卡片（可折叠）

private struct DoneUploadsCard: View {
    let tasks: [UploadTask]
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("已完成".uppercased())
                    .font(PVFont.sectionHeader)
                    .tracking(1.5)
                    .foregroundStyle(PV.muted)
                Text("\(tasks.count)")
                    .font(PVFont.mono(11))
                    .foregroundStyle(PV.muted)
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 8)

            Button {
                withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
            } label: {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(PV.mint)
                    Text(expanded ? "收起" : "\(tasks.count) 项已完成 · 点击展开")
                        .font(PVFont.body(13.5))
                        .foregroundStyle(PV.sub)
                    Spacer()
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(PV.muted)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 13)
            }
            .buttonStyle(.plain)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(PV.line, lineWidth: 1)
            )
            .padding(.horizontal, 20)

            if expanded {
                VStack(spacing: 0) {
                    ForEach(Array(tasks.enumerated()), id: \.element.id) { idx, task in
                        if idx > 0 { Rectangle().fill(PV.divider).frame(height: 0.5).padding(.leading, 44) }
                        UploadTaskRow(task: task)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                    }
                }
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(PV.line, lineWidth: 1)
                )
                .padding(.horizontal, 20)
                .padding(.top, 8)
            }
        }
    }
}

// MARK: - Upload Task Row (对应 cream.jsx UploadRow — mono 小胶囊状态 + 圆进度)

struct UploadTaskRow: View {
    @ObservedObject var task: UploadTask

    var body: some View {
        HStack(spacing: 11) {
            // 左侧媒体类型图标（cream: mint 成功 / caramel 重复 / muted 其他）
            ZStack {
                Image(systemName: iconName)
                    .font(.system(size: 18))
                    .foregroundStyle(iconColor)
            }
            .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(task.filename)
                    .font(PVFont.mono(12.5))
                    .foregroundStyle(PV.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    Text(ByteCountFormatter.string(fromByteCount: task.fileSize, countStyle: .file))
                        .font(PVFont.mono(10.5))
                        .foregroundStyle(PV.muted)
                    statusChip
                }
            }

            Spacer(minLength: 8)

            rightWidget
                .frame(width: 22, height: 22)
        }
    }

    private var iconName: String {
        let ext = (task.filename as NSString).pathExtension.lowercased()
        if ["mp4", "mov", "m4v"].contains(ext) { return "video" }
        return "photo"
    }

    private var iconColor: Color {
        switch task.status {
        case .completed: return PV.mint
        case .duplicated: return PV.caramel
        case .failed: return PV.berry
        default: return PV.muted
        }
    }

    /// cream.jsx 风 mono 胶囊：`DONE` / `EXIST` / `WAIT` / `62%`
    @ViewBuilder
    private var statusChip: some View {
        switch task.status {
        case .pending:
            monoChip("WAIT", fg: PV.muted, bg: PV.ink.opacity(0.08))
        case .uploading(let p):
            monoChip("\(Int(p * 100))%", fg: PV.caramel, bg: PV.caramel.opacity(0.13))
        case .completed:
            monoChip("DONE", fg: PV.mint, bg: PV.mint.opacity(0.22))
        case .duplicated:
            monoChip("EXIST", fg: PV.caramel, bg: PV.caramel.opacity(0.13))
        case .failed(let msg):
            monoChip(msg.isEmpty ? "FAIL" : msg, fg: PV.berry, bg: PV.berry.opacity(0.16))
        }
    }

    private func monoChip(_ text: String, fg: Color, bg: Color) -> some View {
        Text(text)
            .font(PVFont.mono(10, weight: .medium))
            .foregroundStyle(fg)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(bg)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .lineLimit(1)
    }

    /// 右端指示：上传中 → 圆环进度；完成 → 对勾；重复 → 等号；等待 → 省略号；失败 → 叉
    @ViewBuilder
    private var rightWidget: some View {
        switch task.status {
        case .uploading(let p):
            CircularProgressView(progress: p)
        case .completed:
            Image(systemName: "checkmark")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(PV.mint)
        case .duplicated:
            Text("=")
                .font(PVFont.mono(15, weight: .medium))
                .foregroundStyle(PV.caramel)
        case .pending:
            Text("⋯")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(PV.muted)
        case .failed:
            Image(systemName: "xmark")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(PV.berry)
        }
    }
}

/// 对应 cream.jsx 的圆环进度 — 焦糖色 2.5pt 线宽
struct CircularProgressView: View {
    let progress: Double
    var body: some View {
        ZStack {
            Circle().stroke(PV.ink.opacity(0.18), lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: max(0, min(1, progress)))
                .stroke(PV.caramel, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}

// MARK: - Folder Picker (hierarchical drill-down)

struct FolderPickerView: View {
    let api: APIService
    @Binding var selectedFolderId: UUID?
    @Binding var selectedFolderPath: String
    var onDismiss: (() -> Void)?
    @Environment(\.dismiss) private var dismiss

    // 面包屑导航：[(name, id?)]
    @State private var breadcrumbs: [(name: String, id: UUID?)] = [("根目录", nil)]
    @State private var currentParentId: UUID? = nil
    @State private var folders: [Folder] = []
    @State private var isLoading = false

    var body: some View {
        NavigationStack {
            ZStack {
                PV.bg.ignoresSafeArea()
                VStack(spacing: 0) {
                    // 面包屑路径（cream 风格 · JetBrainsMono）
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(Array(breadcrumbs.enumerated()), id: \.offset) { idx, crumb in
                                if idx > 0 {
                                    Text("/")
                                        .font(PVFont.mono(12))
                                        .foregroundStyle(PV.muted)
                                }
                                let last = idx == breadcrumbs.count - 1
                                Button(crumb.name) {
                                    breadcrumbs = Array(breadcrumbs.prefix(idx + 1))
                                    currentParentId = crumb.id
                                    Task { await loadFolders() }
                                }
                                .font(PVFont.mono(12, weight: last ? .medium : .regular))
                                .foregroundStyle(last ? PV.caramel : PV.sub)
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                    }
                    .background(Color.white.opacity(0.5))

                    ScrollView {
                        VStack(spacing: 14) {
                            // "选择此文件夹" —— 焦糖填充大按钮
                            Button {
                                selectedFolderId = currentParentId
                                selectedFolderPath = currentPath
                                dismiss(); onDismiss?()
                            } label: {
                                HStack(spacing: 12) {
                                    ZStack {
                                        Circle().fill(PV.caramel)
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 12, weight: .bold))
                                            .foregroundStyle(.white)
                                    }
                                    .frame(width: 26, height: 26)
                                    Text("选择此文件夹")
                                        .font(PVFont.body(14.5, weight: .semibold))
                                        .foregroundStyle(PV.caramel)
                                    Spacer()
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 14)
                                .background(Color.white)
                                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                                        .strokeBorder(PV.line, lineWidth: 1)
                                )
                            }
                            .buttonStyle(.plain)

                            // 子文件夹列表
                            if !folders.isEmpty {
                                VStack(spacing: 0) {
                                    ForEach(Array(folders.enumerated()), id: \.element.id) { idx, folder in
                                        Button {
                                            breadcrumbs.append((folder.name, folder.id))
                                            currentParentId = folder.id
                                            Task { await loadFolders() }
                                        } label: {
                                            HStack(spacing: 11) {
                                                Image(systemName: "folder")
                                                    .font(.system(size: 17))
                                                    .foregroundStyle(PV.caramel)
                                                Text(folder.name)
                                                    .font(PVFont.body(14))
                                                    .foregroundStyle(PV.ink)
                                                Spacer()
                                                Image(systemName: "chevron.right")
                                                    .font(.system(size: 11, weight: .semibold))
                                                    .foregroundStyle(PV.muted)
                                            }
                                            .padding(.horizontal, 16)
                                            .padding(.vertical, 13)
                                            .overlay(alignment: .bottom) {
                                                if idx < folders.count - 1 {
                                                    Rectangle()
                                                        .fill(PV.divider)
                                                        .frame(height: 0.5)
                                                        .padding(.leading, 46)
                                                }
                                            }
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                                .background(Color.white)
                                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                                        .strokeBorder(PV.line, lineWidth: 1)
                                )
                            } else if !isLoading {
                                VStack(spacing: 10) {
                                    Image(systemName: "folder.badge.questionmark")
                                        .font(.system(size: 24))
                                        .foregroundStyle(PV.muted)
                                    Text("这一层没有子文件夹")
                                        .font(PVFont.body(13))
                                        .foregroundStyle(PV.sub)
                                }
                                .padding(.vertical, 40)
                            }

                            if isLoading {
                                ProgressView().tint(PV.caramel).padding()
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 14)
                    }
                }
            }
            .navigationTitle("选择文件夹")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(PV.bg, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss(); onDismiss?() }
                }
            }
            .task { await loadFolders() }
        }
    }

    private var currentPath: String {
        if breadcrumbs.count <= 1 { return "/ 根目录" }
        return "/" + breadcrumbs.dropFirst().map(\.name).joined(separator: "/") + "/"
    }

    private func loadFolders() async {
        isLoading = true
        defer { isLoading = false }
        do {
            folders = try await api.getFolders(parentId: currentParentId)
        } catch {
            print("[PandaVault] Folder picker error: \(error)")
        }
    }
}

// MARK: - Upload Progress Summary

struct UploadProgressSummary: View {
    @ObservedObject var manager: UploadManager

    var body: some View {
        // TimelineView 每秒刷新，确保进度实时更新
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            summaryContent
        }
    }

    private var summaryContent: some View {
        let tasks = manager.tasks
        let total = tasks.count
        let completed = tasks.filter {
            if case .completed = $0.status { return true }
            if case .duplicated = $0.status { return true }
            return false
        }.count
        let failed = tasks.filter { if case .failed = $0.status { return true }; return false }.count
        let uploading = tasks.filter { if case .uploading = $0.status { return true }; return false }.count

        var progressSum = 0.0
        var doneBytes: Int64 = 0
        let totalBytes = tasks.map(\.fileSize).reduce(0, +)
        for task in tasks {
            switch task.status {
            case .completed, .duplicated:
                progressSum += 1.0
                doneBytes += task.fileSize
            case .uploading(let p):
                progressSum += p
                doneBytes += Int64(Double(task.fileSize) * p)
            default: break
            }
        }
        let progress = total > 0 ? progressSum / Double(total) : 0

        return VStack(spacing: 8) {
            PixelProgressBar(progress: progress, color: failed > 0 ? PV.orange : PV.cyan)

            HStack {
                Text("\(completed)/\(total)")
                    .font(.system(.caption, design: .monospaced).bold())
                    .foregroundStyle(.primary)
                Text("\(formatSize(doneBytes))/\(formatSize(totalBytes))")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                if uploading > 0 {
                    PixelTag(text: "\(uploading) UPLOADING", color: PV.cyan)
                }
                if failed > 0 {
                    PixelTag(text: "\(failed) FAILED", color: PV.pink)
                }
                Spacer()
                Text("\(Int(progress * 100))%")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func formatSize(_ bytes: Int64) -> String {
        if bytes < 1024 * 1024 { return "\(bytes / 1024) KB" }
        if bytes < 1024 * 1024 * 1024 { return String(format: "%.1f MB", Double(bytes) / 1_048_576) }
        return String(format: "%.2f GB", Double(bytes) / 1_073_741_824)
    }
}

// MARK: - Create Folder Sheet

private struct CreateFolderSheet: View {
    let parentPath: String
    let api: APIService
    let parentId: UUID?
    @Binding var folderName: String
    @Binding var selectedFolderId: UUID?
    @Binding var selectedFolderPath: String
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isFocused: Bool
    @State private var isCreating = false
    @State private var statusMsg = ""
    @State private var isError = false

    private var trimmedName: String {
        folderName.trimmingCharacters(in: .whitespaces)
    }

    private var previewPath: String {
        trimmedName.isEmpty ? parentPath : "\(parentPath)\(trimmedName)/"
    }

    var body: some View {
        ZStack {
            PV.bg.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 16) {
                // 标题
                HStack {
                    Text("新建文件夹")
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
                .padding(.top, 6)

                // 路径预览（mono · 焦糖）
                VStack(alignment: .leading, spacing: 4) {
                    Text("创建位置")
                        .font(PVFont.sectionHeader)
                        .tracking(1.5)
                        .foregroundStyle(PV.muted)
                    Text(previewPath)
                        .font(PVFont.mono(12, weight: .medium))
                        .foregroundStyle(PV.caramel)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(PV.caramel.opacity(0.09))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }

                // 名称输入
                VStack(alignment: .leading, spacing: 4) {
                    Text("文件夹名称")
                        .font(PVFont.sectionHeader)
                        .tracking(1.5)
                        .foregroundStyle(PV.muted)
                    TextField("", text: $folderName, prompt:
                        Text("比如 2026春节").font(PVFont.body(14.5)).foregroundStyle(PV.muted))
                    .font(PVFont.body(15))
                    .tint(PV.caramel)
                    .focused($isFocused)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(PV.line, lineWidth: 1)
                    )
                }

                if !statusMsg.isEmpty {
                    Text(statusMsg)
                        .font(PVFont.body(12))
                        .foregroundStyle(isError ? PV.berry : PV.caramel)
                        .padding(.horizontal, 4)
                }

                Spacer()

                // CTA
                Button {
                    Task { await doCreate() }
                } label: {
                    HStack {
                        if isCreating {
                            ProgressView().tint(.white)
                        } else {
                            Text("创建")
                        }
                    }
                }
                .buttonStyle(CButtonStyle(tone: PV.caramel, filled: true, height: 48))
                .disabled(trimmedName.isEmpty || isCreating)
                .opacity(trimmedName.isEmpty ? 0.5 : 1)
            }
            .padding(20)
        }
        .onAppear { isFocused = true }
    }

    private func doCreate() async {
        print("[PandaVault] doCreate called, trimmedName=\(trimmedName), parentId=\(String(describing: parentId))")
        guard !trimmedName.isEmpty else { print("[PandaVault] name is empty, returning"); return }
        isCreating = true
        statusMsg = ""
        defer { isCreating = false }
        do {
            print("[PandaVault] calling api.createFolder...")
            let folder = try await api.createFolder(name: trimmedName, parentId: parentId)
            print("[PandaVault] created: \(folder.name)")
            selectedFolderId = folder.id
            selectedFolderPath = previewPath
            folderName = ""
            dismiss()
        } catch let error as APIError {
            isError = true
            if case .httpError(let code) = error, code == 409 {
                statusMsg = "同名文件夹已存在"
            } else {
                statusMsg = "创建失败: \(error.localizedDescription)"
            }
        } catch {
            isError = true
            statusMsg = "创建失败: \(error.localizedDescription)"
        }
    }
}
