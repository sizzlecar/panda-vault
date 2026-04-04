import SwiftUI

@MainActor
final class GalleryViewModel: ObservableObject {
    @Published var assets: [Asset] = []
    @Published var isLoading = false
    @Published var searchText = ""
    @Published var hasMore = true
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

        let offset = refresh ? 0 : assets.count
        do {
            let newAssets = try await api.getAssets(limit: pageSize, offset: offset)
            if refresh {
                assets = newAssets
                rebuildMonthlyCache(newAssets)
            } else {
                assets.append(contentsOf: newAssets)
                appendToMonthlyCache(newAssets)
            }
            hasMore = newAssets.count >= pageSize
        } catch { print("[PandaVault] Error: \(error)") }
    }

    // MARK: - Timeline

    func loadTimeline() async {
        do {
            let days = try await api.getTimeline()
            // 按月聚合
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
        } catch { print("[PandaVault] Error: \(error)") }
    }

    func assetsForMonth(_ month: String) -> [Asset] {
        monthlyAssets[month] ?? []
    }

    /// 按时间轴顺序排列的所有资产（用于详情页左右滑动）
    var allAssetsOrdered: [Asset] {
        timeline.flatMap { assetsForMonth($0.month) }
    }

    private func rebuildMonthlyCache(_ assets: [Asset]) {
        monthlyAssets = [:]
        appendToMonthlyCache(assets)
    }

    private func appendToMonthlyCache(_ assets: [Asset]) {
        for asset in assets {
            let month = monthFromDate(asset.createdAt)
            monthlyAssets[month, default: []].append(asset)
        }
    }

    private func monthFromDate(_ date: Date) -> String {
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
            hasMore = false
        } catch { print("[PandaVault] Error: \(error)") }
    }

    func loadMoreIfNeeded(current: Asset) {
        guard let index = assets.firstIndex(of: current) else { return }
        if index >= assets.count - 10 {
            Task { await loadAssets() }
        }
    }
}
