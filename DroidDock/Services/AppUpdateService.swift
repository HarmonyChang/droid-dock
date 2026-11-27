import AppKit
import CryptoKit
import Foundation
import Observation

/// 语义化版本号解析与比较（支持 `v0.2.0`、`0.2.0`、`0.2.0-beta.1`）。
struct SemanticVersion: Comparable, Sendable, Equatable, Hashable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int
    let preRelease: String?

    init?(_ rawString: String) {
        var cleaned = rawString.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("v") || cleaned.hasPrefix("V") {
            cleaned.removeFirst()
        }
        if let plusIndex = cleaned.firstIndex(of: "+") {
            cleaned = String(cleaned[..<plusIndex])
        }
        guard !cleaned.isEmpty else { return nil }

        let corePart: String
        let prePart: String?
        if let dashIndex = cleaned.firstIndex(of: "-") {
            corePart = String(cleaned[..<dashIndex])
            let suffix = String(cleaned[cleaned.index(after: dashIndex)...])
            prePart = suffix.isEmpty ? nil : suffix
        } else {
            corePart = cleaned
            prePart = nil
        }

        let components = corePart.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(components.count) else { return nil }
        var nums: [Int] = []
        for token in components {
            guard let value = Int(token), value >= 0 else { return nil }
            nums.append(value)
        }

        self.major = nums[0]
        self.minor = nums.count > 1 ? nums[1] : 0
        self.patch = nums.count > 2 ? nums[2] : 0
        self.preRelease = prePart
    }

    var description: String {
        let base = "\(major).\(minor).\(patch)"
        return preRelease.map { "\(base)-\($0)" } ?? base
    }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }

        switch (lhs.preRelease, rhs.preRelease) {
        case (nil, nil):
            return false
        case (.some, nil):
            return true
        case (nil, .some):
            return false
        case (.some(let lPre), .some(let rPre)):
            return comparePreRelease(lPre, rPre)
        }
    }

    private static func comparePreRelease(_ lhs: String, _ rhs: String) -> Bool {
        let lParts = lhs.split(separator: ".").map(String.init)
        let rParts = rhs.split(separator: ".").map(String.init)
        for idx in 0..<max(lParts.count, rParts.count) {
            if idx >= lParts.count { return true }
            if idx >= rParts.count { return false }
            let lToken = lParts[idx]
            let rToken = rParts[idx]
            if let lNum = Int(lToken), let rNum = Int(rToken) {
                if lNum != rNum { return lNum < rNum }
            } else if lToken != rToken {
                return lToken.localizedStandardCompare(rToken) == .orderedAscending
            }
        }
        return false
    }
}

/// 单条版本更新记录（本地随包内置 + 远端 GitHub Releases 合并）。
struct ChangelogEntry: Identifiable, Sendable, Equatable {
    var id: String { version }
    let version: String
    let title: String
    let releaseDate: String
    let notes: [String]
    let releaseURL: URL?

    static let bundledHistory: [ChangelogEntry] = [
        ChangelogEntry(
            version: "0.2.1",
            title: "界面细节修复、实时存储刷新与视频封面预览",
            releaseDate: "2026-11-27",
            notes: [
                "优化左下角存储空间与设备详情弹窗容量展示（最多 1 位小数且不换行），并在目录增删、传输完成及传输期间每 5 秒自动刷新剩余空间。",
                "修复顶部工具栏视图切换分段器多余截断标签，并将传输队列头部重排为两行布局，解决“同名冲突”筛选词竖排折叠问题。",
                "新增基于 USB MTP GetPartialObject 与无线按需分片的远程视频首帧封面提取（128 KB 块缓存、4 MB 上限与 8 秒超时），并在列表视图接入缩略封面。",
                "补充中英文 README 说明文档与开源 LICENSE。",
            ],
            releaseURL: URL(string: "https://github.com/HarmonyChang/droid-dock/releases/tag/v0.2.1")
        ),
        ChangelogEntry(
            version: "0.2.0",
            title: "超大规模传输稳定性重构与手机状态展示",
            releaseDate: "2026-11-24",
            notes: [
                "新增版本记录查看面板与基于 GitHub Releases 的自动检查、校验与一键升级重启能力。",
                "侧边栏设备卡新增电量与网络（或 USB 链路速率）状态胶囊，点击可查看充电状态、温度、Wi-Fi 名称、5G/4G、IPv4 与系统版本；传输期间自动暂停状态轮询保障带宽。",
                "修复 USB 2.0 512 字节包边界缺少 ZLP 导致的传输卡死，以及瞬时超时误判为永久断线问题。",
                "目录上传改用后台流式扫盘与 O(1) 队列调度，增加远端目录缓存与防 App Nap / 休眠保护，支持十万级文件稳定传输。",
            ],
            releaseURL: URL(string: "https://github.com/HarmonyChang/droid-dock/releases/tag/v0.2.0")
        ),
        ChangelogEntry(
            version: "0.1.1",
            title: "高清大图预览、EXIF 浮窗与相册加载提速",
            releaseDate: "2026-11-17",
            notes: [
                "双击看图支持原图高清预解码，查看器右上角新增半透明 EXIF 拍摄参数与文件路径浮窗。",
                "相册缩略图切换为当前视口优先（LIFO）与 128 KB 局部 EXIF 提取，大幅提升滑动出图速度。",
                "在 MTP 事务锁中补齐取消后排空管道，避免半截响应影响后续预览或缩略图指令。",
            ],
            releaseURL: URL(string: "https://github.com/HarmonyChang/droid-dock/releases/tag/v0.1.1")
        ),
        ChangelogEntry(
            version: "0.1.0",
            title: "首个正式版本发布",
            releaseDate: "2026-11-16",
            notes: [
                "基于 Apple IOUSBHost 实现纯 Swift USB MTP 客户端（USBMTP），支持防第三方进程抢占接口。",
                "支持文件浏览、媒体相册、双向拖拽与断点临时文件保护，以及同名冲突策略切换。",
                "支持同网无线连接双模式（手机相机扫码网页快传 + 无线调试全盘管理）与四套儒雅主题配色。",
            ],
            releaseURL: URL(string: "https://github.com/HarmonyChang/droid-dock/releases/tag/v0.1.0")
        ),
    ]
}

/// 远端可升级版本元数据（来自 GitHub Releases API）。
struct AppUpdateRelease: Sendable, Equatable {
    let tagName: String
    let versionString: String
    let title: String
    let releaseDate: String
    let releaseNotes: String
    let htmlURL: URL
    let downloadURL: URL
    let downloadFilename: String
    let expectedSizeBytes: Int64
    let sha256AssetURL: URL?
    let sha256Inline: String?
}

/// 自动升级状态机。
enum AppUpdateState: Equatable, Sendable {
    case idle
    case checking
    case upToDate(latestVersion: String)
    case available(AppUpdateRelease)
    case downloading(release: AppUpdateRelease, progress: Double, receivedBytes: Int64, totalBytes: Int64)
    case verifying(release: AppUpdateRelease)
    case installing(release: AppUpdateRelease)
    case error(String)
}

/// 版本记录与 GitHub Releases 自动升级管理器（零第三方依赖）。
@MainActor
@Observable
final class AppUpdateService {
    nonisolated static let githubOwner = "HarmonyChang"
    nonisolated static let githubRepo = "droid-dock"
    nonisolated static let expectedBundleIdentifier = "com.droiddock.app"
    nonisolated static let releasesAPIURL = URL(string: "https://api.github.com/repos/\(githubOwner)/\(githubRepo)/releases?per_page=20")
    nonisolated static let releasesPageURL = URL(string: "https://github.com/\(githubOwner)/\(githubRepo)/releases")

    private static let autoCheckDefaultsKey = "droiddock.update.autoCheckEnabled"
    private static let lastCheckDefaultsKey = "droiddock.update.lastCheckedAt"
    private static let skippedVersionDefaultsKey = "droiddock.update.skippedVersion"
    private static let autoCheckIntervalSeconds: TimeInterval = 6 * 3600

    let currentVersionString: String
    let currentBuildString: String

    private(set) var state: AppUpdateState = .idle
    private(set) var remoteReleases: [AppUpdateRelease] = []
    private(set) var lastCheckedAt: Date?
    private(set) var statusNote: String?
    private(set) var skippedVersion: String?
    var autoCheckEnabled: Bool {
        didSet {
            userDefaults.set(autoCheckEnabled, forKey: Self.autoCheckDefaultsKey)
        }
    }

    private let userDefaults: UserDefaults
    private let dataFetcher: @Sendable (URLRequest) async throws -> (Data, URLResponse)
    private var downloadTask: Task<Void, Never>?

    init(
        currentVersionString: String? = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
        currentBuildString: String? = Bundle.main.infoDictionary?["CFBundleVersion"] as? String,
        userDefaults: UserDefaults = .standard,
        dataFetcher: (@Sendable (URLRequest) async throws -> (Data, URLResponse))? = nil
    ) {
        self.currentVersionString = (currentVersionString?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap {
            $0.isEmpty ? nil : $0
        } ?? "0.2.1"
        self.currentBuildString = (currentBuildString?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap {
            $0.isEmpty ? nil : $0
        } ?? "3"
        self.userDefaults = userDefaults
        self.dataFetcher = dataFetcher ?? { request in
            try await URLSession.shared.data(for: request)
        }

        if userDefaults.object(forKey: Self.autoCheckDefaultsKey) != nil {
            self.autoCheckEnabled = userDefaults.bool(forKey: Self.autoCheckDefaultsKey)
        } else {
            self.autoCheckEnabled = true
        }
        self.lastCheckedAt = userDefaults.object(forKey: Self.lastCheckDefaultsKey) as? Date
        self.skippedVersion = userDefaults.string(forKey: Self.skippedVersionDefaultsKey)
    }

    var shouldHighlightUpdate: Bool {
        guard case .available(let release) = state else { return false }
        return release.versionString != skippedVersion
    }

    var isBusy: Bool {
        switch state {
        case .checking, .downloading, .verifying, .installing:
            return true
        case .idle, .upToDate, .available, .error:
            return false
        }
    }

    var mergedChangelog: [ChangelogEntry] {
        var map: [String: ChangelogEntry] = [:]
        for item in ChangelogEntry.bundledHistory {
            let key = SemanticVersion(item.version)?.description ?? item.version
            map[key] = item
        }
        for remoteEntry in Self.convertToChangelogEntries(remoteReleases) {
            let key = SemanticVersion(remoteEntry.version)?.description ?? remoteEntry.version
            if let existing = map[key], remoteEntry.notes.isEmpty {
                map[key] = ChangelogEntry(
                    version: existing.version,
                    title: remoteEntry.title.isEmpty ? existing.title : remoteEntry.title,
                    releaseDate: remoteEntry.releaseDate.isEmpty ? existing.releaseDate : remoteEntry.releaseDate,
                    notes: existing.notes,
                    releaseURL: remoteEntry.releaseURL ?? existing.releaseURL
                )
            } else {
                map[key] = remoteEntry
            }
        }
        return map.values.sorted { lhs, rhs in
            switch (SemanticVersion(lhs.version), SemanticVersion(rhs.version)) {
            case (.some(let lVer), .some(let rVer)):
                return lVer > rVer
            case (.some, nil):
                return true
            case (nil, .some):
                return false
            case (nil, nil):
                return lhs.releaseDate > rhs.releaseDate
            }
        }
    }

    func checkForUpdatesOnLaunchIfNeeded() async {
        guard autoCheckEnabled else { return }
        if let lastCheckedAt, Date().timeIntervalSince(lastCheckedAt) < Self.autoCheckIntervalSeconds {
            return
        }
        await checkForUpdates(userInitiated: false)
    }

    func checkForUpdates(userInitiated: Bool) async {
        guard !isBusy, let apiURL = Self.releasesAPIURL else { return }
        state = .checking
        statusNote = nil

        var request = URLRequest(url: apiURL)
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("DroidDock/\(currentVersionString)", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await dataFetcher(request)
            if let http = response as? HTTPURLResponse {
                if http.statusCode == 404 {
                    recordCheckedTimestamp()
                    remoteReleases = []
                    state = .upToDate(latestVersion: currentVersionString)
                    statusNote = "GitHub Releases 暂未发布任何线上版本，下方已显示本地版本记录。"
                    return
                }
                if http.statusCode == 403 {
                    let msg = "GitHub 接口访问受限（HTTP 403），请稍后再试或手动打开 Releases 页面查看。"
                    state = userInitiated ? .error(msg) : .idle
                    return
                }
                guard (200...299).contains(http.statusCode) else {
                    let msg = "检查更新失败（HTTP \(http.statusCode)）"
                    state = userInitiated ? .error(msg) : .idle
                    return
                }
            }

            let parsed = try Self.parseReleasesJSON(data)
            remoteReleases = parsed
            recordCheckedTimestamp()

            if let newer = Self.findNewerRelease(from: parsed, currentVersion: currentVersionString) {
                state = .available(newer)
            } else {
                let latest = parsed.first?.versionString ?? currentVersionString
                if let skipped = skippedVersion,
                   let skippedSemver = SemanticVersion(skipped),
                   let currentSemver = SemanticVersion(currentVersionString),
                   currentSemver >= skippedSemver {
                    skippedVersion = nil
                    userDefaults.removeObject(forKey: Self.skippedVersionDefaultsKey)
                }
                state = .upToDate(latestVersion: latest)
                statusNote = parsed.isEmpty ? "仓库暂未发布带安装包的 Release，当前版本 \(currentVersionString) 为最新。" : nil
            }
        } catch is CancellationError {
            state = .idle
        } catch {
            Log.ui.error("Update check failed: \(error.localizedDescription, privacy: .public)")
            state = userInitiated ? .error("检查更新失败：\(error.localizedDescription)") : .idle
        }
    }

    func skipAvailableVersion() {
        guard case .available(let release) = state else { return }
        skippedVersion = release.versionString
        userDefaults.set(release.versionString, forKey: Self.skippedVersionDefaultsKey)
        statusNote = "已忽略 v\(release.versionString) 的启动提醒，仍可随时在此页升级。"
    }

    func cancelDownload() {
        guard case .downloading(let release, _, _, _) = state else { return }
        downloadTask?.cancel()
        downloadTask = nil
        state = .available(release)
    }

    func openReleasesPage() {
        guard let url = Self.releasesPageURL else { return }
        NSWorkspace.shared.open(url)
    }

    func downloadAndInstallUpdate(isTransferring: Bool) {
        if isTransferring {
            state = .error("当前正在传输文件，请等待传输完成后再执行升级，以免中断设备连接。")
            return
        }
        guard case .available(let release) = state else { return }

        downloadTask?.cancel()
        downloadTask = Task { [weak self] in
            guard let self else { return }
            await self.performDownloadAndInstall(release: release)
        }
    }

    private func recordCheckedTimestamp() {
        let now = Date()
        lastCheckedAt = now
        userDefaults.set(now, forKey: Self.lastCheckDefaultsKey)
    }

    private func performDownloadAndInstall(release: AppUpdateRelease) async {
        let stagingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("DroidDockUpdate-\(UUID().uuidString)", isDirectory: true)
        var cleanupStagingOnFailure = true
        defer {
            if cleanupStagingOnFailure {
                try? FileManager.default.removeItem(at: stagingRoot)
            }
        }

        do {
            try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
            let packageURL = stagingRoot.appendingPathComponent(release.downloadFilename)

            state = .downloading(
                release: release,
                progress: 0,
                receivedBytes: 0,
                totalBytes: max(0, release.expectedSizeBytes)
            )

            let computedSHA256 = try await Self.streamDownload(
                from: release.downloadURL,
                to: packageURL,
                expectedBytes: release.expectedSizeBytes,
                userAgent: "DroidDock/\(currentVersionString)"
            ) { [weak self] received, total in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let ratio = total > 0 ? min(1, max(0, Double(received) / Double(total))) : 0
                    self.state = .downloading(
                        release: release,
                        progress: ratio,
                        receivedBytes: received,
                        totalBytes: total
                    )
                }
            }

            try Task.checkCancellation()
            state = .verifying(release: release)

            // 若有 .sha256 资产或发布说明内嵌 SHA-256，执行严格完整性校验
            if let expectedDigest = try await resolveExpectedSHA256(for: release) {
                guard expectedDigest.caseInsensitiveCompare(computedSHA256) == .orderedSame else {
                    throw UpdateError.checksumMismatch
                }
            }

            // 解包并校验证书与 Bundle Identifier
            let stagedAppURL = stagingRoot.appendingPathComponent("DroidDock.app", isDirectory: true)
            try await extractAndVerifyAppBundle(
                from: packageURL,
                filename: release.downloadFilename,
                stagingRoot: stagingRoot,
                destinationAppURL: stagedAppURL
            )

            // 确认安装目标目录可写；否则在 Finder 高亮安装包引导用户手动拖放
            guard let targetAppURL = Self.resolveWritableTargetAppURL(currentBundleURL: Bundle.main.bundleURL) else {
                cleanupStagingOnFailure = false
                NSWorkspace.shared.activateFileViewerSelecting([packageURL])
                state = .error("当前安装位置无直接写入权限，已在 Finder 中定位安装包，请手动打开并拖入「应用程序」。")
                return
            }

            state = .installing(release: release)
            let backupAppURL = stagingRoot.appendingPathComponent("DroidDock-backup.app", isDirectory: true)
            let scriptText = Self.buildInstallScript(
                pid: ProcessInfo.processInfo.processIdentifier,
                stagedAppPath: stagedAppURL.path,
                targetAppPath: targetAppURL.path,
                backupAppPath: backupAppURL.path,
                stagingRootPath: stagingRoot.path
            )
            let scriptURL = stagingRoot.appendingPathComponent("install-update.sh")
            try scriptText.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)

            try Self.launchDetachedInstaller(scriptURL: scriptURL)
            cleanupStagingOnFailure = false
            NSApplication.shared.terminate(nil)
        } catch is CancellationError {
            state = .available(release)
        } catch {
            Log.ui.error("Update install failed: \(error.localizedDescription, privacy: .public)")
            state = .error(error.localizedDescription)
        }
    }

    private func resolveExpectedSHA256(for release: AppUpdateRelease) async throws -> String? {
        if let inline = release.sha256Inline {
            return inline
        }
        guard let assetURL = release.sha256AssetURL else {
            return nil
        }
        var request = URLRequest(url: assetURL)
        request.timeoutInterval = 15
        request.setValue("DroidDock/\(currentVersionString)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await dataFetcher(request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            return nil
        }
        let text = String(data: data, encoding: .utf8) ?? ""
        return Self.parseSHA256Text(text)
    }

    private nonisolated static func streamDownload(
        from url: URL,
        to destinationURL: URL,
        expectedBytes: Int64,
        userAgent: String,
        onProgress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            var req = URLRequest(url: url)
            req.timeoutInterval = 120
            req.setValue(userAgent, forHTTPHeaderField: "User-Agent")

            let (bytes, response) = try await URLSession.shared.bytes(for: req)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw UpdateError.downloadFailed("HTTP \(http.statusCode)")
            }

            let totalBytes = max(expectedBytes, response.expectedContentLength)
            FileManager.default.createFile(atPath: destinationURL.path, contents: nil)
            let handle = try FileHandle(forWritingTo: destinationURL)
            defer { try? handle.close() }

            var hasher = SHA256()
            var buffer = Data()
            buffer.reserveCapacity(64 * 1024)
            var received: Int64 = 0
            var lastReportTime = CFAbsoluteTimeGetCurrent()

            for try await byte in bytes {
                try Task.checkCancellation()
                buffer.append(byte)
                received += 1
                if buffer.count >= 64 * 1024 {
                    hasher.update(data: buffer)
                    try handle.write(contentsOf: buffer)
                    buffer.removeAll(keepingCapacity: true)
                    let now = CFAbsoluteTimeGetCurrent()
                    if now - lastReportTime >= 0.08 {
                        lastReportTime = now
                        onProgress(received, totalBytes)
                    }
                }
            }
            if !buffer.isEmpty {
                hasher.update(data: buffer)
                try handle.write(contentsOf: buffer)
            }
            try handle.synchronize()
            onProgress(received, max(received, totalBytes))
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }.value
    }

    private func extractAndVerifyAppBundle(
        from packageURL: URL,
        filename: String,
        stagingRoot: URL,
        destinationAppURL: URL
    ) async throws {
        let lower = filename.lowercased()
        if lower.hasSuffix(".dmg") {
            let mountPoint = try await Self.attachDMG(at: packageURL)
            defer { Self.detachDMG(mountPoint: mountPoint) }
            guard let sourceApp = Self.locateAppBundle(under: URL(fileURLWithPath: mountPoint, isDirectory: true)) else {
                throw UpdateError.invalidPackage("镜像中未找到 DroidDock.app")
            }
            try await Self.runProcess(executablePath: "/usr/bin/ditto", arguments: [sourceApp.path, destinationAppURL.path])
        } else if lower.hasSuffix(".zip") {
            let extractDir = stagingRoot.appendingPathComponent("unzipped", isDirectory: true)
            try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)
            try await Self.runProcess(executablePath: "/usr/bin/ditto", arguments: ["-xk", packageURL.path, extractDir.path])
            guard let sourceApp = Self.locateAppBundle(under: extractDir) else {
                throw UpdateError.invalidPackage("压缩包中未找到 DroidDock.app")
            }
            try await Self.runProcess(executablePath: "/usr/bin/ditto", arguments: [sourceApp.path, destinationAppURL.path])
        } else {
            throw UpdateError.invalidPackage("不支持的安装包格式：\(filename)")
        }

        let bundleID = Bundle(url: destinationAppURL)?.bundleIdentifier
        guard bundleID == Self.expectedBundleIdentifier else {
            throw UpdateError.invalidPackage("新版本应用标识异常（\(bundleID ?? "未知")）")
        }
        try await Self.runProcess(
            executablePath: "/usr/bin/codesign",
            arguments: ["--verify", "--deep", "--strict", destinationAppURL.path]
        )
    }

    // MARK: - 静态解析与安装辅助（支持纯单元测试）

    nonisolated static func parseReleasesJSON(_ data: Data) throws -> [AppUpdateRelease] {
        guard let rawArray = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw UpdateError.malformedResponse
        }
        var results: [AppUpdateRelease] = []
        for item in rawArray {
            if (item["draft"] as? Bool) == true || (item["prerelease"] as? Bool) == true {
                continue
            }
            guard let tagName = item["tag_name"] as? String,
                  let version = SemanticVersion(tagName),
                  let htmlStr = item["html_url"] as? String,
                  let htmlURL = URL(string: htmlStr),
                  let assets = item["assets"] as? [[String: Any]] else {
                continue
            }

            guard let primaryAsset = selectPreferredAsset(from: assets),
                  let downloadStr = primaryAsset["browser_download_url"] as? String,
                  let downloadURL = URL(string: downloadStr),
                  let assetName = primaryAsset["name"] as? String else {
                continue
            }

            let expectedSize = (primaryAsset["size"] as? NSNumber)?.int64Value ?? 0
            let shaAssetURL = findSHA256AssetURL(for: assetName, in: assets)
            let body = (item["body"] as? String) ?? ""
            let inlineDigest = parseSHA256Text(body)
            let rawName = ((item["name"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let title = rawName.isEmpty ? "DroidDock v\(version.description)" : rawName
            let publishedRaw = (item["published_at"] as? String) ?? (item["created_at"] as? String) ?? ""
            let dateStr = formatISODateOnly(publishedRaw)

            results.append(AppUpdateRelease(
                tagName: tagName,
                versionString: version.description,
                title: title,
                releaseDate: dateStr,
                releaseNotes: body,
                htmlURL: htmlURL,
                downloadURL: downloadURL,
                downloadFilename: assetName,
                expectedSizeBytes: expectedSize,
                sha256AssetURL: shaAssetURL,
                sha256Inline: inlineDigest
            ))
        }

        return results.sorted { lhs, rhs in
            switch (SemanticVersion(lhs.versionString), SemanticVersion(rhs.versionString)) {
            case (.some(let lVer), .some(let rVer)):
                return lVer > rVer
            default:
                return lhs.releaseDate > rhs.releaseDate
            }
        }
    }

    nonisolated static func findNewerRelease(from releases: [AppUpdateRelease], currentVersion: String) -> AppUpdateRelease? {
        guard let current = SemanticVersion(currentVersion) else { return nil }
        return releases.first { release in
            guard let candidate = SemanticVersion(release.versionString) else { return false }
            return candidate > current
        }
    }

    nonisolated static func parseSHA256Text(_ text: String) -> String? {
        let hexChars = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
        for token in text.components(separatedBy: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)) {
            guard token.count == 64 else { continue }
            if token.unicodeScalars.allSatisfy({ hexChars.contains($0) }) {
                return token.lowercased()
            }
        }
        return nil
    }

    nonisolated static func convertToChangelogEntries(_ releases: [AppUpdateRelease]) -> [ChangelogEntry] {
        releases.map { release in
            let lines = release.releaseNotes
                .split(whereSeparator: \.isNewline)
                .map { line -> String in
                    var text = String(line).trimmingCharacters(in: .whitespaces)
                    if text.hasPrefix("- ") || text.hasPrefix("* ") {
                        text = String(text.dropFirst(2))
                    } else if text.hasPrefix("### ") {
                        text = String(text.dropFirst(4))
                    } else if text.hasPrefix("## ") {
                        text = String(text.dropFirst(3))
                    }
                    return text.trimmingCharacters(in: .whitespaces)
                }
                .filter { !$0.isEmpty && parseSHA256Text($0) == nil }

            return ChangelogEntry(
                version: release.versionString,
                title: release.title,
                releaseDate: release.releaseDate,
                notes: lines,
                releaseURL: release.htmlURL
            )
        }
    }

    nonisolated static func resolveWritableTargetAppURL(
        currentBundleURL: URL,
        applicationsURL: URL = URL(fileURLWithPath: "/Applications", isDirectory: true)
    ) -> URL? {
        let path = currentBundleURL.path
        if currentBundleURL.pathExtension == "app",
           !path.hasPrefix("/Volumes/"),
           !path.contains("/DerivedData/") {
            let parentDir = currentBundleURL.deletingLastPathComponent()
            if FileManager.default.isWritableFile(atPath: parentDir.path) {
                return currentBundleURL
            }
        }
        if FileManager.default.isWritableFile(atPath: applicationsURL.path) {
            return applicationsURL.appendingPathComponent("DroidDock.app", isDirectory: true)
        }
        return nil
    }

    nonisolated static func buildInstallScript(
        pid: Int32,
        stagedAppPath: String,
        targetAppPath: String,
        backupAppPath: String,
        stagingRootPath: String
    ) -> String {
        """
        #!/bin/sh
        set -eu
        PID=\(pid)
        STAGED_APP=\(shellQuote(stagedAppPath))
        TARGET_APP=\(shellQuote(targetAppPath))
        BACKUP_APP=\(shellQuote(backupAppPath))
        STAGING_ROOT=\(shellQuote(stagingRootPath))

        WAITED=0
        while kill -0 "$PID" 2>/dev/null && [ "$WAITED" -lt 150 ]; do
          sleep 0.2
          WAITED=$((WAITED + 1))
        done

        if kill -0 "$PID" 2>/dev/null; then
          rm -rf "$STAGING_ROOT"
          exit 1
        fi

        rm -rf "$BACKUP_APP"
        if [ -e "$TARGET_APP" ]; then
          mv "$TARGET_APP" "$BACKUP_APP"
        fi

        if /usr/bin/ditto "$STAGED_APP" "$TARGET_APP"; then
          /usr/bin/xattr -dr com.apple.quarantine "$TARGET_APP" 2>/dev/null || true
          rm -rf "$BACKUP_APP" "$STAGING_ROOT"
          /usr/bin/open "$TARGET_APP"
        else
          rm -rf "$TARGET_APP"
          if [ -e "$BACKUP_APP" ]; then
            mv "$BACKUP_APP" "$TARGET_APP"
          fi
          rm -rf "$STAGING_ROOT"
          exit 1
        fi
        """
    }

    private nonisolated static func selectPreferredAsset(from assets: [[String: Any]]) -> [String: Any]? {
        let validAssets = assets.filter { item in
            guard let name = (item["name"] as? String)?.lowercased(),
                  let urlStr = item["browser_download_url"] as? String,
                  !urlStr.isEmpty else {
                return false
            }
            return name.hasSuffix(".dmg") || name.hasSuffix(".zip")
        }
        return validAssets.first {
            let name = (($0["name"] as? String) ?? "").lowercased()
            return name.hasSuffix(".dmg") && name.contains("arm64")
        }
            ?? validAssets.first { (($0["name"] as? String) ?? "").lowercased().hasSuffix(".dmg") }
            ?? validAssets.first
    }

    private nonisolated static func findSHA256AssetURL(for assetName: String, in assets: [[String: Any]]) -> URL? {
        let lowerTarget = assetName.lowercased()
        let exact = assets.first {
            let name = (($0["name"] as? String) ?? "").lowercased()
            return name == "\(lowerTarget).sha256" || name == "\(lowerTarget).sha256sum"
        }
        let fallback = assets.first {
            let name = (($0["name"] as? String) ?? "").lowercased()
            return name.hasSuffix(".sha256")
        }
        guard let urlStr = (exact ?? fallback)?["browser_download_url"] as? String else { return nil }
        return URL(string: urlStr)
    }

    private nonisolated static func formatISODateOnly(_ raw: String) -> String {
        guard raw.count >= 10 else { return raw }
        return String(raw.prefix(10))
    }

    private nonisolated static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private nonisolated static func locateAppBundle(under root: URL) -> URL? {
        let direct = root.appendingPathComponent("DroidDock.app", isDirectory: true)
        if FileManager.default.fileExists(atPath: direct.path) {
            return direct
        }
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        for child in children where child.pathExtension == "app" {
            if Bundle(url: child)?.bundleIdentifier == expectedBundleIdentifier {
                return child
            }
        }
        return children.first { $0.pathExtension == "app" }
    }

    private nonisolated static func attachDMG(at dmgURL: URL) async throws -> String {
        let stdoutData = try await runProcessCapturingStdout(
            executablePath: "/usr/bin/hdiutil",
            arguments: ["attach", dmgURL.path, "-nobrowse", "-readonly", "-plist"]
        )
        guard let plist = try PropertyListSerialization.propertyList(from: stdoutData, format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]],
              let mountPoint = entities.compactMap({ $0["mount-point"] as? String }).first else {
            throw UpdateError.invalidPackage("无法挂载更新镜像")
        }
        return mountPoint
    }

    private nonisolated static func detachDMG(mountPoint: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["detach", mountPoint, "-force"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }

    private nonisolated static func launchDetachedInstaller(scriptURL: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [scriptURL.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    private nonisolated static func runProcess(executablePath: String, arguments: [String]) async throws {
        _ = try await runProcessCapturingStdout(executablePath: executablePath, arguments: arguments)
    }

    private nonisolated static func runProcessCapturingStdout(executablePath: String, arguments: [String]) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executablePath)
            process.arguments = arguments
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
            try process.run()
            let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let errMsg = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                throw UpdateError.verificationFailed(errMsg.isEmpty ? "退出码 \(process.terminationStatus)" : errMsg)
            }
            return outData
        }.value
    }

    private enum UpdateError: LocalizedError {
        case malformedResponse
        case downloadFailed(String)
        case checksumMismatch
        case invalidPackage(String)
        case verificationFailed(String)

        var errorDescription: String? {
            switch self {
            case .malformedResponse:
                return "解析版本发布信息失败。"
            case .downloadFailed(let detail):
                return "下载升级包失败（\(detail)）。"
            case .checksumMismatch:
                return "升级包 SHA-256 校验未通过，已放弃安装。"
            case .invalidPackage(let detail):
                return detail
            case .verificationFailed(let detail):
                return "校验或解压升级包失败：\(detail)"
            }
        }
    }
}
