import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Darwin
import Foundation
import Observation

/// 局域网内通过 Bonjour/mDNS 发现的 Android 无线调试端点。
struct DiscoveredADBEndpoint: Identifiable, Sendable, Equatable {
    let id: String
    let serviceName: String
    let host: String
    let port: Int
    let isPairingService: Bool
}

/// 无线扫码配对一次性会话凭证（格式：`WIFI:T:ADB;S:<service>;P:<password>;;`）。
struct ADBQRPairingSession: Sendable, Equatable {
    let serviceName: String
    let password: String

    var qrPayload: String {
        "WIFI:T:ADB;S:\(serviceName);P:\(password);;"
    }

    static func generate() -> ADBQRPairingSession {
        let suffix = randomToken(length: 8, alphabet: Array("abcdefghijklmnopqrstuvwxyz0123456789"))
        let pass = randomToken(length: 8, alphabet: Array("0123456789ABCDEFGHJKLMNPQRSTUVWXYZ"))
        return ADBQRPairingSession(
            serviceName: "ADB_WIFI_\(suffix)",
            password: pass
        )
    }

    private static func randomToken(length: Int, alphabet: [Character]) -> String {
        String((0..<length).compactMap { _ in alphabet.randomElement() })
    }
}

enum QRPairingStatus: Equatable, Sendable {
    case idle
    case waitingScan
    case pairing(String)
    case connecting(String)
    case connected(String)
    case failed(String)

    var message: String {
        switch self {
        case .idle:
            return "未开始扫码配对"
        case .waitingScan:
            return "正在同一 Wi-Fi 下监听手机扫码配对（手机可正常上网）…"
        case .pairing(let endpoint):
            return "已发现手机配对请求（\(endpoint)），正在完成加密配对…"
        case .connecting(let host):
            return "配对成功，正在自动连接 \(host)…"
        case .connected(let endpoint):
            return "已成功无线连接到 \(endpoint)"
        case .failed(let reason):
            return "配对或连接失败：\(reason)"
        }
    }
}

/// 负责局域网 Bonjour/mDNS 监听（`_adb-tls-connect._tcp.` 与 `_adb-tls-pairing._tcp.`）及扫码自动配对连接。
@MainActor
@Observable
final class ADBDiscoveryService {
    private(set) var discoveredConnectEndpoints: [DiscoveredADBEndpoint] = []
    private(set) var discoveredPairingEndpoints: [DiscoveredADBEndpoint] = []
    private(set) var currentQRSession: ADBQRPairingSession?
    private(set) var qrImage: NSImage?
    private(set) var qrPairingStatus: QRPairingStatus = .idle

    private let adbClient: ADBClient
    private let coordinator = BonjourDiscoveryCoordinator()
    private var handledPairingKeys: Set<String> = []
    private var isStartingBrowsing = false
    private var onPairedConnected: (@MainActor () -> Void)?

    init(adbClient: ADBClient) {
        self.adbClient = adbClient
        coordinator.onEndpointsChanged = { [weak self] connectList, pairingList in
            Task { @MainActor [weak self] in
                self?.handleEndpointsUpdate(connectList: connectList, pairingList: pairingList)
            }
        }
    }

    func configureOnConnected(_ handler: @escaping @MainActor () -> Void) {
        onPairedConnected = handler
    }

    func startDiscovery() {
        guard !isStartingBrowsing else { return }
        isStartingBrowsing = true
        coordinator.start()
    }

    func stopDiscovery() {
        isStartingBrowsing = false
        coordinator.stop()
    }

    /// 生成新的二维码会话，并在同一 Wi-Fi 下监听手机扫描后的 mDNS 配对广播。
    func startQRPairingSession() {
        startDiscovery()
        let session = ADBQRPairingSession.generate()
        currentQRSession = session
        qrImage = Self.renderQRCode(from: session.qrPayload)
        qrPairingStatus = .waitingScan
        handledPairingKeys.removeAll()
        handleEndpointsUpdate(connectList: discoveredConnectEndpoints, pairingList: discoveredPairingEndpoints)
    }

    func stopQRPairingSession() {
        if case .waitingScan = qrPairingStatus {
            qrPairingStatus = .idle
        }
    }

    func pairWithCode(host: String, port: Int, code: String) async throws -> String {
        let cleanHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try await adbClient.pair(host: cleanHost, port: port, code: code)
        qrPairingStatus = .connecting(cleanHost)
        if let connectEndpoint = await waitForConnectEndpoint(onHost: cleanHost, timeoutSeconds: 4) {
            let result = try await adbClient.connect(host: connectEndpoint.host, port: connectEndpoint.port)
            qrPairingStatus = .connected("\(connectEndpoint.host):\(connectEndpoint.port)")
            onPairedConnected?()
            return result
        }
        throw DeviceError.underlying("已完成配对，请点击上方「同网已配对设备」中的连接端口，或手动输入无线调试主页的 IP 与连接端口。")
    }

    func connectDirect(host: String, port: Int) async throws -> String {
        let cleanHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let msg = try await adbClient.connect(host: cleanHost, port: port)
        qrPairingStatus = .connected("\(cleanHost):\(port)")
        onPairedConnected?()
        return msg
    }

    static func renderQRCode(from string: String) -> NSImage? {
        guard let data = string.data(using: .utf8) else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = data
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: 220, height: 220))
    }

    private func handleEndpointsUpdate(
        connectList: [DiscoveredADBEndpoint],
        pairingList: [DiscoveredADBEndpoint]
    ) {
        discoveredConnectEndpoints = connectList
        discoveredPairingEndpoints = pairingList

        guard let qr = currentQRSession else { return }
        switch qrPairingStatus {
        case .waitingScan, .failed:
            break
        case .idle, .pairing, .connecting, .connected:
            return
        }

        // AOSP 扫码配对广播的服务名与二维码中的 `S:` 字段完全一致
        if let matched = pairingList.first(where: { $0.serviceName == qr.serviceName }) {
            let dedupKey = "\(matched.serviceName)@\(matched.host):\(matched.port)"
            guard !handledPairingKeys.contains(dedupKey) else { return }
            handledPairingKeys.insert(dedupKey)
            Task { @MainActor [weak self] in
                await self?.executeQRPairAndConnect(endpoint: matched, password: qr.password)
            }
        }
    }

    private func executeQRPairAndConnect(endpoint: DiscoveredADBEndpoint, password: String) async {
        qrPairingStatus = .pairing("\(endpoint.host):\(endpoint.port)")
        do {
            _ = try await adbClient.pair(host: endpoint.host, port: endpoint.port, code: password)
            qrPairingStatus = .connecting(endpoint.host)
            if let connectEndpoint = await waitForConnectEndpoint(onHost: endpoint.host, timeoutSeconds: 6) {
                _ = try await adbClient.connect(host: connectEndpoint.host, port: connectEndpoint.port)
                qrPairingStatus = .connected("\(connectEndpoint.host):\(connectEndpoint.port)")
                onPairedConnected?()
            } else {
                qrPairingStatus = .failed("配对已完成，但未检测到手机连接端口，请切换到「同网与配对码」手动点击连接。")
            }
        } catch {
            qrPairingStatus = .failed(error.localizedDescription)
        }
    }

    private func waitForConnectEndpoint(onHost host: String, timeoutSeconds: TimeInterval) async -> DiscoveredADBEndpoint? {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if let match = discoveredConnectEndpoints.first(where: { $0.host == host }) {
                return match
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return nil
    }
}

private final class BonjourDiscoveryCoordinator: NSObject, NetServiceBrowserDelegate, NetServiceDelegate, @unchecked Sendable {
    var onEndpointsChanged: (@Sendable ([DiscoveredADBEndpoint], [DiscoveredADBEndpoint]) -> Void)?

    private var connectBrowser: NetServiceBrowser?
    private var pairingBrowser: NetServiceBrowser?
    private var resolvingServices: [NetService] = []
    private var connectEndpoints: [String: DiscoveredADBEndpoint] = [:]
    private var pairingEndpoints: [String: DiscoveredADBEndpoint] = [:]

    func start() {
        if Thread.isMainThread {
            startOnMain()
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.startOnMain()
            }
        }
    }

    private func startOnMain() {
        stopOnMain()

        let cBrowser = NetServiceBrowser()
        cBrowser.delegate = self
        cBrowser.searchForServices(ofType: "_adb-tls-connect._tcp.", inDomain: "local.")
        connectBrowser = cBrowser

        let pBrowser = NetServiceBrowser()
        pBrowser.delegate = self
        pBrowser.searchForServices(ofType: "_adb-tls-pairing._tcp.", inDomain: "local.")
        pairingBrowser = pBrowser
    }

    func stop() {
        if Thread.isMainThread {
            stopOnMain()
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.stopOnMain()
            }
        }
    }

    private func stopOnMain() {
        connectBrowser?.stop()
        connectBrowser = nil
        pairingBrowser?.stop()
        pairingBrowser = nil
        for service in resolvingServices {
            service.stop()
        }
        resolvingServices.removeAll()
        connectEndpoints.removeAll()
        pairingEndpoints.removeAll()
        notify()
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        service.delegate = self
        if !resolvingServices.contains(where: { $0.name == service.name && $0.type == service.type }) {
            resolvingServices.append(service)
        }
        service.resolve(withTimeout: 5.0)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        let isPairing = service.type.contains("pairing")
        if isPairing {
            pairingEndpoints.removeValue(forKey: service.name)
        } else {
            connectEndpoints.removeValue(forKey: service.name)
        }
        resolvingServices.removeAll { $0.name == service.name && $0.type == service.type }
        if !moreComing {
            notify()
        }
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        guard sender.port > 0,
              let host = Self.extractHostAddress(from: sender.addresses) else {
            return
        }
        let isPairing = sender.type.contains("pairing")
        let endpoint = DiscoveredADBEndpoint(
            id: "\(sender.name)@\(host):\(sender.port)",
            serviceName: sender.name,
            host: host,
            port: sender.port,
            isPairingService: isPairing
        )
        if isPairing {
            pairingEndpoints[sender.name] = endpoint
        } else {
            connectEndpoints[sender.name] = endpoint
        }
        notify()
    }

    private func notify() {
        let connects = connectEndpoints.values.sorted { $0.serviceName.localizedStandardCompare($1.serviceName) == .orderedAscending }
        let pairings = pairingEndpoints.values.sorted { $0.serviceName.localizedStandardCompare($1.serviceName) == .orderedAscending }
        onEndpointsChanged?(connects, pairings)
    }

    private static func extractHostAddress(from addresses: [Data]?) -> String? {
        guard let addresses else { return nil }
        var fallbackIPv6: String?
        for addrData in addresses {
            let resolved: (isIPv4: Bool, host: String)? = addrData.withUnsafeBytes { rawBuffer in
                guard let baseAddr = rawBuffer.baseAddress?.assumingMemoryBound(to: sockaddr.self) else {
                    return nil
                }
                if Int32(baseAddr.pointee.sa_family) == AF_INET {
                    if var addr = rawBuffer.baseAddress?.assumingMemoryBound(to: sockaddr_in.self).pointee {
                        var hostBuf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                        if let cStr = withUnsafePointer(to: &addr.sin_addr, { ptr in
                            inet_ntop(AF_INET, ptr, &hostBuf, socklen_t(INET_ADDRSTRLEN))
                        }) {
                            return (true, String(cString: cStr))
                        }
                    }
                } else if Int32(baseAddr.pointee.sa_family) == AF_INET6 {
                    if var addr6 = rawBuffer.baseAddress?.assumingMemoryBound(to: sockaddr_in6.self).pointee {
                        var hostBuf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                        if let cStr = withUnsafePointer(to: &addr6.sin6_addr, { ptr in
                            inet_ntop(AF_INET6, ptr, &hostBuf, socklen_t(INET6_ADDRSTRLEN))
                        }) {
                            let ip6 = String(cString: cStr)
                            if !ip6.hasPrefix("fe80:") {
                                return (false, ip6)
                            }
                        }
                    }
                }
                return nil
            }
            if let resolved {
                if resolved.isIPv4 {
                    return resolved.host
                }
                fallbackIPv6 = fallbackIPv6 ?? resolved.host
            }
        }
        return fallbackIPv6
    }
}
