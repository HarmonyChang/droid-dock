import Foundation

/// 封装 Android `adb` 命令行调用（用于同网无线调试配对、连接、目录枚举与流式 `pull`/`push`）。
actor ADBClient {
    struct WirelessDeviceEntry: Sendable, Equatable {
        let serial: String
        let model: String
        let state: String
    }

    private let appSupportToolsDir: URL

    init(appSupportToolsDir: URL? = nil) {
        if let appSupportToolsDir {
            self.appSupportToolsDir = appSupportToolsDir
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
            self.appSupportToolsDir = appSupport
                .appendingPathComponent("com.droiddock.app", isDirectory: true)
                .appendingPathComponent("platform-tools", isDirectory: true)
        }
    }

    /// 查找系统或应用内可用的 `adb` 可执行文件。
    nonisolated func locateExecutableURL() -> URL? {
        var candidates: [URL] = []
        if let bundled = Bundle.main.url(forResource: "adb", withExtension: nil) {
            candidates.append(bundled)
        }
        candidates.append(appSupportToolsDir.appendingPathComponent("adb"))
        candidates.append(URL(fileURLWithPath: "/opt/homebrew/bin/adb"))
        candidates.append(URL(fileURLWithPath: "/usr/local/bin/adb"))
        let home = FileManager.default.homeDirectoryForCurrentUser
        candidates.append(home.appendingPathComponent("Library/Android/sdk/platform-tools/adb"))

        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    func isAvailable() -> Bool {
        locateExecutableURL() != nil
    }

    /// 若本机尚未安装 `adb`，自动从 Google 官方仓库下载并解压 `platform-tools` 到应用支持目录。
    func installPlatformToolsIfNeeded() async throws -> URL {
        if let existing = locateExecutableURL() {
            return existing
        }
        guard let downloadURL = URL(string: "https://dl.google.com/android/repository/platform-tools-latest-darwin.zip") else {
            throw DeviceError.underlying("无效的 platform-tools 下载地址")
        }

        let parentDir = appSupportToolsDir.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)

        let (tempZipURL, response) = try await URLSession.shared.download(from: downloadURL)
        defer { try? FileManager.default.removeItem(at: tempZipURL) }
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw DeviceError.underlying("下载 Android 无线组件失败（HTTP \(http.statusCode)）")
        }

        if FileManager.default.fileExists(atPath: appSupportToolsDir.path) {
            try? FileManager.default.removeItem(at: appSupportToolsDir)
        }

        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-xk", tempZipURL.path, parentDir.path]
        try unzip.run()
        unzip.waitUntilExit()

        let adbURL = appSupportToolsDir.appendingPathComponent("adb")
        guard unzip.terminationStatus == 0, FileManager.default.fileExists(atPath: adbURL.path) else {
            throw DeviceError.underlying("解压 Android 无线组件失败")
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: adbURL.path)
        return adbURL
    }

    func run(_ arguments: [String], timeout: TimeInterval = 20) async throws -> String {
        guard let adbURL = locateExecutableURL() else {
            throw DeviceError.underlying("未找到无线连接组件（adb），请在无线连接弹窗中一键安装。")
        }
        return try await Self.executeProcess(executable: adbURL, arguments: arguments, timeout: timeout)
    }

    func runTransfer(
        _ arguments: [String],
        pollIntervalNanoseconds: UInt64 = 100_000_000,
        onTick: (@Sendable () async -> Void)? = nil
    ) async throws -> String {
        guard let adbURL = locateExecutableURL() else {
            throw DeviceError.underlying("未找到无线连接组件（adb）")
        }

        let pollTask: Task<Void, Never>? = onTick.map { tickHandler in
            Task {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
                    guard !Task.isCancelled else { break }
                    await tickHandler()
                }
            }
        }

        do {
            let output = try await Self.executeProcess(executable: adbURL, arguments: arguments, timeout: nil)
            pollTask?.cancel()
            await pollTask?.value
            return output
        } catch {
            pollTask?.cancel()
            await pollTask?.value
            throw error
        }
    }

    @discardableResult
    func pair(host: String, port: Int, code: String) async throws -> String {
        let trimmedCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, port > 0, !trimmedCode.isEmpty else {
            throw DeviceError.underlying("请填写完整的配对 IP、端口与 6 位配对码")
        }
        let target = Self.formatEndpoint(host: host, port: port)
        let output = try await run(["pair", target, trimmedCode], timeout: 25)
        if output.localizedCaseInsensitiveContains("Successfully paired") {
            return output
        }
        throw DeviceError.underlying(output.isEmpty ? "无线配对失败，请确认手机与 Mac 在同一 Wi-Fi 且配对码未过期。" : output)
    }

    @discardableResult
    func connect(host: String, port: Int) async throws -> String {
        guard !host.isEmpty, port > 0 else {
            throw DeviceError.underlying("请填写完整的连接 IP 与端口")
        }
        let target = Self.formatEndpoint(host: host, port: port)
        let output = try await run(["connect", target], timeout: 15)
        let lower = output.lowercased()
        if lower.contains("connected to") || lower.contains("already connected") {
            return output
        }
        throw DeviceError.underlying(output.isEmpty ? "连接无线设备失败，请确认手机已开启「无线调试」。" : output)
    }

    func disconnect(serial: String) async throws {
        _ = try await run(["disconnect", serial], timeout: 10)
    }

    func connectedWirelessDevices() async throws -> [WirelessDeviceEntry] {
        guard isAvailable() else { return [] }
        let output = try await run(["devices", "-l"], timeout: 10)
        return Self.parseDevicesList(output)
    }

    nonisolated static func parseDevicesList(_ output: String) -> [WirelessDeviceEntry] {
        struct ParsedCandidate {
            let entry: WirelessDeviceEntry
            let dedupKey: String?
            let isMDNS: Bool
        }

        var parsed: [ParsedCandidate] = []
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("List of devices") else { continue }
            let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard parts.count >= 2 else { continue }
            let serial = parts[0]
            let state = parts[1]
            // 仅接管无线会话（IP:Port、mDNS _adb-tls-connect._tcp 或 [IPv6]:Port），避免抢占已有 USB MTP 会话
            let isMDNS = serial.contains("_adb-tls-connect._tcp")
            let isWireless = isMDNS || serial.contains(":") || serial.hasPrefix("adb-")
            guard isWireless else { continue }

            var model = "Android 无线设备"
            var deviceCode = ""
            for token in parts.dropFirst(2) {
                if token.hasPrefix("model:") {
                    model = String(token.dropFirst("model:".count)).replacingOccurrences(of: "_", with: " ")
                } else if token.hasPrefix("device:") {
                    deviceCode = String(token.dropFirst("device:".count))
                }
            }
            let dedupKey = deviceCode.isEmpty ? nil : "\(model)|\(deviceCode)"
            parsed.append(ParsedCandidate(
                entry: WirelessDeviceEntry(serial: serial, model: model, state: state),
                dedupKey: dedupKey,
                isMDNS: isMDNS
            ))
        }

        // 若同一台设备同时存在 IP:Port 与 _adb-tls-connect._tcp 两条会话，去重并优先保留在线及 mDNS 句柄
        var result: [WirelessDeviceEntry] = []
        var bestByKey: [String: Int] = [:]
        for candidate in parsed {
            guard let key = candidate.dedupKey else {
                result.append(candidate.entry)
                continue
            }
            if let existingIndex = bestByKey[key] {
                let existing = result[existingIndex]
                let candidateActive = candidate.entry.state == "device"
                let existingActive = existing.state == "device"
                let existingIsMDNS = existing.serial.contains("_adb-tls-connect._tcp")
                let shouldReplace = (candidateActive && !existingActive)
                    || (candidateActive == existingActive && candidate.isMDNS && !existingIsMDNS)
                if shouldReplace {
                    result[existingIndex] = candidate.entry
                }
            } else {
                bestByKey[key] = result.count
                result.append(candidate.entry)
            }
        }
        return result
    }

    private nonisolated static func formatEndpoint(host: String, port: Int) -> String {
        if host.contains(":") && !host.hasPrefix("[") {
            return "[\(host)]:\(port)"
        }
        return "\(host):\(port)"
    }

    private static func executeProcess(
        executable: URL,
        arguments: [String],
        timeout: TimeInterval?
    ) async throws -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = FileHandle.nullDevice

        let collector = ProcessOutputBox()
        let processBox = SendableBox(process)
        let stdoutBox = SendableBox(stdoutPipe)
        let stderrBox = SendableBox(stderrPipe)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                stdoutBox.value.fileHandleForReading.readabilityHandler = { handle in
                    let chunk = handle.availableData
                    if !chunk.isEmpty {
                        collector.appendStdout(chunk)
                    }
                }
                stderrBox.value.fileHandleForReading.readabilityHandler = { handle in
                    let chunk = handle.availableData
                    if !chunk.isEmpty {
                        collector.appendStderr(chunk)
                    }
                }

                let resumeGate = ResumeOnceGate()
                let timeoutBox: SendableBox<DispatchWorkItem>? = timeout.map { seconds in
                    let item = DispatchWorkItem {
                        if processBox.value.isRunning {
                            processBox.value.terminate()
                        }
                        if resumeGate.tryEnter() {
                            stdoutBox.value.fileHandleForReading.readabilityHandler = nil
                            stderrBox.value.fileHandleForReading.readabilityHandler = nil
                            continuation.resume(throwing: DeviceError.underlying("执行无线指令超时"))
                        }
                    }
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds, execute: item)
                    return SendableBox(item)
                }

                processBox.value.terminationHandler = { finished in
                    timeoutBox?.value.cancel()
                    stdoutBox.value.fileHandleForReading.readabilityHandler = nil
                    stderrBox.value.fileHandleForReading.readabilityHandler = nil
                    let tailOut = stdoutBox.value.fileHandleForReading.readDataToEndOfFile()
                    let tailErr = stderrBox.value.fileHandleForReading.readDataToEndOfFile()
                    if !tailOut.isEmpty { collector.appendStdout(tailOut) }
                    if !tailErr.isEmpty { collector.appendStderr(tailErr) }

                    guard resumeGate.tryEnter() else { return }
                    let combined = collector.combinedString().trimmingCharacters(in: .whitespacesAndNewlines)
                    if finished.terminationReason == .uncaughtSignal && Task.isCancelled {
                        continuation.resume(throwing: CancellationError())
                    } else if finished.terminationStatus == 0 {
                        continuation.resume(returning: collector.stdoutString())
                    } else {
                        continuation.resume(throwing: DeviceError.underlying(
                            combined.isEmpty ? "adb 退出码 \(finished.terminationStatus)" : combined
                        ))
                    }
                }

                do {
                    try processBox.value.run()
                } catch {
                    timeoutBox?.value.cancel()
                    stdoutBox.value.fileHandleForReading.readabilityHandler = nil
                    stderrBox.value.fileHandleForReading.readabilityHandler = nil
                    if resumeGate.tryEnter() {
                        continuation.resume(throwing: DeviceError.underlying(error.localizedDescription))
                    }
                }
            }
        } onCancel: {
            if processBox.value.isRunning {
                processBox.value.terminate()
            }
        }
    }
}

private final class SendableBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

private final class ProcessOutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stdout = Data()
    private var stderr = Data()

    func appendStdout(_ data: Data) {
        lock.lock()
        stdout.append(data)
        lock.unlock()
    }

    func appendStderr(_ data: Data) {
        lock.lock()
        stderr.append(data)
        lock.unlock()
    }

    func stdoutString() -> String {
        lock.lock()
        defer { lock.unlock() }
        return String(data: stdout, encoding: .utf8) ?? ""
    }

    func combinedString() -> String {
        lock.lock()
        defer { lock.unlock() }
        let out = String(data: stdout, encoding: .utf8) ?? ""
        let err = String(data: stderr, encoding: .utf8) ?? ""
        if out.isEmpty { return err }
        if err.isEmpty { return out }
        return out + "\n" + err
    }
}

private final class ResumeOnceGate: @unchecked Sendable {
    private let lock = NSLock()
    private var didEnter = false

    func tryEnter() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if didEnter { return false }
        didEnter = true
        return true
    }
}
