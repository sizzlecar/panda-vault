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

    var api: APIService
    private let pageSize = 50

    // 按月分组的资产缓存
    private var monthlyAssets: [String: [Asset]] = [:]

    init(api: APIService) {
        self.api = api
    }

    // MARK: - Assets

    func loadAssets(refresh: Bool = false) async {
        guard !isLoading else { return }
        if !refresh && !hasMore { return }

        isLoading = true
        defer { isLoading = false }

        if refresh {
            // 全量加载所有资产（分页循环直到取完）
            var all: [Asset] = []
            var offset = 0
            while true {
                do {
                    let batch = try await api.getAssets(limit: 200, offset: offset)
                    all.append(contentsOf: batch)
                    if batch.count < 200 { break }
                    offset += batch.count
                } catch {
                    print("[PandaVault] Error: \(error)")
                    break
                }
            }
            assets = all
            rebuildMonthlyCache(all)
            hasMore = false
        } else {
            let offset = assets.count
            do {
                let newAssets = try await api.getAssets(limit: pageSize, offset: offset)
                assets.append(contentsOf: newAssets)
                appendToMonthlyCache(assets: newAssets)
                hasMore = newAssets.count >= pageSize
            } catch { print("[PandaVault] Error: \(error)") }
        }
    }

    // MARK: - Timeline

    /// 同时加载 timeline + 所有 assets，一起更新 UI 避免中间态
    func loadTimelineAndAssets() async {
        isLoading = true
        defer { isLoading = false }

        // 并发加载 timeline 和 assets
        async let timelineTask = api.getTimeline()
        async let assetsTask = loadAllAssets()

        // 等两个都完成
        let allAssets = await assetsTask
        assets = allAssets
        rebuildMonthlyCache(allAssets)
        hasMore = false
        isImageSearchResult = false

        do {
            let days = try await timelineTask
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
        } catch { print("[PandaVault] loadTimeline error: \(error)") }
    }

    private func loadAllAssets() async -> [Asset] {
        var all: [Asset] = []
        var offset = 0
        while true {
            do {
                let batch = try await api.getAssets(limit: 200, offset: offset)
                all.append(contentsOf: batch)
                if batch.count < 200 { break }
                offset += batch.count
            } catch {
                print("[PandaVault] loadAssets error: \(error)")
                break
            }
        }
        return all
    }

    func loadTimeline() async {
        // 保留兼容，实际用 loadTimelineAndAssets
        await loadTimelineAndAssets()
    }

    func assetsForMonth(_ month: String) -> [Asset] {
        monthlyAssets[month] ?? []
    }

    /// 按时间轴顺序排列的所有资产（用于详情页左右滑动）
    var allAssetsOrdered: [Asset] {
        timeline.flatMap { assetsForMonth($0.month) }
    }

    private func rebuildMonthlyCache(_ all: [Asset]) {
        monthlyAssets = [:]
        appendToMonthlyCache(assets: all)
    }

    private func appendToMonthlyCache(assets list: [Asset]) {
        for asset in list {
            let month = monthForAsset(asset)
            monthlyAssets[month, default: []].append(asset)
        }
    }

    /// 用 shootAt 优先（和后端 timeline 一致），fallback 到 createdAt
    func monthForAsset(_ asset: Asset) -> String {
        let date = asset.shootAt ?? asset.createdAt
        let cal = Calendar.current
        let y = cal.component(.year, from: date)
        let m = cal.component(.month, from: date)
        return String(format: "%04d-%02d", y, m)
    }

    // MARK: - Search (默认 AI 语义搜索，降级到文件名)

    func search() async {
        guard !searchText.isEmpty else {
            await loadAssets(refresh: true)
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
        Task { await loadAssets(refresh: true) }
    }

    func loadMoreIfNeeded(current: Asset) {
        guard let index = assets.firstIndex(of: current) else { return }
        if index >= assets.count - 10 {
            Task { await loadAssets() }
        }
    }
}
