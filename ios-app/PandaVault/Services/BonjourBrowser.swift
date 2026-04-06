import Foundation
import Network

@MainActor
final class BonjourBrowser: ObservableObject {
    @Published var discoveredServer: String?
    @Published var isSearching = false
    @Published var debugLog: String = ""

    private var browser: NWBrowser?
    private var resolver: ServiceResolver?

    func startSearch() {
        guard !isSearching else { return }
        isSearching = true
        discoveredServer = nil
        debugLog = ""
        log("开始搜索 _pandavault._tcp ...")

        let params = NWParameters()
        params.includePeerToPeer = true

        let descriptor = NWBrowser.Descriptor.bonjour(type: "_pandavault._tcp", domain: "local.")
        let browser = NWBrowser(for: descriptor, using: params)

        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                self?.log("Browser state: \(state)")
                if case .failed = state {
                    self?.isSearching = false
                }
            }
        }

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in
                self?.log("发现 \(results.count) 个服务")
                for result in results {
                    if case .service(let name, let type, let domain, _) = result.endpoint {
                        self?.log("服务: \(name) type=\(type) domain=\(domain)")
                        self?.resolveWithNetService(name: name, type: type, domain: domain)
                        return
                    }
                }
            }
        }

        browser.start(queue: .main)
        self.browser = browser

        // 15 秒超时
        Task {
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            if self.discoveredServer == nil && self.isSearching {
                self.log("搜索超时")
                self.stopSearch()
            }
        }
    }

    func stopSearch() {
        browser?.cancel()
        browser = nil
        resolver = nil
        isSearching = false
    }

    private func resolveWithNetService(name: String, type: String, domain: String) {
        log("NetService 解析: \(name)")
        let resolver = ServiceResolver(name: name, type: type, domain: domain) { [weak self] result in
            Task { @MainActor in
                switch result {
                case .success(let url):
                    self?.log("解析成功: \(url)")
                    self?.discoveredServer = url
                    self?.isSearching = false
                    self?.browser?.cancel()
                    self?.browser = nil
                case .failure(let error):
                    self?.log("解析失败: \(error)")
                }
            }
        }
        self.resolver = resolver
        resolver.start()
    }

    func log(_ msg: String) {
        print("[Bonjour] \(msg)")
        debugLog += msg + "\n"
    }
}

// MARK: - NetService based resolver

private class ServiceResolver: NSObject, NetServiceDelegate {
    private let service: NetService
    private let completion: (Result<String, Error>) -> Void

    init(name: String, type: String, domain: String, completion: @escaping (Result<String, Error>) -> Void) {
        self.service = NetService(domain: domain, type: type, name: name)
        self.completion = completion
        super.init()
        self.service.delegate = self
    }

    func start() {
        service.resolve(withTimeout: 10)
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        guard let addresses = sender.addresses else {
            completion(.failure(NSError(domain: "Bonjour", code: -1, userInfo: [NSLocalizedDescriptionKey: "无地址"])))
            return
        }

        // 收集所有 IPv4 地址
        var candidates: [(ip: String, isLocal: Bool)] = []
        for data in addresses {
            data.withUnsafeBytes { ptr in
                guard let base = ptr.baseAddress else { return }
                let sa = base.assumingMemoryBound(to: sockaddr.self)
                if sa.pointee.sa_family == UInt8(AF_INET) {
                    var addr = data.withUnsafeBytes { $0.load(as: sockaddr_in.self) }
                    var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                    inet_ntop(AF_INET, &addr.sin_addr, &buf, socklen_t(INET_ADDRSTRLEN))
                    let ip = String(cString: buf)
                    let isLocal = ip.hasPrefix("169.254.") || ip.hasPrefix("127.")
                    candidates.append((ip, isLocal))
                }
            }
        }

        // 优先非 link-local 的 IPv4（WiFi 地址）
        if let best = candidates.first(where: { !$0.isLocal }) {
            let url = "http://\(best.ip):\(sender.port)"
            completion(.success(url))
            return
        }

        // 只有 link-local(169.254.x.x) 或 loopback 时，用 .local hostname 代替
        if let hostName = sender.hostName {
            let host = hostName.hasSuffix(".") ? String(hostName.dropLast()) : hostName
            completion(.success("http://\(host):\(sender.port)"))
            return
        }

        completion(.failure(NSError(domain: "Bonjour", code: -2, userInfo: [NSLocalizedDescriptionKey: "无可用地址"])))
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        completion(.failure(NSError(domain: "Bonjour", code: -3, userInfo: [NSLocalizedDescriptionKey: "解析失败: \(errorDict)"])))
    }
}
