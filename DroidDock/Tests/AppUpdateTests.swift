import Foundation
import XCTest
@testable import DroidDock

@MainActor
final class AppUpdateTests: XCTestCase {
    private var defaultsSuiteName: String!
    private var testDefaults: UserDefaults!

    override func setUp() async throws {
        defaultsSuiteName = "com.droiddock.tests.update.\(UUID().uuidString)"
        testDefaults = UserDefaults(suiteName: defaultsSuiteName)
    }

    override func tearDown() async throws {
        if let defaultsSuiteName {
            testDefaults?.removePersistentDomain(forName: defaultsSuiteName)
        }
        testDefaults = nil
    }

    func testSemanticVersionParsingAndComparison() {
        XCTAssertEqual(SemanticVersion("v0.2.0"), SemanticVersion("0.2.0"))
        XCTAssertEqual(SemanticVersion("1.2"), SemanticVersion("1.2.0"))
        XCTAssertEqual(SemanticVersion("0.2.0+build12"), SemanticVersion("0.2.0"))

        XCTAssertLessThan(SemanticVersion("0.1.9") ?? SemanticVersion("0.0.0")!, SemanticVersion("0.2.0")!)
        XCTAssertLessThan(SemanticVersion("0.2.0-beta.1") ?? SemanticVersion("0.0.0")!, SemanticVersion("0.2.0-beta.2")!)
        XCTAssertLessThan(SemanticVersion("0.2.0-beta.2") ?? SemanticVersion("0.0.0")!, SemanticVersion("0.2.0")!)
        XCTAssertLessThan(SemanticVersion("0.9.9") ?? SemanticVersion("0.0.0")!, SemanticVersion("1.0.0")!)

        XCTAssertNil(SemanticVersion(""))
        XCTAssertNil(SemanticVersion("invalid"))
        XCTAssertNil(SemanticVersion("1.2.3.4"))
    }

    func testParseReleasesJSONPrefersArm64DMGAndExtractsSHA256() throws {
        let digest = String(repeating: "a1b2c3d4", count: 8)
        let json: [[String: Any]] = [
            [
                "tag_name": "v9.9.9-draft",
                "draft": true,
                "prerelease": false,
                "html_url": "https://github.com/HarmonyChang/droid-dock/releases/tag/v9.9.9",
                "assets": [
                    ["name": "DroidDock-9.9.9-arm64.dmg", "browser_download_url": "https://example.com/draft.dmg", "size": 100],
                ],
            ],
            [
                "tag_name": "v0.3.0-rc.1",
                "draft": false,
                "prerelease": true,
                "html_url": "https://github.com/HarmonyChang/droid-dock/releases/tag/v0.3.0-rc.1",
                "assets": [
                    ["name": "DroidDock-0.3.0-rc.1-arm64.dmg", "browser_download_url": "https://example.com/pre.dmg", "size": 100],
                ],
            ],
            [
                "tag_name": "v0.1.0",
                "draft": false,
                "prerelease": false,
                "name": "Initial Release",
                "published_at": "2026-11-16T08:00:00Z",
                "body": "- 首次发布",
                "html_url": "https://github.com/HarmonyChang/droid-dock/releases/tag/v0.1.0",
                "assets": [
                    ["name": "DroidDock-0.1.0-arm64.dmg", "browser_download_url": "https://example.com/0.1.0.dmg", "size": 2_500_000],
                ],
            ],
            [
                "tag_name": "v0.3.0",
                "draft": false,
                "prerelease": false,
                "name": "DroidDock v0.3.0 稳定版",
                "published_at": "2026-12-01T10:30:00Z",
                "body": "- 新增局域网断点续传\n- SHA256: \(digest)",
                "html_url": "https://github.com/HarmonyChang/droid-dock/releases/tag/v0.3.0",
                "assets": [
                    ["name": "DroidDock-0.3.0.zip", "browser_download_url": "https://example.com/0.3.0.zip", "size": 3_100_000],
                    ["name": "DroidDock-0.3.0-arm64.dmg", "browser_download_url": "https://example.com/0.3.0-arm64.dmg", "size": 2_900_000],
                    ["name": "DroidDock-0.3.0-arm64.dmg.sha256", "browser_download_url": "https://example.com/0.3.0-arm64.dmg.sha256", "size": 92],
                ],
            ],
        ]

        let data = try JSONSerialization.data(withJSONObject: json)
        let parsed = try AppUpdateService.parseReleasesJSON(data)
        XCTAssertEqual(parsed.map(\.versionString), ["0.3.0", "0.1.0"])

        let latest = try XCTUnwrap(parsed.first)
        XCTAssertEqual(latest.downloadFilename, "DroidDock-0.3.0-arm64.dmg")
        XCTAssertEqual(latest.sha256AssetURL?.absoluteString, "https://example.com/0.3.0-arm64.dmg.sha256")
        XCTAssertEqual(latest.sha256Inline, digest)
        XCTAssertEqual(latest.releaseDate, "2026-12-01")

        let newer = AppUpdateService.findNewerRelease(from: parsed, currentVersion: "0.2.0")
        XCTAssertEqual(newer?.versionString, "0.3.0")

        let changelog = AppUpdateService.convertToChangelogEntries(parsed)
        XCTAssertEqual(changelog.first?.notes, ["新增局域网断点续传"])
    }

    func testParseSHA256AndCheckForUpdatesFlows() async throws {
        let validHex = String(repeating: "f0e1d2c3", count: 8)
        XCTAssertEqual(AppUpdateService.parseSHA256Text("\(validHex.uppercased())  DroidDock-0.2.0-arm64.dmg\n"), validHex)
        XCTAssertNil(AppUpdateService.parseSHA256Text("not-a-digest 1234"))

        let json: [[String: Any]] = [
            [
                "tag_name": "v0.3.0",
                "draft": false,
                "prerelease": false,
                "name": "v0.3.0",
                "published_at": "2026-12-01T00:00:00Z",
                "body": "- 性能提升",
                "html_url": "https://github.com/HarmonyChang/droid-dock/releases/tag/v0.3.0",
                "assets": [
                    ["name": "DroidDock-0.3.0-arm64.dmg", "browser_download_url": "https://example.com/0.3.0.dmg", "size": 2_800_000],
                ],
            ],
        ]
        let payloadData = try JSONSerialization.data(withJSONObject: json)

        let service = AppUpdateService(
            currentVersionString: "0.2.0",
            currentBuildString: "2",
            userDefaults: testDefaults
        ) { request in
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://api.github.com")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (payloadData, response)
        }

        await service.checkForUpdates(userInitiated: true)
        if case .available(let release) = service.state {
            XCTAssertEqual(release.versionString, "0.3.0")
        } else {
            XCTFail("期望状态为 .available，实际为 \(service.state)")
        }
        XCTAssertTrue(service.shouldHighlightUpdate)
        XCTAssertEqual(service.mergedChangelog.first?.version, "0.3.0")
        XCTAssertTrue(service.mergedChangelog.contains { $0.version == "0.2.0" })

        // 跳过提醒后高亮消失
        service.skipAvailableVersion()
        XCTAssertFalse(service.shouldHighlightUpdate)

        // 传输进行中时拦截升级，确保不破坏进行中的传输
        service.downloadAndInstallUpdate(isTransferring: true)
        if case .error(let msg) = service.state {
            XCTAssertTrue(msg.contains("传输"))
        } else {
            XCTFail("传输过程中升级应被阻止并返回错误")
        }

        // 仓库尚无 Release（HTTP 404）时优雅回到最新状态
        let notFoundService = AppUpdateService(
            currentVersionString: "0.2.0",
            currentBuildString: "2",
            userDefaults: testDefaults
        ) { request in
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://api.github.com")!,
                statusCode: 404,
                httpVersion: nil,
                headerFields: nil
            )!
            return (Data(), response)
        }
        await notFoundService.checkForUpdates(userInitiated: true)
        XCTAssertEqual(notFoundService.state, .upToDate(latestVersion: "0.2.0"))
        XCTAssertFalse(notFoundService.mergedChangelog.isEmpty)
    }

    func testBuildInstallScriptContainsRollbackAndRelaunch() {
        let script = AppUpdateService.buildInstallScript(
            pid: 4321,
            stagedAppPath: "/tmp/stage/DroidDock.app",
            targetAppPath: "/Applications/DroidDock.app",
            backupAppPath: "/tmp/stage/DroidDock-backup.app",
            stagingRootPath: "/tmp/stage"
        )
        XCTAssertTrue(script.contains("PID=4321"))
        XCTAssertTrue(script.contains("kill -0 \"$PID\""))
        XCTAssertTrue(script.contains("/usr/bin/ditto \"$STAGED_APP\" \"$TARGET_APP\""))
        XCTAssertTrue(script.contains("xattr -dr com.apple.quarantine"))
        XCTAssertTrue(script.contains("mv \"$BACKUP_APP\" \"$TARGET_APP\""))
        XCTAssertTrue(script.contains("/usr/bin/open \"$TARGET_APP\""))
    }
}
