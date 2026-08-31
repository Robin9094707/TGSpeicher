import Foundation
import Network

@MainActor
final class TGNetworkMonitor: ObservableObject {
    @Published private(set) var isConnected = true
    @Published private(set) var isExpensive = false
    @Published private(set) var isConstrained = false
    @Published private(set) var interfaceName = "Network"

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "eu.simplexsmp.tgspeicher.network-monitor")

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self else { return }
                self.isConnected = path.status == .satisfied
                self.isExpensive = path.isExpensive
                self.isConstrained = path.isConstrained
                if path.usesInterfaceType(.wifi) { self.interfaceName = "Wi‑Fi" }
                else if path.usesInterfaceType(.cellular) { self.interfaceName = "Cellular" }
                else if path.usesInterfaceType(.wiredEthernet) { self.interfaceName = "Ethernet" }
                else { self.interfaceName = path.status == .satisfied ? "Network" : "Offline" }
            }
        }
        monitor.start(queue: queue)
    }

    deinit { monitor.cancel() }
}

enum TGProxyType: String, CaseIterable, Identifiable {
    case socks5
    case http
    case mtproto

    var id: String { rawValue }
    var label: String {
        switch self {
        case .socks5: return "SOCKS5"
        case .http: return "HTTP"
        case .mtproto: return "MTProto"
        }
    }
}

@MainActor
final class TGProxyManager: ObservableObject {
    @Published var enabled: Bool
    @Published var type: TGProxyType
    @Published var server: String
    @Published var portText: String
    @Published var username: String
    @Published var secret: String
    @Published private(set) var status = "Direct connection"
    @Published private(set) var activeProxyID: Int?
    @Published var lastError: String?

    private enum Keys {
        static let enabled = "network.proxy.enabled"
        static let type = "network.proxy.type"
        static let server = "network.proxy.server"
        static let port = "network.proxy.port"
        static let username = "network.proxy.username"
        static let password = "network.proxy.password"
    }

    init() {
        let defaults = UserDefaults.standard
        enabled = defaults.bool(forKey: Keys.enabled)
        type = TGProxyType(rawValue: defaults.string(forKey: Keys.type) ?? "socks5") ?? .socks5
        server = defaults.string(forKey: Keys.server) ?? ""
        let port = defaults.integer(forKey: Keys.port)
        portText = port > 0 ? String(port) : "1080"
        username = defaults.string(forKey: Keys.username) ?? ""
        secret = KeychainStore.get(Keys.password) ?? ""
    }

    func apply(using telegram: TelegramClient) {
        let cleanServer = server.trimmingCharacters(in: .whitespacesAndNewlines)
        guard enabled else {
            telegram.send(["@type": "disableProxy"]) { [weak self] response in
                guard let self else { return }
                if response["@type"] as? String == "error" {
                    self.lastError = response["message"] as? String ?? "Could not disable the proxy."
                } else {
                    self.activeProxyID = nil
                    self.status = "Direct connection"
                    self.save()
                }
            }
            return
        }

        guard !cleanServer.isEmpty, let port = Int(portText), (1...65535).contains(port) else {
            lastError = "Enter a valid proxy server and port."
            return
        }

        let proxyType: [String: Any]
        switch type {
        case .socks5:
            proxyType = [
                "@type": "proxyTypeSocks5",
                "username": username,
                "password": secret
            ]
        case .http:
            proxyType = [
                "@type": "proxyTypeHttp",
                "username": username,
                "password": secret,
                "http_only": false
            ]
        case .mtproto:
            proxyType = [
                "@type": "proxyTypeMtproto",
                "secret": secret
            ]
        }

        status = "Connecting through \(type.label)…"
        lastError = nil
        telegram.send([
            "@type": "addProxy",
            "server": cleanServer,
            "port": port,
            "enable": true,
            "type": proxyType
        ]) { [weak self] response in
            guard let self else { return }
            if response["@type"] as? String == "error" {
                self.status = "Proxy connection failed"
                self.lastError = response["message"] as? String ?? "Telegram rejected the proxy configuration."
                return
            }
            self.activeProxyID = TelegramClient.int(response["id"])
            self.status = "Connected through \(self.type.label)"
            self.save()
        }
    }

    func ping(using telegram: TelegramClient) {
        guard let id = activeProxyID else {
            lastError = "Apply the proxy first."
            return
        }
        status = "Testing proxy…"
        telegram.send(["@type": "pingProxy", "proxy_id": id]) { [weak self] response in
            guard let self else { return }
            if response["@type"] as? String == "error" {
                self.status = "Proxy test failed"
                self.lastError = response["message"] as? String ?? "Proxy test failed."
            } else if let seconds = response["seconds"] as? Double {
                self.status = String(format: "Proxy latency %.0f ms", seconds * 1000)
            } else {
                self.status = "Proxy reachable"
            }
        }
    }

    private func save() {
        let defaults = UserDefaults.standard
        defaults.set(enabled, forKey: Keys.enabled)
        defaults.set(type.rawValue, forKey: Keys.type)
        defaults.set(server, forKey: Keys.server)
        defaults.set(Int(portText) ?? 0, forKey: Keys.port)
        defaults.set(username, forKey: Keys.username)
        KeychainStore.set(secret, for: Keys.password)
    }
}
