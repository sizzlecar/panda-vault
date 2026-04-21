import SwiftUI

struct TrashView: View {
    let api: APIService

    @State private var assets: [Asset] = []
    @State private var isLoading = false
    @State private var isSelecting = false
    @State private var selectedIds: Set<UUID> = []
    @State private var showDeleteConfirm = false
    @State private var showEmptyConfirm = false

    private let columns = [GridItem(.adaptive(minimum: 110, maximum: 200), spacing: 2)]

    var body: some View {
        ScrollView {
            if assets.isEmpty && !isLoading {
                emptyState
            } else {
                LazyVGrid(columns: columns, spacing: 2) {
                    ForEach(assets) { asset in
                        trashCell(asset)
                    }
                }
                .padding(.horizontal, 2)
            }
        }
        .background(PV.bg.ignoresSafeArea())
        .toolbarBackground(PV.bg, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .navigationTitle("最近删除")
        .toolbar { trashToolbar }
        .overlay(alignment: .bottom) {
            if isSelecting && !selectedIds.isEmpty {
                trashBottomBar
            }
        }
        .confirmationDialog(
            "永久删除 \(selectedIds.count) 个素材？\n文件将从磁盘清除，无法恢复。",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("永久删除", role: .destructive) { Task { await permanentlyDelete() } }
        }
        .alert("清空回收站", isPresented: $showEmptyConfirm) {
            Button("清空", role: .destructive) { Task { await emptyAll() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将永久删除所有已超过 7 天的素材，无法恢复。")
        }
        .task { await load() }
    }

    // MARK: - Cell

    private func trashCell(_ asset: Asset) -> some View {
        let isSelected = isSelecting && selectedIds.contains(asset.id)
        return Button {
            if isSelecting {
                if selectedIds.contains(asset.id) { selectedIds.remove(asset.id) }
                else { selectedIds.insert(asset.id) }
            }
        } label: {
            AssetThumbnail(asset: asset, api: api)
                .overlay(alignment: .topLeading) {
                    if let d = asset.deletedAt {
                        Text(daysRemaining(d))
                            .font(PVFont.mono(10, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(PV.berry, in: Capsule())
                            .padding(6)
                            .shadow(color: .black.opacity(0.2), radius: 2)
                    }
                }
                .overlay {
                    if isSelected { Color.black.opacity(0.2) }
                }
                .overlay(alignment: .topTrailing) {
                    if isSelecting {
                        ZStack {
                            Circle()
                                .fill(isSelected ? PV.cyan : .black.opacity(0.3))
                                .frame(width: 22, height: 22)
                            if isSelected {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(.white)
                            } else {
                                Circle()
                                    .strokeBorder(.white, lineWidth: 1.5)
                                    .frame(width: 22, height: 22)
                            }
                        }
                        .shadow(color: .black.opacity(0.3), radius: 2)
                        .padding(6)
                    }
                }
                .border(isSelected ? PV.cyan : .clear, width: 2)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var trashToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            HStack(spacing: 12) {
                if isSelecting && !assets.isEmpty {
                    Button {
                        let allIds = Set(assets.map(\.id))
                        selectedIds = selectedIds == allIds ? [] : allIds
                    } label: {
                        Text(selectedIds.count == assets.count ? "取消全选" : "全选")
                            .foregroundStyle(PV.cyan)
                    }
                }
                if !assets.isEmpty {
                    Button {
                        isSelecting.toggle()
                        if !isSelecting { selectedIds.removeAll() }
                    } label: {
                        Text(isSelecting ? "完成" : "选择")
                            .foregroundStyle(PV.cyan)
                    }
                }
            }
        }
    }

    // MARK: - Bottom Bar (cream 浮动白卡)

    private var trashBottomBar: some View {
        VStack(spacing: 0) {
            Text("已选 \(selectedIds.count) 项")
                .font(PVFont.body(10.5, weight: .semibold))
                .foregroundStyle(PV.sub)
                .padding(.top, 10)

            HStack(spacing: 0) {
                Button { Task { await restoreSelected() } } label: {
                    VStack(spacing: 3) {
                        Image(systemName: "arrow.uturn.backward").font(.system(size: 18))
                        Text("恢复").font(PVFont.body(11, weight: .medium))
                    }
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(PV.caramel)
                }

                Button { showDeleteConfirm = true } label: {
                    VStack(spacing: 3) {
                        Image(systemName: "trash.slash").font(.system(size: 18))
                        Text("永久删除").font(PVFont.body(11, weight: .medium))
                    }
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(PV.berry)
                }

                Button { showEmptyConfirm = true } label: {
                    VStack(spacing: 3) {
                        Image(systemName: "trash").font(.system(size: 18))
                        Text("清空").font(PVFont.body(11, weight: .medium))
                    }
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(PV.peach)
                }
            }
            .padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(PV.line, lineWidth: 1)
        )
        .shadow(color: PV.bean.opacity(0.14), radius: 14, y: 4)
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "trash.slash")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text("回收站为空")
                .font(.system(.caption, design: .monospaced).bold())
                .foregroundStyle(.secondary)
            Text("删除的素材会保留 7 天")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 100)
    }

    // MARK: - Actions

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        assets = (try? await api.getTrash()) ?? []
    }

    private func restoreSelected() async {
        let ids = Array(selectedIds)
        try? await api.restoreAssets(ids: ids)
        selectedIds.removeAll()
        isSelecting = false
        await load()
    }

    private func permanentlyDelete() async {
        let ids = Array(selectedIds)
        try? await api.permanentlyDeleteAssets(ids: ids)
        selectedIds.removeAll()
        isSelecting = false
        await load()
    }

    private func emptyAll() async {
        // 传空 ids → 后端删除所有 7 天前的
        try? await api.permanentlyDeleteAssets(ids: assets.map(\.id))
        selectedIds.removeAll()
        isSelecting = false
        await load()
    }

    // MARK: - Helpers

    private func daysRemaining(_ deletedAt: Date) -> String {
        let remaining = 7 - Calendar.current.dateComponents([.day], from: deletedAt, to: Date()).day!
        if remaining <= 0 { return "即将清理" }
        return "剩 \(remaining) 天"
    }
}
