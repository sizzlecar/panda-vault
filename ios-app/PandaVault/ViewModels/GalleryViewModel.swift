import SwiftUI

@MainActor
final class GalleryViewModel: ObservableObject {
    @Published var assets: [Asset] = []
    @Published var isLoading = false
    @Published var searchText = ""
    @Published var hasMore = true
    @Published var isImageSearchResult = false
    @Published var timeline: [TimelineGroup] = []
    @Published var folders: [Folder] = []
    @Published var errorMessage: String?

    /// 每月资产的加载状态，用于驱动 UI 显示 loading indicator
    @Published var monthLoadingStates: [String: MonthLoadState] = [:]

    var api: APIService
    private let pageSize = 50

    // 按月分组的资产缓存（已加载的月份）
    private var monthlyAssets: [String: [Asset]] = [:]
    // 正在加载的月份（防止并发重复请求）
    private var monthsInFlight: Set<String> = []

    enum MonthLoadState {
        case idle
        case loading
        case loaded
        case failed
    }

    init(api: APIService) {
        self.api = api
    }

    // MARK: - Timeline (lightweight, only loads month + count)

    /// 只加载 timeline 元数据（月 + 数量），不加载任何资产
    func loadTimeline() async {
        isLoading = true
        defer { isLoading = false }

        do {
            let days = try await api.getTimeline()
            var monthMap: [String: Int] = [:]
            var monthOrder: [String] = []
            for d in days {
                let m = d.month
                if monthMap[m] == nil { monthOrder.append(m) }
                monthMap[m, default: 0] += d.count
            }
            timeline = monthOrder.map { m in
                TimelineGroup(day: m, count: monthMap[m] ?? 0)
            }
            isImageSearchResult = false
            errorMessage = nil
        } catch {
            errorMessage = "无法连接服务器"
            print("[PandaVault] loadTimeline error: \(error)")
        }
    }

    /// 兼容旧调用点：pull-to-refresh 和 server URL 变更时使用
    func loadTimelineAndAssets() async {
        // 清除缓存，重新加载 timeline
        monthlyAssets = [:]
        monthsInFlight = []
        monthLoadingStates = [:]
        await loadTimeline()
        // 并行加载前 3 个月，显著降低主线程 hang 时间
        let firstThree = timeline.prefix(3).map(\.month)
        for month in firstThree {
            if monthlyAssets[month] == nil {
                monthLoadingStates[month] = .loading
            }
        }
        let api = self.api
        let results: [(String, [Asset]?)] = await withTaskGroup(of: (String, [Asset]?).self) { group in
            for month in firstThree where monthlyAssets[month] == nil {
                group.addTask {
                    let r = try? await api.getAssetsByMonth(month: month)
                    return (month, r)
                }
            }
            var collected: [(String, [Asset]?)] = []
            for await item in group { collected.append(item) }
            return collected
        }
        for (month, assets) in results {
            if let assets {
                monthlyAssets[month] = assets
                monthLoadingStates[month] = .loaded
            } else {
                monthLoadingStates[month] = .failed
            }
        }
    }

    // MARK: - Per-Month Lazy Loading

    /// 确保某月的资产已加载。由 View 的 onAppear 调用。
    func ensureMonthLoaded(_ month: String) {
        // 已缓存或正在加载中 → 跳过
        if monthlyAssets[month] != nil || monthsInFlight.contains(month) { return }

        monthsInFlight.insert(month)
        monthLoadingStates[month] = .loading
        PVLog.mem("加载月份: \(month)")

        Task {
            do {
                let assets = try await api.getAssetsByMonth(month: month)
                monthlyAssets[month] = assets
                monthLoadingStates[month] = .loaded
                PVLog.mem("月份加载完成: \(month) count=\(assets.count)")
            } catch {
                print("[PandaVault] loadMonth(\(month)) error: \(error)")
                monthLoadingStates[month] = .failed
            }
            monthsInFlight.remove(month)
            // 触发 UI 更新（monthlyAssets 不是 @Published，需手动触发）
            objectWillChange.send()
        }
    }

    func assetsForMonth(_ month: String) -> [Asset] {
        monthlyAssets[month] ?? []
    }

    /// 详情页修改了某个 asset（重命名/备注）后，同步更新本地缓存
    /// —— 否则关闭详情页重打开会看到旧数据
    func replaceAsset(_ asset: Asset) {
        // 时间线月份缓存
        for month in monthlyAssets.keys {
            if let idx = monthlyAssets[month]?.firstIndex(where: { $0.id == asset.id }) {
                monthlyAssets[month]?[idx] = asset
            }
        }
        // 搜索 / 文件夹 fallback 用的 assets 列表
        if let idx = assets.firstIndex(where: { $0.id == asset.id }) {
            assets[idx] = asset
        }
        objectWillChange.send()
    }

    func isMonthLoading(_ month: String) -> Bool {
        monthLoadingStates[month] == .loading
    }

    /// 按时间轴顺序排列的所有 *已加载* 资产（用于详情页左右滑动）
    var allAssetsOrdered: [Asset] {
        timeline.flatMap { assetsForMonth($0.month) }
    }

    /// 用 shootAt 优先（和后端 timeline 一致），fallback 到 createdAt
    func monthForAsset(_ asset: Asset) -> String {
        let date = asset.shootAt ?? asset.createdAt
        let cal = Calendar.current
        let y = cal.component(.year, from: date)
        let m = cal.component(.month, from: date)
        return String(format: "%04d-%02d", y, m)
    }

    // MARK: - Assets (搜索用，非 timeline 模式)

    func loadAssets(refresh: Bool = false) async {
        guard !isLoading else { return }
        if !refresh && !hasMore { return }

        isLoading = true
        defer { isLoading = false }

        if refresh {
            let offset = 0
            do {
                let batch = try await api.getAssets(limit: pageSize, offset: offset)
                assets = batch
                hasMore = batch.count >= pageSize
            } catch {
                print("[PandaVault] Error: \(error)")
            }
        } else {
            let offset = assets.count
            do {
                let newAssets = try await api.getAssets(limit: pageSize, offset: offset)
                assets.append(contentsOf: newAssets)
                hasMore = newAssets.count >= pageSize
            } catch { print("[PandaVault] Error: \(error)") }
        }
    }

    // MARK: - Search (默认 AI 语义搜索，降级到文件名)

    func search() async {
        guard !searchText.isEmpty else {
            // 清空搜索 → 回到 timeline 模式
            assets = []
            isImageSearchResult = false
            return
        }

        isLoading = true
        defer { isLoading = false }

        do {
            // 优先语义搜索
            assets = try await api.semanticSearch(text: searchText)
            hasMore = false
        } catch {
            // AI 不可用时降级为文件名搜索
            do {
                assets = try await api.getAssets(query: searchText, limit: 50, offset: 0)
                hasMore = false
            } catch { print("[PandaVault] Error: \(error)") }
        }
    }

    // MARK: - Folders

    func loadFolders() async {
        do {
            folders = try await api.getFolders()
        } catch { print("[PandaVault] Error: \(error)") }
    }

    @Published var recentFolders: [Folder] = []

    /// 拉"最近在整理"横滚卡数据
    func loadRecentFolders(limit: Int = 6) async {
        do {
            recentFolders = try await api.getRecentFolders(limit: limit)
        } catch {
            // 老后端没这个接口时返回 404；优雅降级 — 仅打日志
            PVLog.info("loadRecentFolders 失败（老后端？）: \(error.localizedDescription)")
            recentFolders = []
        }
    }

    func createNewFolder() async {
        // 默认名称，可后续改成弹窗输入
        let name = "新文件夹 \(folders.count + 1)"
        do {
            let folder = try await api.createFolder(name: name)
            folders.insert(folder, at: 0)
        } catch { print("[PandaVault] Error: \(error)") }
    }

    func imageSearch(data: Data) async {
        isLoading = true
        defer { isLoading = false }
        do {
            assets = try await api.imageSearch(imageData: data)
            isImageSearchResult = true
            hasMore = false
        } catch { print("[PandaVault] Error: \(error)") }
    }

    func clearImageSearch() {
        isImageSearchResult = false
        assets = []
    }

    func loadMoreIfNeeded(current: Asset) {
        guard let index = assets.firstIndex(of: current) else { return }
        if index >= assets.count - 10 {
            Task { await loadAssets() }
        }
    }
}
