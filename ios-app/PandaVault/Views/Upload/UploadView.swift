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
    @StateObject private var uploadManager: UploadManager
    @State private var showPicker = false
    @State private var selectedItems: [PhotosPickerItem] = []
    @State private var folders: [Folder] = []
    @State private var selectedFolderId: UUID?
    @State private var selectedFolderPath: String = "/ 根目录"
    @State private var activeSheet: UploadSheetType?
    @State private var newFolderName = ""
    @State private var isExporting = false
    @State private var exportProgress = ""

    init() {
        _uploadManager = StateObject(wrappedValue: UploadManager(api: APIService(baseURL: "")))
    }

    var body: some View {
        NavigationStack {
                List {
                    exportSection
                    folderSection
                    pickSection
                    uploadStatusSections
                }
                
            .navigationTitle("上传")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showPicker = true } label: {
                        Image(systemName: "plus").foregroundStyle(PV.cyan)
                    }
                }
            }
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
        .task {
            uploadManager.updateAPI(appState.api)
            await loadFolders()
        }
    }

    // MARK: - Sub Sections

    @ViewBuilder
    private var exportSection: some View {
        if isExporting {
            Section {
                HStack {
                    ProgressView().tint(PV.cyan)
                    Text(exportProgress)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var folderSection: some View {
        Section {
            Button {
                activeSheet = .folderPicker
            } label: {
                HStack {
                    Text("上传到")
                        .foregroundStyle(.primary)
                    Spacer()
                    Text(selectedFolderPath)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            Button { newFolderName = ""; activeSheet = .newFolder } label: {
                Label("新建文件夹", systemImage: "folder.badge.plus")
                    .foregroundStyle(PV.cyan)
            }
        } header: {
            PixelSectionHeader(title: "目标位置")
        }
    }

    private var pickSection: some View {
        Section {
            Button { showPicker = true } label: {
                Label("从相册选择", systemImage: "photo.on.rectangle.angled")
                    .foregroundStyle(PV.green)
            }
        }
    }

    @ViewBuilder
    private var uploadStatusSections: some View {
        if !uploadManager.tasks.isEmpty {
            Section {
                UploadProgressSummary(manager: uploadManager)
            } header: {
                PixelSectionHeader(title: "上传进度")
            }

            let active = uploadManager.activeTasks
            if !active.isEmpty {
                Section {
                    ForEach(active) { UploadTaskRow(task: $0) }
                } header: {
                    PixelSectionHeader(title: "进行中", count: "\(active.count)")
                }
            }

            let failed = uploadManager.failedTasks
            if !failed.isEmpty {
                Section {
                    ForEach(failed) { UploadTaskRow(task: $0) }
                    Button { uploadManager.retryFailed() } label: {
                        Label("重试失败项", systemImage: "arrow.clockwise")
                            .foregroundStyle(PV.orange)
                    }
                } header: {
                    PixelSectionHeader(title: "失败", count: "\(failed.count)")
                }
            }

            let doneItems = uploadManager.tasks.filter {
                if case .completed = $0.status { return true }
                if case .duplicated = $0.status { return true }
                return false
            }
            if !doneItems.isEmpty {
                DisclosureGroup {
                    ForEach(doneItems) { UploadTaskRow(task: $0) }
                } label: {
                    PixelSectionHeader(title: "已完成", count: "\(doneItems.count)")
                }
            }
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
        var files: [(url: URL, filename: String, size: Int64, shootAt: Date?)] = []

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
                    files.append((exported.url, exported.filename, exported.size, phAsset.creationDate))
                    PVLog.upload("handleSelection[export-ok] \(i + 1)/\(items.count) name=\(exported.filename) size=\(exported.size.humanReadableBytes)")
                } catch {
                    exportFailed += 1
                    PVLog.uploadError("handleSelection[export-fail] \(i + 1)/\(items.count) id=\(id) err=\(error.localizedDescription)")
                }
            } else if let data = try? await item.loadTransferable(type: Data.self) {
                let name = "image_\(UUID().uuidString.prefix(8)).jpg"
                let tmpURL = FileManager.default.temporaryDirectory.appendingPathComponent(name)
                try? data.write(to: tmpURL)
                files.append((tmpURL, name, Int64(data.count), nil))
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

// MARK: - Upload Task Row

struct UploadTaskRow: View {
    @ObservedObject var task: UploadTask

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: iconName)
                .font(.title3)
                .foregroundStyle(iconColor)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(task.filename)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(ByteCountFormatter.string(fromByteCount: task.fileSize, countStyle: .file))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    statusText
                }
            }

            Spacer()

            switch task.status {
            case .uploading(let progress):
                CircularProgressView(progress: progress).frame(width: 24, height: 24)
            case .completed:
                Image(systemName: "checkmark").foregroundStyle(PV.green).font(.caption.bold())
            case .duplicated:
                Image(systemName: "equal.circle").foregroundStyle(PV.cyan).font(.caption.bold())
            case .failed:
                Image(systemName: "xmark").foregroundStyle(PV.pink).font(.caption.bold())
            default:
                Image(systemName: "ellipsis").foregroundStyle(.tertiary).font(.caption)
            }
        }
        .padding(.vertical, 2)
    }

    private var iconName: String {
        let ext = (task.filename as NSString).pathExtension.lowercased()
        if ["mp4", "mov", "m4v"].contains(ext) { return "film" }
        return "photo"
    }

    private var iconColor: Color {
        switch task.status {
        case .completed, .duplicated: return PV.green
        case .failed: return PV.pink
        default: return Color(.tertiaryLabel)
        }
    }

    @ViewBuilder
    private var statusText: some View {
        switch task.status {
        case .pending:
            PixelTag(text: "WAIT", color: Color(.tertiaryLabel))
        case .uploading(let p):
            PixelTag(text: "\(Int(p * 100))%", color: PV.cyan)
        case .completed:
            PixelTag(text: "DONE", color: PV.green)
        case .duplicated:
            PixelTag(text: "EXIST", color: PV.cyan)
        case .failed(let msg):
            PixelTag(text: msg, color: PV.pink)
        }
    }
}

struct CircularProgressView: View {
    let progress: Double
    var body: some View {
        ZStack {
            Circle().stroke(Color(.secondarySystemFill), lineWidth: 3)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(PV.cyan, style: StrokeStyle(lineWidth: 3, lineCap: .round))
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
            VStack(spacing: 0) {
                // 面包屑路径
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(Array(breadcrumbs.enumerated()), id: \.offset) { idx, crumb in
                            if idx > 0 { Text("/").font(.caption2).foregroundStyle(.tertiary) }
                            Button(crumb.name) {
                                // 跳回到这一层
                                breadcrumbs = Array(breadcrumbs.prefix(idx + 1))
                                currentParentId = crumb.id
                                Task { await loadFolders() }
                            }
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(idx == breadcrumbs.count - 1 ? PV.cyan : .secondary)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                }
                .background(Color(.secondarySystemGroupedBackground))

                List {
                    // 选当前层
                    Button {
                        selectedFolderId = currentParentId
                        selectedFolderPath = currentPath
                        dismiss(); onDismiss?()
                    } label: {
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(PV.cyan)
                            Text("选择此文件夹")
                                .foregroundStyle(PV.cyan)
                                .fontWeight(.medium)
                        }
                    }

                    if isLoading {
                        HStack { Spacer(); ProgressView().tint(PV.cyan); Spacer() }
                    }

                    ForEach(folders) { folder in
                        Button {
                            breadcrumbs.append((folder.name, folder.id))
                            currentParentId = folder.id
                            Task { await loadFolders() }
                        } label: {
                            HStack {
                                Image(systemName: "folder.fill").foregroundStyle(PV.cyan)
                                Text(folder.name).foregroundStyle(.primary)
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("选择文件夹")
            .navigationBarTitleDisplayMode(.inline)
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
        VStack(spacing: 16) {
            Text("新建文件夹").font(.headline)

            Text(previewPath)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(PV.cyan)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(PV.cyan.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))

            TextField("文件夹名称", text: $folderName)
                .textFieldStyle(.roundedBorder)
                .focused($isFocused)

            if !statusMsg.isEmpty {
                Text(statusMsg)
                    .font(.caption)
                    .foregroundStyle(isError ? .red : PV.cyan)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 16) {
                Button("取消") { dismiss() }
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)

                Button(isCreating ? "创建中..." : "创建") {
                    print("[PandaVault] 创建按钮被点击, name=\(folderName), parentId=\(String(describing: parentId))")
                    Task { await doCreate() }
                }
                .fontWeight(.semibold)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(trimmedName.isEmpty || isCreating ? .gray : PV.cyan, in: RoundedRectangle(cornerRadius: 8))
                .disabled(trimmedName.isEmpty || isCreating)
            }
        }
        .padding(20)
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
