import Foundation

/// 基于同网无线 ADB 的设备文件提供方（复用 `FileProvider`，零手机端额外 App 即可浏览完整相册与文件系统）。
actor ADBFileProvider: FileProvider {
    private static let remoteStorageRoot = "/storage/emulated/0"
    private static let priorityRootFolders = [
        "DCIM", "Pictures", "Movies", "Download", "Documents", "Music", "Recordings",
    ]

    private let serial: String
    private let client: ADBClient

    init(serial: String, client: ADBClient) {
        self.serial = serial
        self.client = client
    }

    nonisolated static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    nonisolated static func remotePath(from posixPath: String) -> String {
        let normalized = PathUtils.normalize(posixPath)
        if normalized == "/" {
            return remoteStorageRoot
        }
        return remoteStorageRoot + normalized
    }

    nonisolated static func posixPath(from remotePath: String) -> String {
        if remotePath == remoteStorageRoot || remotePath == remoteStorageRoot + "/" {
            return "/"
        }
        if remotePath.hasPrefix(remoteStorageRoot + "/") {
            let trimmed = String(remotePath.dropFirst(remoteStorageRoot.count))
            return PathUtils.normalize(trimmed)
        }
        return PathUtils.normalize(remotePath)
    }

    func storages() async throws -> [StorageInfo] {
        do {
            let out = try await client.run(["-s", serial, "shell", "df -k \(Self.remoteStorageRoot)"], timeout: 10)
            return [Self.parseDFOutput(out)]
        } catch {
            throw Self.mapError(error)
        }
    }

    func list(dir: String, storage: UInt32) async throws -> [RemoteNode] {
        let normalizedDir = PathUtils.normalize(dir)
        let remoteDir = Self.remotePath(from: normalizedDir)
        let cmd = "find \(Self.shellQuote(remoteDir)) -mindepth 1 -maxdepth 1 ! -name '.*' -exec stat -c '%F|%s|%Y|%n' {} + 2>/dev/null || true"
        do {
            let out = try await client.run(["-s", serial, "shell", cmd], timeout: 20)
            let nodes = Self.parseStatLines(out, storage: storage)
            return nodes.sorted { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory {
                    return lhs.isDirectory
                }
                if normalizedDir == "/" && lhs.isDirectory && rhs.isDirectory {
                    let lRank = Self.priorityRootFolders.firstIndex(of: lhs.name) ?? Int.max
                    let rRank = Self.priorityRootFolders.firstIndex(of: rhs.name) ?? Int.max
                    if lRank != rRank {
                        return lRank < rRank
                    }
                }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
        } catch {
            throw Self.mapError(error)
        }
    }

    func listMedia(storage: UInt32, limit: Int) async throws -> [RemoteNode] {
        let roots = ["DCIM", "Pictures", "Movies"].map {
            Self.shellQuote("\(Self.remoteStorageRoot)/\($0)")
        }.joined(separator: " ")
        let cmd = "find \(roots) -maxdepth 3 -type f ! -name '.*' -exec stat -c '%F|%s|%Y|%n' {} + 2>/dev/null || true"
        do {
            let out = try await client.run(["-s", serial, "shell", cmd], timeout: 30)
            let parsed = Self.parseStatLines(out, storage: storage)
            let media = parsed.filter { node in
                !node.isDirectory
                    && !node.path.contains("/.")
                    && (node.kind == .photo || node.kind == .video)
            }.sorted { lhs, rhs in
                let lDate = lhs.modified ?? .distantPast
                let rDate = rhs.modified ?? .distantPast
                if lDate != rDate {
                    return lDate > rDate
                }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedDescending
            }
            return Array(media.prefix(limit))
        } catch {
            throw Self.mapError(error)
        }
    }

    func thumbnail(for node: RemoteNode) async throws -> Data? {
        // ADB 无 MTP 原生 GetThumb；返回 nil 由上层 ThumbnailPipeline 命中磁盘缓存或本地生成 320 px 缩略图
        nil
    }

    func download(_ node: RemoteNode, to url: URL, progress: @Sendable (UInt64) -> Void) async throws {
        guard !node.isDirectory else {
            throw DeviceError.unsupported
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? FileManager.default.removeItem(at: url)

        let remoteFile = Self.remotePath(from: node.path)
        do {
            try await withoutActuallyEscaping(progress) { escapingProgress in
                _ = try await client.runTransfer(["-s", serial, "pull", remoteFile, url.path]) {
                    if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                       let currentSize = (attrs[.size] as? NSNumber)?.uint64Value {
                        escapingProgress(currentSize)
                    }
                }
            }
            if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
               let finalSize = (attrs[.size] as? NSNumber)?.uint64Value {
                progress(finalSize)
            } else {
                progress(node.size)
            }
        } catch let error as CancellationError {
            throw error
        } catch {
            throw Self.mapError(error)
        }
    }

    func upload(
        from url: URL,
        toDir: String,
        remoteName: String?,
        storage: UInt32,
        progress: @Sendable (UInt64) -> Void
    ) async throws -> RemoteNode {
        let filename = remoteName ?? url.lastPathComponent
        if PathUtils.validateAndroidFilename(filename) != nil {
            throw DeviceError.invalidName
        }
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let fileSize = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        let modDate = attrs[.modificationDate] as? Date

        let normalizedDir = PathUtils.normalize(toDir)
        let remoteDir = Self.remotePath(from: normalizedDir)
        let targetPosix = PathUtils.join(normalizedDir, filename)
        let remoteTarget = Self.remotePath(from: targetPosix)

        do {
            _ = try await client.run(["-s", serial, "shell", "mkdir -p \(Self.shellQuote(remoteDir))"], timeout: 10)
            try await withoutActuallyEscaping(progress) { escapingProgress in
                _ = try await client.runTransfer(["-s", serial, "push", url.path, remoteTarget]) {
                    escapingProgress(fileSize / 2)
                }
            }
            progress(fileSize)

            // 通知 Android 媒体库扫描新上传的文件，立即出现在手机系统相册中
            let scanCmd = "am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE -d \(Self.shellQuote("file://" + remoteTarget)) >/dev/null 2>&1 || true"
            _ = try? await client.run(["-s", serial, "shell", scanCmd], timeout: 8)

            return RemoteNode(
                id: "adb:\(storage):\(targetPosix)",
                storageID: storage,
                path: targetPosix,
                name: filename,
                isDirectory: false,
                size: fileSize,
                modified: modDate ?? Date(),
                kind: PathUtils.inferMediaKind(filename: filename)
            )
        } catch let error as CancellationError {
            throw error
        } catch {
            throw Self.mapError(error)
        }
    }

    func delete(_ node: RemoteNode) async throws {
        let remoteTarget = Self.remotePath(from: node.path)
        do {
            _ = try await client.run(["-s", serial, "shell", "rm -rf \(Self.shellQuote(remoteTarget))"], timeout: 15)
        } catch let error as CancellationError {
            throw error
        } catch {
            throw Self.mapError(error)
        }
    }

    func makeDirectory(_ name: String, in dir: String, storage: UInt32) async throws {
        if PathUtils.validateAndroidFilename(name) != nil {
            throw DeviceError.invalidName
        }
        let targetPosix = PathUtils.join(dir, name)
        let remoteTarget = Self.remotePath(from: targetPosix)
        do {
            _ = try await client.run(["-s", serial, "shell", "mkdir -p \(Self.shellQuote(remoteTarget))"], timeout: 10)
        } catch let error as CancellationError {
            throw error
        } catch {
            throw Self.mapError(error)
        }
    }

    func deviceStatus() async throws -> DeviceStatusInfo? {
        let script = [
            "echo '===BATTERY==='; dumpsys battery 2>/dev/null || true",
            "echo '===ANDROID_VER==='; getprop ro.build.version.release 2>/dev/null || true",
            "echo '===WIFI==='; dumpsys wifi 2>/dev/null | grep -E 'Wi-Fi is|mNetworkInfo|SSID:' | head -n 25 || true",
            "echo '===CONN==='; dumpsys connectivity 2>/dev/null | grep -E 'Active default network|NetworkAgentInfo|Transports:|type: WIFI|type: MOBILE|CONNECTED' | head -n 20 || true",
            "echo '===TELEPHONY==='; dumpsys telephony.registry 2>/dev/null | grep -E 'mDataConnectionState|mDataNetworkType|mServiceState|overrideNetworkType|nrState' | head -n 15 || true",
            "echo '===IP==='; ip -o -4 addr show wlan0 2>/dev/null || ifconfig wlan0 2>/dev/null || true",
        ].joined(separator: "; ")

        do {
            let output = try await client.run(["-s", serial, "shell", script], timeout: 8)
            return Self.parseDeviceStatusOutput(output, serial: serial)
        } catch let error as CancellationError {
            throw error
        } catch {
            throw Self.mapError(error)
        }
    }

    // MARK: - 输出解析与错误映射

    nonisolated static func parseDeviceStatusOutput(_ output: String, serial: String) -> DeviceStatusInfo {
        var sections: [String: [String]] = [:]
        var currentSection = ""
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("===") && trimmed.hasSuffix("===") && trimmed.count > 6 {
                currentSection = String(trimmed.dropFirst(3).dropLast(3))
                sections[currentSection, default: []] = []
                continue
            }
            sections[currentSection, default: []].append(line)
        }

        // 1. 电池信息
        var batteryLevel: Int?
        var statusCode: Int?
        var acPowered = false
        var usbPowered = false
        var wirelessPowered = false
        var batteryTemp: Double?

        for rawLine in sections["BATTERY"] ?? [] {
            let parts = rawLine.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let val = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            switch key {
            case "level":
                if let lvl = Int(val), (0...100).contains(lvl) {
                    batteryLevel = lvl
                }
            case "status":
                statusCode = Int(val)
            case "ac powered":
                acPowered = val.lowercased() == "true"
            case "usb powered":
                usbPowered = val.lowercased() == "true"
            case "wireless powered":
                wirelessPowered = val.lowercased() == "true"
            case "temperature":
                if let tenths = Int(val), (-200...1000).contains(tenths) {
                    batteryTemp = Double(tenths) / 10.0
                }
            default:
                break
            }
        }

        let chargingState: BatteryChargingState
        switch statusCode {
        case 2:
            chargingState = .charging
        case 5:
            chargingState = .full
        case 3, 4:
            chargingState = .discharging
        default:
            if acPowered || usbPowered || wirelessPowered {
                chargingState = batteryLevel == 100 ? .full : .charging
            } else if batteryLevel != nil {
                chargingState = .discharging
            } else {
                chargingState = .unknown
            }
        }

        // 2. 系统版本
        let verRaw = (sections["ANDROID_VER"] ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        let androidVersion = verRaw.map { "Android \($0)" }

        // 3. Wi-Fi SSID 与网络状态
        let wifiText = (sections["WIFI"] ?? []).joined(separator: "\n")
        let connText = (sections["CONN"] ?? []).joined(separator: "\n")
        let telText = (sections["TELEPHONY"] ?? []).joined(separator: "\n")

        let wifiSSID = extractWiFiSSID(from: wifiText)
        let wifiConnectedInWifiDump = wifiText.contains("CONNECTED/CONNECTED")
            || wifiText.contains("state: CONNECTED")
            || (wifiText.contains("Wi-Fi is enabled") && wifiSSID != nil)
        let connLower = connText.lowercased()
        let connHasWiFi = (connText.contains("type: WIFI") && connText.contains("CONNECTED"))
            || (connText.contains("Transports: WIFI") && (connText.contains("CONNECTED") || connText.contains("VALIDATED")))
        let connHasEthernet = (connText.contains("type: ETHERNET") && connText.contains("CONNECTED"))
            || (connText.contains("Transports: ETHERNET") && connText.contains("CONNECTED"))
        let connHasCellular = (connText.contains("type: MOBILE") && connText.contains("CONNECTED"))
            || (connText.contains("Transports: CELLULAR") && (connText.contains("CONNECTED") || connText.contains("VALIDATED")))
        let telUpper = telText.uppercased()
        let telConnected = telText.contains("mDataConnectionState=2")

        let networkType: DeviceNetworkType
        if connHasWiFi || (wifiConnectedInWifiDump && !connHasCellular && !connHasEthernet) {
            networkType = .wifi
        } else if connHasEthernet {
            networkType = .ethernet
        } else if connHasCellular || telConnected {
            if telUpper.contains("NR") || telUpper.contains("5G") || telText.contains("dataNetworkType=20") || telText.contains("mDataNetworkType=20") {
                networkType = .cellular5G
            } else if telUpper.contains("LTE") || telText.contains("dataNetworkType=13") || telText.contains("mDataNetworkType=13") || telText.contains("dataNetworkType=19") {
                networkType = .cellular4G
            } else if telUpper.contains("UMTS") || telUpper.contains("HSPA") || telUpper.contains("HSDPA") || telText.contains("dataNetworkType=3") || telText.contains("dataNetworkType=15") {
                networkType = .cellular3G
            } else {
                networkType = .cellular
            }
        } else if connLower.contains("active default network: none") || !connText.isEmpty || !wifiText.isEmpty {
            networkType = .offline
        } else {
            networkType = .unavailable
        }

        // 4. 局域网 IPv4
        let ipSection = (sections["IP"] ?? []).joined(separator: "\n")
        let parsedIP = extractIPv4(from: ipSection) ?? extractIPv4FromSerial(serial)

        return DeviceStatusInfo(
            batteryLevel: batteryLevel,
            chargingState: chargingState,
            batteryTempCelsius: batteryTemp,
            networkType: networkType,
            wifiSSID: networkType == .wifi ? wifiSSID : nil,
            ipAddress: parsedIP,
            androidVersion: androidVersion,
            connectionDetail: "Wi-Fi 无线调试 (ADB)",
            updatedAt: Date()
        )
    }

    private nonisolated static func extractWiFiSSID(from text: String) -> String? {
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            guard let range = line.range(of: "SSID:") else { continue }
            var tail = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            if tail.hasPrefix("\"") {
                tail.removeFirst()
                if let endQuote = tail.firstIndex(of: "\"") {
                    tail = String(tail[..<endQuote])
                }
            } else if let comma = tail.range(of: ", BSSID:") {
                tail = String(tail[..<comma.lowerBound])
            } else if let comma = tail.firstIndex(of: ",") {
                tail = String(tail[..<comma])
            }
            let cleaned = tail.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty && cleaned.lowercased() != "<unknown ssid>" && cleaned.lowercased() != "null" {
                return cleaned
            }
        }
        return nil
    }

    private nonisolated static func extractIPv4(from text: String) -> String? {
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if let inetRange = line.range(of: "inet addr:") {
                let candidate = String(line[inetRange.upperBound...]).split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
                if isValidIPv4(candidate) { return candidate }
            } else if let inetRange = line.range(of: "inet ") {
                let token = String(line[inetRange.upperBound...]).split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
                let ip = token.split(separator: "/", maxSplits: 1).first.map(String.init) ?? ""
                if isValidIPv4(ip) { return ip }
            }
        }
        return nil
    }

    private nonisolated static func extractIPv4FromSerial(_ serial: String) -> String? {
        guard let colon = serial.firstIndex(of: ":") else { return nil }
        let host = String(serial[..<colon])
        return isValidIPv4(host) ? host : nil
    }

    private nonisolated static func isValidIPv4(_ str: String) -> Bool {
        let parts = str.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { Int($0).map { (0...255).contains($0) } ?? false }
    }

    nonisolated static func parseDFOutput(_ output: String) -> StorageInfo {
        let lines = output.split(whereSeparator: \.isNewline).map(String.init)
        if let dataLine = lines.last(where: { !$0.lowercased().hasPrefix("filesystem") }) {
            let cols = dataLine.split(whereSeparator: \.isWhitespace).map(String.init)
            if cols.count >= 4,
               let totalKB = UInt64(cols[1]),
               let availKB = UInt64(cols[3]) {
                return StorageInfo(
                    id: 1,
                    name: "内部共享存储空间",
                    totalBytes: totalKB * 1024,
                    freeBytes: availKB * 1024
                )
            }
        }
        return StorageInfo(id: 1, name: "内部共享存储空间", totalBytes: 0, freeBytes: 0)
    }

    nonisolated static func parseStatLines(_ output: String, storage: UInt32) -> [RemoteNode] {
        var nodes: [RemoteNode] = []
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            let parts = line.split(separator: "|", maxSplits: 3, omittingEmptySubsequences: false)
            guard parts.count == 4 else { continue }

            let typeStr = String(parts[0]).lowercased()
            let sizeVal = UInt64(parts[1]) ?? 0
            let mtimeSec = TimeInterval(parts[2])
            let fullRemotePath = String(parts[3])
            guard fullRemotePath != remoteStorageRoot else { continue }

            let posix = posixPath(from: fullRemotePath)
            let name = PathUtils.filename(of: posix)
            guard !name.isEmpty, name != "/", !name.hasPrefix(".") else { continue }

            let isDirectory = typeStr.contains("directory")
            let kind: MediaKind = isDirectory ? .other : PathUtils.inferMediaKind(filename: name)
            nodes.append(RemoteNode(
                id: "adb:\(storage):\(posix)",
                storageID: storage,
                path: posix,
                name: name,
                isDirectory: isDirectory,
                size: isDirectory ? 0 : sizeVal,
                modified: mtimeSec.map { Date(timeIntervalSince1970: $0) },
                kind: kind
            ))
        }
        return nodes
    }

    private nonisolated static func mapError(_ error: Error) -> DeviceError {
        if let deviceError = error as? DeviceError {
            return deviceError
        }
        let msg = error.localizedDescription.lowercased()
        if msg.contains("unauthorized") {
            return .deviceLocked
        }
        if msg.contains("no devices") || msg.contains("not found") || msg.contains("offline") || msg.contains("closed") {
            return .disconnected
        }
        if msg.contains("no space left") {
            return .storageFull
        }
        if msg.contains("permission denied") {
            return .permissionDenied
        }
        return .underlying(error.localizedDescription)
    }
}

/// 监听同网已配对无线 ADB 设备的自动发现与连接状态。
final class ADBDeviceBackend: DeviceBackend, @unchecked Sendable {
    private actor Coordinator {
        struct Entry {
            let info: DeviceInfo
            let state: DeviceState
            let provider: ADBFileProvider
        }

        private let client: ADBClient
        private weak var discovery: ADBDiscoveryService?
        private var continuations: [UUID: AsyncStream<DeviceEvent>.Continuation] = [:]
        private var entries: [DeviceID: Entry] = [:]
        private var pollTask: Task<Void, Never>?
        private var lastConnectAttempt: [String: Date] = [:]
        private var isRefreshing = false

        init(client: ADBClient, discovery: ADBDiscoveryService) {
            self.client = client
            self.discovery = discovery
        }

        func addStream() -> AsyncStream<DeviceEvent> {
            let id = UUID()
            return AsyncStream { continuation in
                continuations[id] = continuation
                continuation.onTermination = { [weak self] _ in
                    Task { await self?.removeStream(id) }
                }
                for entry in entries.values {
                    continuation.yield(.attached(entry.info))
                    continuation.yield(.stateChanged(entry.info.id, entry.state))
                }
                startPollingIfNeeded()
                Task { await refreshNow() }
            }
        }

        func open(_ id: DeviceID) throws -> any FileProvider {
            guard let entry = entries[id] else {
                throw DeviceError.disconnected
            }
            return entry.provider
        }

        func refreshNow() async {
            guard !isRefreshing else { return }
            isRefreshing = true
            defer { isRefreshing = false }

            // 先对局域网内已配对的 _adb-tls-connect._tcp. 设备做静默自动连接
            await autoConnectDiscoveredEndpoints()

            let list = (try? await client.connectedWirelessDevices()) ?? []
            var seenIDs: Set<DeviceID> = []

            for item in list where item.state == "device" || item.state == "unauthorized" {
                let id = DeviceID(rawValue: "wifi:\(item.serial)")
                seenIDs.insert(id)
                let state: DeviceState = item.state == "unauthorized" ? .locked : .ready

                if let existing = entries[id] {
                    if existing.state != state {
                        entries[id] = Entry(info: existing.info, state: state, provider: existing.provider)
                        emit(.stateChanged(id, state))
                    }
                    continue
                }

                let info = DeviceInfo(
                    id: id,
                    name: item.model,
                    manufacturer: "Android",
                    model: item.model,
                    serialNumber: item.serial,
                    transport: .wifi
                )
                let provider = ADBFileProvider(serial: item.serial, client: client)
                entries[id] = Entry(info: info, state: state, provider: provider)
                Log.device.info("Connected wireless ADB device: \(item.model, privacy: .public) (\(item.serial, privacy: .public))")
                emit(.attached(info))
                emit(.stateChanged(id, state))
            }

            for existingID in entries.keys where !seenIDs.contains(existingID) {
                if let removed = entries.removeValue(forKey: existingID) {
                    Log.device.info("Detached wireless ADB device: \(removed.info.name, privacy: .public)")
                    emit(.detached(existingID))
                }
            }
        }

        private func autoConnectDiscoveredEndpoints() async {
            guard await client.isAvailable() else { return }
            let discoveryService = discovery
            let endpoints: [DiscoveredADBEndpoint] = await MainActor.run {
                discoveryService?.discoveredConnectEndpoints ?? []
            }
            guard !endpoints.isEmpty else { return }

            let connectedSerials = Set(((try? await client.connectedWirelessDevices()) ?? []).map(\.serial))
            let now = Date()

            for endpoint in endpoints {
                let target = "\(endpoint.host):\(endpoint.port)"
                if connectedSerials.contains(target) || connectedSerials.contains(where: { $0.contains(endpoint.serviceName) }) {
                    continue
                }
                if let last = lastConnectAttempt[endpoint.id], now.timeIntervalSince(last) < 15 {
                    continue
                }
                lastConnectAttempt[endpoint.id] = now
                _ = try? await client.connect(host: endpoint.host, port: endpoint.port)
            }
        }

        private func startPollingIfNeeded() {
            guard pollTask == nil else { return }
            let discoveryService = discovery
            Task { @MainActor in
                discoveryService?.startDiscovery()
            }
            pollTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 2_500_000_000)
                    guard !Task.isCancelled, let self else { return }
                    await self.refreshNow()
                }
            }
        }

        private func removeStream(_ id: UUID) {
            continuations[id] = nil
        }

        private func emit(_ event: DeviceEvent) {
            for continuation in continuations.values {
                continuation.yield(event)
            }
        }
    }

    private let coordinator: Coordinator

    init(client: ADBClient, discovery: ADBDiscoveryService) {
        self.coordinator = Coordinator(client: client, discovery: discovery)
    }

    func events() -> AsyncStream<DeviceEvent> {
        AsyncStream { continuation in
            let forwardTask = Task {
                for await event in await coordinator.addStream() {
                    continuation.yield(event)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                forwardTask.cancel()
            }
        }
    }

    func open(_ id: DeviceID) async throws -> any FileProvider {
        try await coordinator.open(id)
    }

    func refresh() async {
        await coordinator.refreshNow()
    }
}
