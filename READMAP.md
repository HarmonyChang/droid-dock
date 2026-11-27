# READMAP — DroidDock 开发记录与进度

本文件记录各阶段完成内容，供不同 Agent 了解进度。每个阶段或子任务完成后必须更新（规则见 `AGENTS.md` 第 8 节）。倒序追加到「开发日志」。

## 当前状态

- 当前阶段：**真机界面细节与视频封面体验修复完成并重新部署 -- 修复左下角存储空间紧凑不换行与传输期 5 秒实时刷新、工具栏分段选择器多余截断标签与传输队列「同名冲突」竖排折叠，并新增基于 `GetPartialObject` / 无线按需分片的远程视频首帧封面提取（网格与列表同步显示，免整片下载）；`USBMTPTests`（15/15）与 `DroidDockTests`（33/33）全部通过，0 Swift 编译器警告，已更新重启 `/Applications/DroidDock.app`（PID `90942` 运行中）**
- 代码与产物：
  - [PathUtils.swift](DroidDock/Support/PathUtils.swift) + [SidebarView.swift](DroidDock/UI/SidebarView.swift) + [BrowserModel.swift](DroidDock/App/BrowserModel.swift) + [AppState.swift](DroidDock/App/AppState.swift)：新增 `formatCompactStorage` 紧凑单小数容量显示与双行不折行布局；新增 `refreshStorages()` 在传输出错完成、删改目录与传输期每 5 秒自动更新剩余/已用空间。
  - [BrowserToolbarView.swift](DroidDock/UI/BrowserToolbarView.swift) + [TransferTrayView.swift](DroidDock/UI/TransferTrayView.swift)：为视图切换 `Picker` 加上 `.labelsHidden()` 消除前置截断文本；将传输队列 `headerBar` 重排为双行紧凑布局彻底消除「同名冲突」竖向折行。
  - [FileProvider.swift](DroidDock/Device/FileProvider.swift) + [DeviceSession.swift](DroidDock/Device/DeviceSession.swift) + [MTPProvider.swift](DroidDock/Device/MTP/MTPProvider.swift) + [ADBProvider.swift](DroidDock/Device/ADB/ADBProvider.swift) + [ThumbnailPipeline.swift](DroidDock/Services/ThumbnailPipeline.swift) + [BrowserContentView.swift](DroidDock/UI/BrowserContentView.swift)：全链路打通 `readPartial(_:offset:length:)`，通过 `AVAssetResourceLoaderDelegate`（128 KB 块缓存 + 4 MB 读取预算上限 + 8s 超时）按需拉取 MP4/MOV/M4V/3GP 头尾索引及首个关键帧生成 JPEG 封面，并在列表行补充微缩图展示。
- 下一步：由用户在已重启的 `/Applications/DroidDock.app`（PID `90942` 运行中）复测左下角空间展示与实时刷新、传输队列头部、顶部视图切换与视频封面预览；确认无误后按指令决定是否提交推送并发布新版本。

## 里程碑进度

| 阶段 | 内容 | 状态 | 验收标准（摘要） |
|---|---|---|---|
| 文档 | 规格与原型设计 | ✅ 已完成（规格 v0.2） | — |
| M0 | IOUSBHost 打开 MTP 接口、OpenSession、列出存储与 `DCIM`，完成全部【待验证】项实测 | ✅ 核心跑通（待补图片 `GetThumb` 与 >4GB/非法字符验证） | 实机列出存储与 DCIM；实测记录回写规格 |
| M1 | 设备层与文件视图：热插拔、存储、导航、锁定态 | ✅ 代码与单测完成（4 套儒雅配色默认方案 B · 黛蓝宋锦，已修复误报权限提示） | 拔插 UI 正确更新；锁屏后可自动解锁恢复 |
| M2 | 传输：下载、上传、队列、托盘、拖拽、冲突策略 | 🔄 代码与单测完成（待实机 1 GB 双向传输验收） | 1 GB 级混合批量双向成功；取消与断线无残留 `.part` |
| M3 | 相册与缩略图：索引、网格、缓存、预览（含双击放大与 `←`/`→` 切换） | 🔄 代码与单测完成（待实机多张大图与 Quick Look 验收） | 5000 张首屏可交互、滚动流畅、重连增量刷新、图片双击放大/方向键切换 |
| M4 | 打磨与分发：品牌 Logo、诊断导出、签名与 DMG 打包 | ✅ 代码、Release 构建与签名打包完成 | Release `DroidDock.app` 与 `.dmg` 校验通过并运行 |
| M5 | 二期 · 双模式同网无线连接：默认新手扫码快传 + 无线调试全盘管理 | 🔄 代码、打包与单测完成（待真机验收） | 手机相机扫码互传不断网、无线调试引导与同 Wi-Fi 秒连 |

## 已确定的技术决策（2026-11-16）

- 放弃 Kalam，改为 Swift + Apple IOUSBHost 自研纯 Swift MTP 客户端（`USBMTP` Package）；不使用 libusb/libmtp，规避 LGPL。
- SQLite 用系统 SQLite3 自行封装，不引入 GRDB。
- 支持 macOS 27，最低 macOS 14；仅 USB，Wi-Fi 与无线配对界面后续阶段再做。
- 仍待实测：沙盒可行性、`DCIM/Camera` 图片 `GetThumb` 与 64 KB `GetPartialObject` 返回数据、其余厂商 MTP 日期字段时区、大于 4 GB 传输、非法文件名集合（`ptpcamerad` 独占、`O+Connect Service` AOA 劫持防护、存储/`DCIM` 枚举与 `.nomedia` `GetPartialObject` 已在 OnePlus 13T 完成实机验证）。

## 评审核实记录（2026-11-16，针对已放弃的 Kalam 路线）


方式：读取 OpenMTP 仓库源码（`ffi/kalam/native` 的 `kalam.go`、`helpers.go`、`structs.go`、`go.mod`、`README.md`）、`go-mtpx` 与 `go-mtpfs` 仓库、GitHub release 页面。详细结论见 `AGENTS.md` 第 4 节。

- 与规格一致：Kalam 可编为动态库；OpenMTP 3.3.0 修复 macOS 27 arm64 崩溃（发布于 2026-08-22）；OpenMTP、go-mtpx 为 MIT。
- 与规格不一致或需补充：见 `AGENTS.md` 第 4 节。
- 未核实：`ptpcamerad` 现象仅有二手描述，未实机验证；4 GB 传输仅为官方宣称。
- 设计稿 HTML 为打包页面，未做视觉评审。

## 开发日志

### 2026-11-27 21:54 -- 优化左下角存储展示与实时刷新、工具栏/传输队列布局并新增视频封面局部提取
- 改动与修复：
  1. **存储空间紧凑不换行与实时刷新**：[PathUtils.swift](DroidDock/Support/PathUtils.swift) 新增 `formatCompactStorage`（1 位小数并去 `.0`）；[SidebarView.swift](DroidDock/UI/SidebarView.swift) 将 `storageFooter` 调整为单行顶部（卷名 + 可用）+ 进度条 + 单行底部（已用/总计 + 百分比）防止 232 pt 边栏折行；[BrowserModel.swift](DroidDock/App/BrowserModel.swift) 与 [AppState.swift](DroidDock/App/AppState.swift) 新增 `refreshStorages()`，在目录增删、传输完成（即使停留在传输队列页）及传输进行中每 5 秒同步更新空间统计。
  2. **顶部工具栏与传输队列布局修复**：[BrowserToolbarView.swift](DroidDock/UI/BrowserToolbarView.swift) 为视图分段器添加 `.labelsHidden()` 与 `.fixedSize()` 消除“网格/列表”前多余截断文字；[TransferTrayView.swift](DroidDock/UI/TransferTrayView.swift) 将 `headerBar` 重构为两行清晰布局彻底解决“同名冲突”竖向折行。
  3. **远程视频首帧封面生成**：[FileProvider.swift](DroidDock/Device/FileProvider.swift)、[DeviceSession.swift](DroidDock/Device/DeviceSession.swift)、[MTPProvider.swift](DroidDock/Device/MTP/MTPProvider.swift)、[ADBProvider.swift](DroidDock/Device/ADB/ADBProvider.swift) 实现按偏移局部字节读取 `readPartial`；[ThumbnailPipeline.swift](DroidDock/Services/ThumbnailPipeline.swift) 新增 `RemoteVideoResourceLoader`（128 KB 块缓存、4 MB 预算上限、8 秒超时与取消清理）按需拉取 MP4/MOV/M4V/3GP 索引及首帧；[BrowserContentView.swift](DroidDock/UI/BrowserContentView.swift) 为列表行照片/视频同步显示缩略封面。
- 验证与部署（2026-11-27 21:54）：
  - 非测试代码 0 `!` 强制解包，`USBMTP` 引入边界保持干净。
  - `Packages/USBMTP` `swift test`：**15/15** 通过；`xcodebuild ... build test`：**33/33** 通过（0 Swift 编译警告，含新增 [MediaAndThumbnailTests.swift](DroidDock/Tests/MediaAndThumbnailTests.swift) 大视频局部拉取封面回归测试与 [BrowserAndDeviceTests.swift](DroidDock/Tests/BrowserAndDeviceTests.swift) 紧凑格式化及实时容量刷新测试）。
  - 执行 [scripts/package-app.sh](scripts/package-app.sh) 生成 Release 包体并替换 `/Applications/DroidDock.app`，清理开发缓存后 `codesign --verify --deep --strict` 校验通过，已启动运行（PID `90942`）。

### 2026-11-25 10:26 -- 新增中英文专业 README 文档（`README.md` / `README_EN.md`）
- 文档变更：
  - 新增 [README.md](README.md)（简体中文）与 [README_EN.md](README_EN.md)（English），均支持顶部中英文互跳开关，全面介绍纯 Swift `USBMTP`、十万级传输优化、相册与 EXIF 查看器、扫码快传与无线 ADB 双模连接、手机状态浮窗、GitHub Releases 自动升级、Ad-hoc 首次启动说明、构建测试命令、快捷键与项目分层结构。
  - 遵循仓库文档规范，仅描述 `v0.2.0` 已实现并验证的真实状态，未将未实现规划或待办写入 `README`。
- 验证（2026-11-25 10:26）：
  - 脚本校验通过：`README.md` 与 `README_EN.md` 各包含 `8` 处本地路径/截图链接，全部存在且可解析，且均无违规全角破折号。

### 2026-11-24 21:02 -- 升级至 `v0.2.0`：新增版本记录（CHANGELOG）与应用内 GitHub Releases 自动升级能力
- 新增能力：
  1. **版本记录体系**：新增 [CHANGELOG.md](CHANGELOG.md) 与内置历史 `ChangelogEntry.bundledHistory`（覆盖 `0.2.0`、`0.1.1`、`0.1.0`），并将 Xcode `MARKETING_VERSION` 升至 `0.2.0`（Build `2`）；[scripts/package-app.sh](scripts/package-app.sh) 自动读取版本号并同步生成 `.dmg.sha256` 校验文件。
  2. **零依赖自动升级服务**（[AppUpdateService.swift](DroidDock/Services/AppUpdateService.swift) ）：实现 `SemanticVersion` 解析、GitHub Releases 查询（`HarmonyChang/droid-dock`，404 尚未发版时优雅提示）、`URLSession` 后台流式下载并计算 `CryptoKit.SHA256`、`hdiutil attach` 自动挂载 `.dmg` 与 `codesign --verify --deep --strict` 验签、`Bundle.bundleIdentifier` 校验，以及带老版本备份与失败回滚机制的自替换重启脚本（明确拦截活跃传输期升级）。
  3. **版本与升级 UI 集成**（[AppUpdateSheetView.swift](DroidDock/UI/AppUpdateSheetView.swift)、[SidebarView.swift](DroidDock/UI/SidebarView.swift)、[DroidDockApp.swift](DroidDock/App/DroidDockApp.swift)、[MainWindowView.swift](DroidDock/UI/MainWindowView.swift)、[AppState.swift](DroidDock/App/AppState.swift) ）：菜单栏支持「检查更新… / 版本记录…」，边栏品牌区新增版本徽标与新版本高亮，应用启动后 3 秒（6 小时频控）按开关静默检查更新。
- 验证与部署（2026-11-24 21:02）：
  - 非测试代码 0 `!` 强制解包，`USBMTP` 引入边界保持干净。
  - `Packages/USBMTP` `swift test`：**15/15** 通过（0 警告）；`xcodebuild ... build test`：**31/31** 通过（0 Swift 编译器警告，含 [AppUpdateTests.swift](DroidDock/Tests/AppUpdateTests.swift) 4 项新增用例）。
  - 执行 [scripts/package-app.sh](scripts/package-app.sh) 生成 [dist/DroidDock-0.2.0-arm64.dmg](dist/DroidDock-0.2.0-arm64.dmg)（2.9 MB）与 `.sha256`，替换 `/Applications/DroidDock.app` 并清理 `dist/DroidDock.app` 与临时目录，签名校验与版本号（`0.2.0` Build `2`）验证通过，已启动 `/Applications/DroidDock.app`（PID `5270` 运行中）。

### 2026-11-24 20:25 -- 新增手机状态与详情展示（电量、网络方式、系统与链路信息）并安全隔离测试宿主
- 改动与功能：
  1. **测试宿主 USB 隔离**：[DroidDockApp.swift](DroidDock/App/DroidDockApp.swift) 在 `.task` 入口校验 `XCTestConfigurationFilePath == nil`，运行单元测试期间不启动 `AppState` / `MTPDeviceBackend`，彻底避免抢占运行中应用的 USB 连接。
  2. **USB MTP 状态与速率扩展**：[MTPCodec.swift](Packages/USBMTP/Sources/USBMTP/MTPCodec.swift)、[MTPSession.swift](Packages/USBMTP/Sources/USBMTP/MTPSession.swift)、[IOUSBHostTransport.swift](Packages/USBMTP/Sources/USBMTP/IOUSBHostTransport.swift) 新增标准 `GetDevicePropValue`（`0x1015`）与 `BatteryLevel`（`0x5001`）查询能力，解析 `devicePropertiesSupported`，并从 IORegistry 读取 `USBSpeed` 生成 USB 链路速率描述。
  3. **跨协议状态模型与采集**：[FileProvider.swift](DroidDock/Device/FileProvider.swift)、[DeviceSession.swift](DroidDock/Device/DeviceSession.swift)、[MTPProvider.swift](DroidDock/Device/MTP/MTPProvider.swift)、[ADBProvider.swift](DroidDock/Device/ADB/ADBProvider.swift) 新增 `DeviceStatusInfo`；USB MTP 模式按能力安全探测电池电量与 USB 速率；无线 ADB 模式单次轻量级 `shell` 命令综合读取电量/充放电状态/电池温度、`Android` 版本、Wi-Fi 与 SSID / 5G / 4G / 3G / 无网络状态及局域网 IPv4。
  4. **边栏状态胶囊、详情浮窗与传输保护**：[AppState.swift](DroidDock/App/AppState.swift) 增加设备就绪时拉取、60s 定时刷新（传输活跃时自动跳过）及断线/锁屏自动清理；[SidebarView.swift](DroidDock/UI/SidebarView.swift) 新增紧凑电量/网络/USB 链路胶囊与 `DeviceDetailsPopoverView` 详情浮窗（含点击复制 IP 与序列号、存储概览、手动刷新按钮）；[DiagnosticsService.swift](DroidDock/Support/DiagnosticsService.swift) 同步写入设备状态摘要。
- 验证（2026-11-24 20:25）：
  - 非测试代码 0 `!` 强制解包，`USBMTP` 边界未越界。
  - `Packages/USBMTP` `swift test`：**15/15** 全部通过（0 警告，新增 `testDeviceInfoParsesDevicePropertiesSupported` 与 `testBatteryLevelReadsValidAndHandlesUnsupported`）。
  - `xcodebuild -project DroidDock.xcodeproj -scheme DroidDock -destination 'platform=macOS,arch=arm64' build test`：**27/27** 全部通过（0 Swift 编译器警告，在 [FakeFileProvider.swift](DroidDock/Tests/FakeFileProvider.swift) 与 [BrowserAndDeviceTests.swift](DroidDock/Tests/BrowserAndDeviceTests.swift) 新增 `testADBParseDeviceStatusWiFiAndCharging`、`testADBParseDeviceStatusCellular5GAndDischarging`、`testAppStateRefreshesAndClearsDeviceStatus`）。
- 部署（2026-11-24 20:52）：
  - 确认用户 40 GB 传输完成后，执行 `scripts/package-app.sh` 生成 Release 构建与 2.7 MB [dist/DroidDock-0.1.0-arm64.dmg](dist/DroidDock-0.1.0-arm64.dmg)，更新 `/Applications/DroidDock.app` 并清理 `dist/DroidDock.app` 与 `/tmp/droiddock-release-build`，`codesign --verify --deep --strict /Applications/DroidDock.app` 通过；已重启 `/Applications/DroidDock.app`（PID `99869` 运行中）。

### 2026-11-24 19:33 -- 修复 40 GB / 15 万文件目录上传首屏假死、中途 USB ZLP 卡死与误报断开问题
- 根因定位：
  1. **USB High-Speed 512 字节对齐缺少 ZLP + 超时误判为永久断线**：OnePlus 真机 USB 2.0 Bulk-OUT 端点 `wMaxPacketSize = 512`。当 MTP 发送容器总长度（12 字节头 + Payload）恰好是 512 的整数倍时（例如上传 500 B 或 65,524 B 文件，平均每约 512 个文件必中一次，实测第 40 个文件命中），Android `MtpFfsHandle::receiveFile` 会一直阻塞等待 Zero-Length Packet（ZLP），触发原先 10s I/O 超时后，[MTPProvider.swift](DroidDock/Device/MTP/MTPProvider.swift) 将超时错误映射为 `.disconnected`，引发 [DeviceManager.swift](DroidDock/Device/DeviceManager.swift) `markDisconnected` 直接清空连接，`TransferQueue` 将剩余 155,336 项一次性全部标为失败；同时 `MTPDeviceBackend.refresh()` 未淘汰已失效的 `.ready` 句柄，导致无法自动恢复。
  2. **入队与 UI 更新 $O(N^2)$ 假死**：原先 `TransferQueue.enqueueUploads` 在启动传输前同步递归遍历 155,375 个文件，未给出任何“扫描中”状态；`scheduleNextIfNeeded`、进度更新与 `buildSnapshot` 每 80 ms 复制/扫描全部 15 万条 `TransferTask`，`TransferModel.overallProgress` 与 `TransferTrayView` 每帧全量扫描并过滤数组。
  3. **目录轮询与后台抢占风暴**：每个文件上传前均重复逐级 `ensureRemoteDirectory` + `session.list`（15 万文件产生 60 万+ 次 MTP 往返），且每传完 1 个文件就触发一次 `browser.reload()`。
- 核心修复：
  1. **USB ZLP 与错误恢复**：[IOUSBHostTransport.swift](Packages/USBMTP/Sources/USBMTP/IOUSBHostTransport.swift)、[MTPSession.swift](Packages/USBMTP/Sources/USBMTP/MTPSession.swift)、[MTPCodec.swift](Packages/USBMTP/Sources/USBMTP/MTPCodec.swift) 补发 512 B/MPS 边界 ZLP、超时放宽至 30s/60s 并细分 `.timeout` / `.busy`；[FileProvider.swift](DroidDock/Device/FileProvider.swift)、[DeviceManager.swift](DroidDock/Device/DeviceManager.swift)、[MTPProvider.swift](DroidDock/Device/MTP/MTPProvider.swift) 保留瞬时超时重试机会并实现 `invalidateAndReconnect` 强制重建失效连接。
  2. **10 万级队列流畅架构**：[TransferQueue.swift](DroidDock/Services/TransferQueue.swift) 改为后台 `AsyncStream` 每批 500 项流式扫盘 + 即时启动传输；全路径替换为 `taskIndexByID` 字典、`queueSearchCursor` 游标、增量 `settledBytes`/`totalPlannedBytes`、`ensuredDirectories` 与 `cachedRemoteDirectories` 目录缓存；快照 10 Hz 节流且超 400 条自动窗口化为 300 条重点条目；整批上传完毕后再触发 1 次 `browser.reload()`。
  3. **UI 状态反馈与防休眠**：[TransferModel.swift](DroidDock/App/TransferModel.swift) 与 [TransferTrayView.swift](DroidDock/UI/TransferTrayView.swift) 增加 `isPreparing` / 扫描实时计数展示，通过 `ProcessInfo.processInfo.beginActivity` 在传输期间防止 App Nap 与系统空闲休眠；[AppState.swift](DroidDock/App/AppState.swift)、[BrowserModel.swift](DroidDock/App/BrowserModel.swift)、[ThumbnailPipeline.swift](DroidDock/Services/ThumbnailPipeline.swift) 在传输期间暂停后台缩略图 USB 拉取。
- 验证（2026-11-24 19:33）：
  - 非测试代码（除 Apple `QLPreviewPanelDataSource` 协议签名外）零 `!` 强制解包，`USBMTP` 仅在 `DroidDock/Device/MTP/` 引入。
  - `Packages/USBMTP` `swift test`：**13/13** 全部通过（0 警告，含新增 `testUploadObjectSendsZLPOnMaxPacketSizeBoundary` 覆盖 500 B / 65,524 B ZLP 发送）。
  - `xcodebuild -project DroidDock.xcodeproj -scheme DroidDock -destination 'platform=macOS,arch=arm64' build test`：**24/24** 全部通过（0 Swift 编译器警告，含新增 `testUploadDirectoryCachesRemoteListingsAndCompletesBatch` 与 `testLargeBatchUploadWindowingAndCompletion` 500 文件窗口化测试）。
  - 执行 `scripts/package-app.sh` 生成 Release 构建与 [dist/DroidDock-0.1.0-arm64.dmg](dist/DroidDock-0.1.0-arm64.dmg)，部署更新 `/Applications/DroidDock.app` 并清理多余 `.app` 构建副本，`codesign --verify --deep --strict /Applications/DroidDock.app` 通过；已启动 `/Applications/DroidDock.app`（PID `58945` 运行中）。

### 2026-11-17 21:31 -- 修复真机双击看图模糊、新增右上角照片信息卡片，并优化相册滑动缩略图加载速度
- 根因与修复（根据真机实测反馈）：
  1. **双击看图高清化与防管道失步**：
     - [Packages/USBMTP/Sources/USBMTP/MTPSession.swift](Packages/USBMTP/Sources/USBMTP/MTPSession.swift)：修复 `withTransactionLock` 取消唤醒后未接力下一等待者的隐患；在 `downloadObject` 对 ≤ 8 MB 事务取消时先静默排空当前数据与末尾 12 字节 Response 容器再抛出 `CancellationError`，防止半截响应污染后续原图与缩略图指令。
     - [DroidDock/Services/ThumbnailPipeline.swift](DroidDock/Services/ThumbnailPipeline.swift) + [DroidDock/App/BrowserModel.swift](DroidDock/App/BrowserModel.swift)：打开预览时通过 `setPreviewPrioritized(true)` 优先抢占设备带宽（自动暂停后台缩略图设备 I/O），提供 `previewProgress` 实时进度、瞬时错误自动重试 1 次、后台 6144 px（含 EXIF 方向矫正）高清预解码，以及相邻照片 250 ms 静默预取；[DroidDock/UI/PhotoPreviewView.swift](DroidDock/UI/PhotoPreviewView.swift) 开启 `.interpolation(.high)` 与 `.antialiased(true)`，并在原图失败时给出明确提示与「重新加载」按钮（不静默停留在模糊缩略图）。
  2. **右上角照片信息卡片（`PhotoMetadataOverlayCard`）**：
     - 在 [DroidDock/App/BrowserModel.swift](DroidDock/App/BrowserModel.swift) 新增 `PhotoMetadata` 与 `ImageIO` EXIF 解析，提取真实宽高（已按 EXIF 方向 5–8 校正横竖屏）、百万像素、文件大小与格式、相机与镜头型号、等效焦距 / 光圈 / 快门 / ISO / 曝光补偿、拍摄时间、色彩配置、GPS 坐标与设备内路径。
     - 在 [DroidDock/UI/PhotoPreviewView.swift](DroidDock/UI/PhotoPreviewView.swift) 查看器右上角展示半透明磨砂信息浮窗，顶部工具栏同步提供「信息」显示开关。
  3. **相册网格滑动缩略图提速**：
     - [DroidDock/Device/DeviceSession.swift](DroidDock/Device/DeviceSession.swift) 与 [DroidDock/Device/MTP/MTPProvider.swift](DroidDock/Device/MTP/MTPProvider.swift)：在 `DeviceSession.run` 入口校验任务取消避免已滑出单元格占用 USB 通道；为 `MTPFileProvider` 增加 `objectInfoCache`；对无原生 `GetThumb` 的照片通过 `GetPartialObject` 读取前 128 KB 仅提取内嵌 EXIF 缩略图。
     - [DroidDock/Services/ThumbnailPipeline.swift](DroidDock/Services/ThumbnailPipeline.swift) 与 [DroidDock/UI/BrowserContentView.swift](DroidDock/UI/BrowserContentView.swift)：设备缩略图排队改为 LIFO 栈（滑停后当前视口最新图片优先加载）；增加后台已解码 `SendableImageCache` 并在网格使用独立 `NodeThumbnailView` 组件，消除单张缩略图回写触发全表重绘与主线程 JPEG 解码；同步将 [docs/DroidDock-Dev-Spec.md](docs/DroidDock-Dev-Spec.md) 更新。
- 验证（2026-11-17 21:31）：
  - 非测试代码（除 Apple `QLPreviewPanelDataSource` 协议签名外）零 `!` 强制解包，`USBMTP` 仅在 `DroidDock/Device/MTP/` 引入。
  - `Packages/USBMTP` `swift test`：0 警告，**12/12** 通过。
  - `xcodebuild -project DroidDock.xcodeproj -scheme DroidDock -destination 'platform=macOS,arch=arm64' build test`：0 Swift 编译器/链接器警告，**22/22** 用例全部通过（含新增 `testPhotoPreviewDecodesHighResOriginalAndExtractsEXIFMetadata`）。
  - 执行 `scripts/package-app.sh`：Release 构建、`codesign --verify --deep --strict` 校验与 DMG 打包通过，更新 [dist/DroidDock.app](dist/DroidDock.app) 与 2.6 MB [dist/DroidDock-0.1.0-arm64.dmg](dist/DroidDock-0.1.0-arm64.dmg)；已重启 [dist/DroidDock.app](dist/DroidDock.app)（PID `53776` 运行中）。

### 2026-11-17 10:20 -- 扫码快传支持文件夹与相册预览、清空编译警告并完成代码提交
- 扫码快传体验增强（[DroidDock/Services/QuickDropWebServer.swift](DroidDock/Services/QuickDropWebServer.swift)、[DroidDock/UI/WirelessPairingSheetView.swift](DroidDock/UI/WirelessPairingSheetView.swift)）：
  1. **文件夹双向收发**：Mac 侧支持选择或拖入整个文件夹，递归统计文件数与总容量并提取最多 120 个媒体条目；手机网页点击文件夹可经 `/usr/bin/ditto` 后台生成并缓存 ZIP 流式下载；手机侧新增「选文件夹」（`webkitdirectory`），上传自动携带合法化校验后的 `subpath` 在 Mac `下载 / DroidDock-快传` 下还原目录层级。
  2. **相册预览与大图/视频灯箱**：新增 `/api/thumb/<mediaID>`（ImageIO / `AVAssetImageGenerator` 生成 320 px JPEG 并内存缓存）与支持 HTTP `Range` 分片的 `/api/media/<mediaID>` 接口；手机端支持选图即时缩略图预览、Mac 投送内容 3 列相册网格及全屏滑屏/切换灯箱预览；Mac 端接收列表为图片显示 64 px 异步微缩图并提供 Quick Look「预览」与「访达」按钮。
  3. **并发隔离优化**：为每个接入的 `QuickDropConnectionHandler` 分配独立串行队列，避免多缩略图并发加载与大文件传输互相阻塞，并清理未使用的 `stateQueue` 变量消除编译警告。
- 仓库配置与规格同步：更新 [.gitignore](.gitignore) 排除 `dist/` 与 `.tmp/`；同步更新 [docs/DroidDock-Dev-Spec.md](docs/DroidDock-Dev-Spec.md)。
- 验证（2026-11-17 10:20）：
  - 非测试代码（除 Apple `QLPreviewPanelDataSource` 协议方法签名外）零 `!` 强制解包；`USBMTP` 仅在 `DroidDock/Device/MTP/` 引入。
  - `Packages/USBMTP` `swift test`：0 警告，**12/12** 通过。
  - `xcodebuild -project DroidDock.xcodeproj -scheme DroidDock -destination 'platform=macOS,arch=arm64' build test`：0 Swift 编译器/链接器警告，**21/21** 用例全部通过（含新增文件夹 ZIP、JPEG 缩略图、原图读取及 `subpath` 嵌套上传端到端回路验证）。
  - 执行 `scripts/package-app.sh`：Release 构建、`codesign --verify --deep --strict` 校验与 DMG 打包通过，更新 [dist/DroidDock.app](dist/DroidDock.app) 与 2.5 MB [dist/DroidDock-0.1.0-arm64.dmg](dist/DroidDock-0.1.0-arm64.dmg)；已重启 [dist/DroidDock.app](dist/DroidDock.app)（PID `15286` 运行中）。

### 2026-11-17 09:57 -- 二次代码 Review 修复 `QuickDropWebServer` 连接生命周期并补齐真实 TCP 端到端单测
- 问题定位与修复（[DroidDock/Services/QuickDropWebServer.swift](DroidDock/Services/QuickDropWebServer.swift)）：
  1. **修复连接处理器被提前释放的关键 Bug**：原 `NWListener.newConnectionHandler` 创建 `QuickDropConnectionHandler` 后未保留强引用，而 `connection.stateUpdateHandler` / `connection.receive` 均使用 `[weak self]`，导致闭包返回后处理器立刻被释放、手机扫码请求无响应。现于 `QuickDropServerSnapshotBox` 新增线程安全 `activeHandlers` 注册表持有每个连接直至 `closeConnection()` 或 `stop()` 调用 `cancelAllHandlers()` 统一释放，并确保队列隔离与幂等关闭。
  2. **补充 HTTP 边界处理**：`GET /favicon.ico` 放行返回 `204 No Content`，避免手机浏览器拉取图标产生 403；`POST /api/upload` 强制校验 `Content-Length` 请求头缺失则返回 `411 Length Required`；同步将 `token` 公开为 `private(set) var` 便于端到端单测校验。
- 新增真实回路单测（[DroidDock/Tests/BrowserAndDeviceTests.swift](DroidDock/Tests/BrowserAndDeviceTests.swift)）：
  - 新增 `testQuickDropWebServerEndToEndUploadAndDownload`，通过真实 `URLSession` 访问 `http://127.0.0.1:<port>` 验证：未鉴权 `403`、`/favicon.ico` `204`、`GET /?t=<token>`、`/api/shared`、96 KB 分块流式下载 `/api/download/<id>` 与 98 KB 分块上传 `POST /api/upload` 原子落盘（无 `.droiddock-part` 残留）。
- 验证（2026-11-17 09:57）：
  - 非测试代码（除 Apple `QLPreviewPanelDataSource` 协议方法签名外）零 `!` 强制解包；`USBMTP` 仅在 `DroidDock/Device/MTP/` 引入。
  - `Packages/USBMTP` `swift test`：0 警告，**12/12** 通过。
  - `xcodebuild -project DroidDock.xcodeproj -scheme DroidDock -destination 'platform=macOS,arch=arm64' build test`：0 编译器/链接器警告，**21/21** 用例全部通过。
  - 执行 `scripts/package-app.sh`：Release 构建、`codesign --verify --deep --strict` 校验与 DMG 打包通过，更新 [dist/DroidDock.app](dist/DroidDock.app) 与 2.4 MB [dist/DroidDock-0.1.0-arm64.dmg](dist/DroidDock-0.1.0-arm64.dmg)；已重启 [dist/DroidDock.app](dist/DroidDock.app)（PID `13620` 运行中）。

### 2026-11-17 09:49 -- Review 问题全量修复 + 新手默认「扫码快传模式」与无线调试开启教程
- 修复 Review 发现的 4 处边界问题：
  1. **防大目录参数长度溢出**：修改 [DroidDock/Device/ADB/ADBProvider.swift](DroidDock/Device/ADB/ADBProvider.swift) 的 `list(dir:storage:)`，将 `stat ... <dir>/*` 改为 `find <dir> -mindepth 1 -maxdepth 1 ! -name '.*' -exec stat ... {} +`。
  2. **防无线/有线大图视频缩略图兜底拉取超大原片**：修改 [DroidDock/Services/ThumbnailPipeline.swift](DroidDock/Services/ThumbnailPipeline.swift)，新增 `maxFallbackPhotoBytes`（50 MB）与 `maxFallbackVideoBytes`（30 MB）限制，超出上限的文件不再为生成缩略图拉取完整文件。
  3. **无线设备重名去重**：更新 [DroidDock/Device/ADB/ADBClient.swift](DroidDock/Device/ADB/ADBClient.swift) 的 `parseDevicesList`，对同时出现 `IP:Port` 与 `mDNS _adb-tls-connect._tcp` 的同一设备按 `(model, device)` 去重，优先保留在线与 mDNS 会话。
  4. **高清大图与 Quick Look 缓存自动清理**：更新 [DroidDock/App/BrowserModel.swift](DroidDock/App/BrowserModel.swift)，为 `~/Library/Caches/com.droiddock.app/PreviewCache` 增加 512 MB 自动淘汰。
- 新增新手默认「扫码快传模式」与多品牌无线调试开启教程：
  - 新增 [DroidDock/Services/QuickDropWebServer.swift](DroidDock/Services/QuickDropWebServer.swift) 并注入 [DroidDock/App/AppState.swift](DroidDock/App/AppState.swift)：Mac 端启动纯 Swift 局域网 HTTP 传图/文件服务，带一次性口令与防覆盖原子落盘，手机系统相机/微信/浏览器扫码即传且不断网。
  - 更新 [DroidDock/UI/WirelessPairingSheetView.swift](DroidDock/UI/WirelessPairingSheetView.swift)：默认首屏展示「扫码快传（推荐新手 · 免设置）」（含手机传 Mac、拖放文件投送到手机与快速在访达查看）；顶部可切换至「无线调试（全盘管理）」，并附一加/OPPO、小米、vivo/三星分步开启「开发者选项 → 无线调试」指引。
  - 更新 [DroidDock.xcodeproj/project.pbxproj](DroidDock.xcodeproj/project.pbxproj)、[DroidDock/Tests/BrowserAndDeviceTests.swift](DroidDock/Tests/BrowserAndDeviceTests.swift)、[DroidDock/Tests/MediaAndThumbnailTests.swift](DroidDock/Tests/MediaAndThumbnailTests.swift) 与 [docs/DroidDock-Dev-Spec.md](docs/DroidDock-Dev-Spec.md)。
- 验证（2026-11-17 09:49）：
  - 非测试代码零 `!` 强制解包，`USBMTP` 仅在 `DroidDock/Device/MTP/` 引入。
  - `Packages/USBMTP` `swift build && swift test`：0 警告，**12/12** 通过。
  - `xcodebuild -project DroidDock.xcodeproj -scheme DroidDock -destination 'platform=macOS,arch=arm64' build test`：0 编译器/链接器警告，**20/20** 用例全部通过。
  - 执行 `scripts/package-app.sh`：Release 构建与 `codesign --verify --deep --strict` 校验通过，更新 [dist/DroidDock.app](dist/DroidDock.app) 与 2.4 MB [dist/DroidDock-0.1.0-arm64.dmg](dist/DroidDock-0.1.0-arm64.dmg)；已启动 Release 版 `DroidDock.app`（PID `12838` 运行中）。

### 2026-11-17 08:42 -- M5（第二阶段）同网无线 ADB 自动发现、扫码/配对码连接与双模后端融合
- 方案选型结论与用户关切验证：
  - 采用「同网 mDNS 自动发现 + 扫码/配对码首次绑定（Android 系统无线调试）」路线：手机无需安装任何 App，首次在同局域网扫码后完成 TLS 密钥信任；后续在同一 Wi-Fi 开启无线调试即可自动发现并重连。二维码（`WIFI:T:ADB;S:...;P:...;;`）仅携带局域网配对服务标识与一次性口令，不切换 Wi-Fi 热点，手机可继续正常上网。
- 实现详情：
  - 安装官方 Android `platform-tools`（`adb` 37.0.1-15733141）至 `~/Library/Application Support/com.droiddock.app/platform-tools/adb`，并新增 [DroidDock/Device/ADB/ADBClient.swift](DroidDock/Device/ADB/ADBClient.swift)（内置洁净 Mac 一键在线下载安装 `platform-tools`、超时与任务取消控制）。
  - 新增 [DroidDock/Device/ADB/ADBDiscoveryService.swift](DroidDock/Device/ADB/ADBDiscoveryService.swift)：通过 `NetServiceBrowser` 监听 `_adb-tls-connect._tcp.` 与 `_adb-tls-pairing._tcp.`，用 CoreImage 生成官方扫码配对二维码并在同网检测到手机扫码请求时自动执行 `adb pair` + `adb connect`。
  - 新增 [DroidDock/Device/ADB/ADBProvider.swift](DroidDock/Device/ADB/ADBProvider.swift) 并扩展 [DroidDock/Device/FileProvider.swift](DroidDock/Device/FileProvider.swift)、[DroidDock/Device/DeviceManager.swift](DroidDock/Device/DeviceManager.swift)：实现 `ADBFileProvider`（完整支持存储探测、`list`、`listMedia`、流式 `pull`/`push` 传输、删除、建目录、Android 媒体库广播刷新）与 `ADBDeviceBackend`（同网已配对设备自动发现重连），通过 `CompositeDeviceBackend` 与 USB MTP 无缝共存切换。
  - 新增 [DroidDock/UI/WirelessPairingSheetView.swift](DroidDock/UI/WirelessPairingSheetView.swift) 并更新 [DroidDock/App/AppState.swift](DroidDock/App/AppState.swift)、[DroidDock/UI/SidebarView.swift](DroidDock/UI/SidebarView.swift)、[DroidDock/UI/BrowserContentView.swift](DroidDock/UI/BrowserContentView.swift)、[DroidDock/UI/MainWindowView.swift](DroidDock/UI/MainWindowView.swift)、[DroidDock/App/DroidDockApp.swift](DroidDock/App/DroidDockApp.swift)、[DroidDock.xcodeproj/project.pbxproj](DroidDock.xcodeproj/project.pbxproj) 与 [DroidDock/Tests/BrowserAndDeviceTests.swift](DroidDock/Tests/BrowserAndDeviceTests.swift)。
  - 同步更新 [docs/DroidDock-Dev-Spec.md](docs/DroidDock-Dev-Spec.md)。
- 验证（2026-11-17 08:42）：
  - 非测试代码零 `!` 强制解包，`USBMTP` 仅在 `DroidDock/Device/MTP/` 引入。
  - `cd Packages/USBMTP && swift build && swift test`：0 警告通过，**12/12** 用例全部通过。
  - `xcodebuild -project DroidDock.xcodeproj -scheme DroidDock -destination 'platform=macOS,arch=arm64' build test`：0 编译器/链接器警告，**19/19** 用例全部通过（含新增 `testCompositeBackendMergesUSBAndWiFiDevices` 与 `testWirelessADBParsingAndQRPayload`）。
  - 执行 `scripts/package-app.sh`：Release 构建通过，`codesign --verify --deep --strict` 通过，产出 [dist/DroidDock.app](dist/DroidDock.app) 与 2.4 MB [dist/DroidDock-0.1.0-arm64.dmg](dist/DroidDock-0.1.0-arm64.dmg)；已启动 Release 版 `DroidDock.app`（PID `8929` 运行中）。

### 2026-11-17 06:59 -- M4 品牌 Logo/图标、连接防误报、查看器左右方向键切图、诊断日志导出与 DMG 分发打包
- 修复使用中发现的 3 个关键体验问题：
  1. **补全应用 Logo 与 macOS 图标集**：新增 [DroidDock/Resources/Assets.xcassets/AppIcon.appiconset](DroidDock/Resources/Assets.xcassets/AppIcon.appiconset/Contents.json)（16x16 至 512x512@2x 全尺寸 PNG）与 [DroidDock/UI/BrandLogoView.swift](DroidDock/UI/BrandLogoView.swift)，在 [DroidDock/App/DroidDockApp.swift](DroidDock/App/DroidDockApp.swift) 启动时设置 `applicationIconImage`，并在 [DroidDock/UI/SidebarView.swift](DroidDock/UI/SidebarView.swift) 顶部与未连接引导卡片呈现品牌标志。
  2. **解决刚插线误报「尚未开放文件权限」提示**：更新 [DroidDock/Device/MTP/MTPProvider.swift](DroidDock/Device/MTP/MTPProvider.swift)（新增 `pendingRescan` 避免热插拔并发丢失、`fetchStoragesWithWarmup` 在会话初建 ~1.2 秒窗口内重试与会话重开、`watchLockedDevice` 自动恢复）与 [DroidDock/App/BrowserModel.swift](DroidDock/App/BrowserModel.swift)（启动 `lockedRetryTask` 持续轮询并自动恢复就绪），并在 [DroidDock/UI/BrowserContentView.swift](DroidDock/UI/BrowserContentView.swift) 给出自动轮询提示与「立即重试」按钮。
  3. **修复查看图片时左右方向键切图**：在 [DroidDock/UI/MainWindowView.swift](DroidDock/UI/MainWindowView.swift) 中当 `previewingNode != nil` 时优先捕获 `←` / `→` / `Esc` / `Space` 事件而不受背后搜索框历史焦点阻塞；在 [DroidDock/UI/PhotoPreviewView.swift](DroidDock/UI/PhotoPreviewView.swift) 打开查看器时释放搜索框焦点，补充常驻左右翻页箭头与底部页码切图栏；同步优化 `InteractionNSView.mouseDown` 点击网格时释放输入框焦点。
- 完成 M4 收尾、诊断与分发：
  - 新增 [DroidDock/Support/DiagnosticsService.swift](DroidDock/Support/DiagnosticsService.swift)（导出设备状态、传输队列摘要与进程内 `OSLogStore` 日志）并在菜单栏增加「设备与诊断」入口。
  - 新增 [scripts/package-app.sh](scripts/package-app.sh) 与 [DroidDock.xcodeproj/project.pbxproj](DroidDock.xcodeproj/project.pbxproj) 资源编译配置：自动构建 Release `DroidDock.app`、`codesign` 深度签名校验、打包 `dist/DroidDock-0.1.0-arm64.dmg`（2.1 MB）并预留公证参数。
  - 扩展 [DroidDock/Tests/BrowserAndDeviceTests.swift](DroidDock/Tests/BrowserAndDeviceTests.swift) 与 [DroidDock/Tests/MediaAndThumbnailTests.swift](DroidDock/Tests/MediaAndThumbnailTests.swift)，新增空存储自动恢复及左右切图边界验证。
- 验证（2026-11-17 06:59）：
  - 非测试代码零 `!` 强制解包，`USBMTP` 仅在 `DroidDock/Device/` 引入；`Packages/USBMTP` `swift build && swift test` **12/12** 通过。
  - `xcodebuild -project DroidDock.xcodeproj -scheme DroidDock -destination 'platform=macOS,arch=arm64' build test`：0 编译器/链接器警告，**17/17** 用例全部通过。
  - 执行 `scripts/package-app.sh`：Release 构建通过，`codesign --verify --deep --strict` 通过，生成 [dist/DroidDock.app](dist/DroidDock.app)（含 `AppIcon.icns` 与 `Assets.car`）及 [dist/DroidDock-0.1.0-arm64.dmg](dist/DroidDock-0.1.0-arm64.dmg)（2.1 MB）；已启动 Release 版 `DroidDock.app`（PID `5077` 运行中）。

### 2026-11-16 23:41 -- M3 SQLite 媒体索引、320 px 缩略图流水线与双击放大图片查看器
- 新增系统 `SQLite3` 持久化媒体索引：
  - 新增 [DroidDock/Services/MediaIndexStore.swift](DroidDock/Services/MediaIndexStore.swift)：在 `~/Library/Caches/com.droiddock.app/media_index.sqlite3` 维护 `media_index(device, storage, node_id, path, name, size, mtime, kind)`，支持设备重连先读本地缓存秒开列表、真机扫描后事务增量同步，以及删除条目同步清理。
- 新增四级 320 px 缩略图流水线：
  - 新增 [DroidDock/Services/ThumbnailPipeline.swift](DroidDock/Services/ThumbnailPipeline.swift)：按 `NSCache` 内存 → `~/Library/Caches/com.droiddock.app/Thumbnails` 磁盘（SHA-1 键值 `sha1(deviceID|storage|path|size|mtime)`，默认 2 GB 上限按修改时间 LRU 淘汰）→ 设备原生 `GetThumb` → 流式下载临时文件后使用 ImageIO / `AVAssetImageGenerator`（按 `min(4, 核心数)` 并发限制）生成最长边 `320 px` JPEG 缩略图。
  - 在 [DroidDock/App/BrowserModel.swift](DroidDock/App/BrowserModel.swift) 接入索引缓存与缩略图流水线，并在单元格滚出视口取消时不误标失败。
- 新增双击放大图片查看器与系统 Quick Look 预览：
  - 新增 [DroidDock/UI/PhotoPreviewView.swift](DroidDock/UI/PhotoPreviewView.swift)：包含 `PhotoLightboxView`（支持双击图片在 `1.0x ↔ 2.5x` 间平滑放大/还原、工具栏按钮与百分比徽标缩放、双指捏合 `1.0x–4.0x`、放大后拖拽平移与边界约束、左右按钮/方向键翻页、`Esc` 关闭，以及无感知原图后台下载）与基于 `QLPreviewPanel` 的 `QuickLookController`。
  - 更新 [DroidDock/UI/BrowserContentView.swift](DroidDock/UI/BrowserContentView.swift) 与 [DroidDock/UI/MainWindowView.swift](DroidDock/UI/MainWindowView.swift)：双击或右键「查看图片 / 快速预览」或按空格键即可预览，且输入框聚焦时不误截空格键。
  - 更新 [DroidDock/Support/Logger.swift](DroidDock/Support/Logger.swift)、[DroidDock/Tests/FakeFileProvider.swift](DroidDock/Tests/FakeFileProvider.swift)、[DroidDock.xcodeproj/project.pbxproj](DroidDock.xcodeproj/project.pbxproj)，新增 [DroidDock/Tests/MediaAndThumbnailTests.swift](DroidDock/Tests/MediaAndThumbnailTests.swift)，并同步更新 [docs/DroidDock-Dev-Spec.md](docs/DroidDock-Dev-Spec.md)。
- 验证（2026-11-16 23:41）：
  - 全非测试代码零 `!` 强制解包，`USBMTP` 仅在 `DroidDock/Device/` 引入；`Packages/USBMTP` `swift build && swift test` 12/12 通过，0 警告。
  - `xcodebuild -project DroidDock.xcodeproj -scheme DroidDock -destination 'platform=macOS,arch=arm64' build test`：0 编译器/链接器警告，**17/17** 用例全部通过（`BrowserAndDeviceTests` 7 项、`MediaAndThumbnailTests` 4 项、`TransferTests` 6 项）。
  - 已重启构建产物 `DroidDock.app`（PID `89789` 运行中）。

### 2026-11-16 23:16 -- M2 Mac ↔ Android 双向传输、队列状态机、悬浮托盘与拖拽全量落地
- 扩展 `Packages/USBMTP` 写与流式传输能力：
  - 修改 [Packages/USBMTP/Sources/USBMTP/MTPCodec.swift](Packages/USBMTP/Sources/USBMTP/MTPCodec.swift)：新增常用错误响应码常量、`ByteWriter.string(_:)`、`MTPObjectInfo.inferFormat` 与 `encodeForSend`。
  - 修改 [Packages/USBMTP/Sources/USBMTP/MTPSession.swift](Packages/USBMTP/Sources/USBMTP/MTPSession.swift)：增加 FIFO `withTransactionLock` 防止浏览/缩略图与传输并发交错损坏 USB 管道；实现 `executeWithData`、分块流式 `downloadObject`、`SendObjectInfo` + `SendObject`（12 字节数据头与首包合并按 64 KB 对齐写出）流式 `uploadObject`、`makeDirectory`（Association `0x3001`）与 `deleteObject`。
  - 扩充 [Packages/USBMTP/Tests/USBMTPTests/MTPCodecTests.swift](Packages/USBMTP/Tests/USBMTPTests/MTPCodecTests.swift)：新增编码往返、分块流式下载、64 KB 首包合并上传及新建目录/删除测试。
- 完成 `MTPFileProvider`、`TransferQueue` 与双向传输交互：
  - 修改 [DroidDock/Support/PathUtils.swift](DroidDock/Support/PathUtils.swift)：新增 `ConflictStrategy`（自动重命名/覆盖/跳过）、Android 文件名/目录名合法性前置校验 `validateAndroidFilename`、`resolveConflictDestination`（大小写不敏感匹配）与 `formatMTPDate`。
  - 修改 [DroidDock/Device/FileProvider.swift](DroidDock/Device/FileProvider.swift)、[DroidDock/Device/DeviceSession.swift](DroidDock/Device/DeviceSession.swift)、[DroidDock/Device/MTP/MTPProvider.swift](DroidDock/Device/MTP/MTPProvider.swift)：打通真实 `FileHandle` 流式 `download` / `upload` / `delete` / `makeDirectory`，并透传 `CancellationError` 与精细化 MTP 响应错误映射。
  - 新增 [DroidDock/Services/TransferQueue.swift](DroidDock/Services/TransferQueue.swift) 与 [DroidDock/App/TransferModel.swift](DroidDock/App/TransferModel.swift)，并接入 [DroidDock/App/AppState.swift](DroidDock/App/AppState.swift)、[DroidDock/App/BrowserModel.swift](DroidDock/App/BrowserModel.swift)：支持单设备串行队列、`.droiddock-part` 原子写入与失败/取消清理、非断线错误至多 1 次自动重试、3 秒窗口 EMA 速率平滑、目录递归导入/上传、以及新建文件夹与批量删除。
  - 新增 [DroidDock/UI/TransferTrayView.swift](DroidDock/UI/TransferTrayView.swift) 并更新 [DroidDock/UI/SidebarView.swift](DroidDock/UI/SidebarView.swift)、[DroidDock/UI/BrowserToolbarView.swift](DroidDock/UI/BrowserToolbarView.swift)、[DroidDock/UI/BrowserContentView.swift](DroidDock/UI/BrowserContentView.swift)、[DroidDock/UI/MainWindowView.swift](DroidDock/UI/MainWindowView.swift)：上线 56 pt 高 / 12 pt 圆角底部悬浮托盘、传输队列全屏页（含同名冲突策略切换与失败详情重试）、`NSOpenPanel` 导入/上传、`NSFilePromiseProvider` 拖出到 Finder、窗口与文件夹拖入上传、右键菜单、新建文件夹弹窗（`⌘⇧N`）以及 `Delete` / `⌘⌫` 删除确认。
  - 更新 [DroidDock/Tests/FakeFileProvider.swift](DroidDock/Tests/FakeFileProvider.swift)、[DroidDock.xcodeproj/project.pbxproj](DroidDock.xcodeproj/project.pbxproj)，新增 [DroidDock/Tests/TransferTests.swift](DroidDock/Tests/TransferTests.swift)。
  - 同步更新 [docs/DroidDock-Dev-Spec.md](docs/DroidDock-Dev-Spec.md)（写明 4 套「儒雅彩色」主题与默认「黛蓝宋锦 `songIndigo`」）。
- 验证（2026-11-16 23:16）：
  - `cd Packages/USBMTP && swift build && swift test`：0 警告通过，12/12 用例全部通过。
  - `xcodebuild -project DroidDock.xcodeproj -scheme DroidDock -destination 'platform=macOS,arch=arm64' build test`：0 编译器/链接器警告（无非测试代码强制解包），13/13 用例全部通过（含 `BrowserAndDeviceTests` 7 项与 `TransferTests` 6 项）。
  - 已重启构建产物 `DroidDock.app`。

### 2026-11-16 22:57 -- M1 相册纯媒体视图、隐藏项过滤与 4 套「儒雅彩色」配色方案
- 针对用户实机反馈优化设备数据与界面表现：
  - 修改 [DroidDock/Device/FileProvider.swift](DroidDock/Device/FileProvider.swift)、[DroidDock/Device/DeviceSession.swift](DroidDock/Device/DeviceSession.swift)、[DroidDock/Device/MTP/MTPProvider.swift](DroidDock/Device/MTP/MTPProvider.swift)：
    - 在 `list(dir:storage:)` 中过滤 `.` 开头的隐藏系统目录与隐藏文件（如 `.DocRecycleBin`、`.convert_security_files`、`.nomedia`），并在根目录将 `DCIM`、`Pictures`、`Movies`、`Download`、`Documents`、`Music`、`Recordings` 置顶排序。
    - 新增 `listMedia(storage:limit:)`，聚合并倒序扫描 `/DCIM/Camera`、`/DCIM/Screenshots`、`/Pictures/Screenshots`、`/Pictures`、`/Movies` 及 `/DCIM` 下非隐藏子目录，仅返回纯照片与视频文件（绝不包含文件夹）。
  - 修改 [DroidDock/App/BrowserModel.swift](DroidDock/App/BrowserModel.swift)：默认进入「相册」纯媒体视图，支持 `全部 / 照片 / 视频 / 截图` 过滤胶囊、自然日降序分组（`今天` / `昨天` / `M 月 D 日`）以及异步 `GetThumb` 原生缩略图加载与内存缓存。
  - 修改 [DroidDock/UI/Theme.swift](DroidDock/UI/Theme.swift)、[DroidDock/App/AppState.swift](DroidDock/App/AppState.swift)、[DroidDock/UI/{SidebarView,BrowserToolbarView,BrowserContentView,MainWindowView}.swift](DroidDock/UI/MainWindowView.swift)：固定温润浅色外观，新增多色圆角图标徽标、常用文件夹中文副标题，并内置「竹青宣纸」「黛蓝宋锦（默认）」「松烟茶白」「晨雾晴岚」4 套儒雅配色方案（支持侧栏实时切换与 `UserDefaults` 持久化）。
  - 更新 [DroidDock/Tests/FakeFileProvider.swift](DroidDock/Tests/FakeFileProvider.swift) 与 [DroidDock/Tests/BrowserAndDeviceTests.swift](DroidDock/Tests/BrowserAndDeviceTests.swift)，覆盖隐藏文件过滤、纯媒体聚合过滤与缩略图缓存测试。
- 验证（2026-11-16 22:57）：
  - `xcodebuild -project DroidDock.xcodeproj -scheme DroidDock -destination 'platform=macOS,arch=arm64' build test`：构建 0 编译器/链接器警告（无强制解包），`DroidDockTests` 7/7 通过（0.043 秒）。
  - 已重启启动新版 `DroidDock.app`。

### 2026-11-16 22:39 -- M1 设备层与文件视图主工程搭建及单元测试通过
- 扩展 `Packages/USBMTP`：
  - 修改 [Packages/USBMTP/Sources/USBMTP/IOUSBHostTransport.swift](Packages/USBMTP/Sources/USBMTP/IOUSBHostTransport.swift)：为 `USBInterfaceCandidate` 增加 `locationID` 与 IORegistry 条目名回退解析；新增 `USBHotplugMonitor`（基于 `IOServiceAddMatchingNotification` 监听 `IOUSBHostInterface` 匹配与移除，输出 `AsyncStream<Void>`）。
  - 修改 [Packages/USBMTP/Sources/USBMTP/MTPSession.swift](Packages/USBMTP/Sources/USBMTP/MTPSession.swift)：新增 `objectHandles(storage:parent:)`、`objectInfo(handle:)`、`thumbnail(handle:)`、`partialObject(handle:offset:maxBytes:)`。
- 新增 `DroidDock` 主工程与单元测试（macOS 14+ / arm64 / Swift 6 严格并发 / 非沙盒）：
  - 支撑层：`DroidDock/Support/Logger.swift`、`Errors.swift`、`PathUtils.swift`。
  - 设备层（唯一导入 `USBMTP` 层）：`DroidDock/Device/FileProvider.swift`、`DeviceSession.swift`、`DeviceManager.swift`、`MTP/MTPProvider.swift`（实现路径到 MTP 句柄缓存、空存储 `.locked` 映射与锁屏轮询、断线 10ms 级重连抢占）。
  - 状态与 UI 层（无 `USBMTP` / `IOKit` 依赖）：`DroidDock/App/{DroidDockApp,AppState,BrowserModel}.swift` 与 `DroidDock/UI/{Theme,SidebarView,BrowserToolbarView,BrowserContentView,MainWindowView}.swift`（实现 232 pt 侧栏、52 pt 工具栏、网格/列表切换、面包屑导航、搜索过滤，以及无设备、`.locked`、错误、加载中、空目录 5 种核心状态）。
  - 工程与测试：`DroidDock.xcodeproj`（含 shared scheme `DroidDock`）及 `DroidDock/Tests/{FakeFileProvider,BrowserAndDeviceTests}.swift`。
- 验证（2026-11-16 22:39，Xcode 27.2 / Swift 6.4.2）：
  - `cd Packages/USBMTP && swift build && swift test`：编译 0 错误 0 警告，`USBMTPTests` 8/8 通过（0.003 秒）。
  - `xcodebuild -project DroidDock.xcodeproj -scheme DroidDock -destination 'platform=macOS,arch=arm64' build test`：构建 0 编译器/链接器警告（无强制解包、符合分层导入边界），`DroidDockTests` 7/7 通过（0.043 秒）。

### 2026-11-16 22:22 -- M0 Xcode 27.2 全量编译与 `swift test` 验证通过
- 环境：使用新安装的 `/Applications/Xcode.app`（Xcode 27.2，Build 27B52，`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`）。注：系统全局 `xcode-select -p` 当前仍指向 `/Library/Developer/CommandLineTools`，建议后续由用户手动执行 `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`。
- 验证（`cd Packages/USBMTP && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift package clean && swift build && swift test`）：
  - `swift build`：构建成功（5.90 秒），**0 错误、0 编译器警告、0 链接器警告**（此前 CommandLineTools 下的 3 条 `ld: warning` 已完全消除）。
  - `swift test`：`USBMTPTests.xctest` 全部 8 项测试通过（`MTPCodecTests` 6 项 + `MTPSessionTests` 2 项，0 failures，耗时 0.005 秒）。

### 2026-11-16 22:18 -- M0 实机跑通存储、`DCIM` 与 `GetPartialObject` 探测（一加 13T）
- 实机验证结果（macOS 27.2.1 + OnePlus PKX110 / 一加 13T，`.build/debug/mtp-spike probe`）：
  - 手机在后台监听状态下重选「传输文件」触发 USB 重枚举后，`mtp-spike` 在 10ms 级重连循环中抢在 `O+Connect Service`（1.9s）和 `ptpcamerad` 之前锁住 `IOUSBHostDevice` 与 `IOUSBHostInterface`，成功阻止 AOA 劫持并完成全链路读取：
    - 存储：`65537`（`内部共享存储空间`），已用 `151802671104 / 492196392960` 字节（约 151.8 GB / 492.2 GB）。
    - 根目录 32 项（含 `Pictures`、`Movies`、`Download`、`Documents`、`DCIM` 等）；`DCIM` 下 8 项（含 `.convert_security_files`、`Google Photos`、`bili`、`Camera` 等）。
    - 对象元数据与读取：因旧版 `Spike.swift` 未跳过隐藏目录且在首个非空子目录退出，本轮对 `DCIM/.convert_security_files/.nomedia`（`size=48`，`thumbFmt=0x0000`）测得 `created='20260115T201015'` / `modified='20260115T201015'`（无时区后缀 `YYYYMMDDThhmmss`）、`GetPartialObject` 返回 `0x2001`（48 字节），`GetThumb` 对非图片返回 `0x2002`。
  - 释放时机验证：`mtp-spike` 于 `22:15:44` 退出并释放 `IOUSBHostDevice` 约 1.8 秒后（`22:15:45.869`），内核日志记录到 `O+Connect Service` 再次介入向 endpoint 0 发送控制请求并切换至 `0x18d1/2d00` 再回落 `0x22d9/2764` 仅充电。因此正式版 `DroidDock` 的 `DeviceManager` / `DeviceSession` 在设备连接期间必须持续持有 `IOUSBHostDevice` 与 `IOUSBHostInterface` 直至设备断开或应用退出。
- 代码与文档更新：
  - 优化 [Packages/USBMTP/Sources/MTPSpike/Spike.swift](Packages/USBMTP/Sources/MTPSpike/Spike.swift)：跳过 `.` 开头隐藏目录、优先进入 `DCIM/Camera` 等相册目录，并仅对前 10 个对象句柄查询 `GetObjectInfo`（避免数千张图片目录阻塞），定位首张图片执行 `GetThumb` 与 64 KB `GetPartialObject`。
  - 更新 [docs/DroidDock-Dev-Spec.md](docs/DroidDock-Dev-Spec.md)、[AGENTS.md](AGENTS.md) 与本文件，回写实测数据与持续锁护架构要求。
- 验证：
  - `cd Packages/USBMTP && swift build`（2026-11-16 22:18）：编译通过，Swift 编译器 0 错误 0 警告（CommandLineTools 下仍有 3 条 `ld: warning` 工具链路径警告）。

### 2026-11-16 22:13 -- M0 定位 `O+Connect Service` AOA 抢占根因并实现 `IOUSBHostDevice` 锁护
- 根因定位（`/usr/bin/log show` 内核 `IOUSBHostFamily` 日志）：
  - 本机后台运行 `/Applications/O+Connect.app/Contents/Resources/daemon/O+Connect Service`（PID 839，root 权限）。手机重枚举为 MTP（`0x22d9/2764`）约 1.9 秒后，该守护进程打开父级 `IOUSBHostDevice` 并向 `endpoint 0x00` 发送 AOA 切换指令（`[usb_host]Sending usb enable msg`），强制将手机切换至 `0x18d1/2d00`（Android Open Accessory）并在 0.6 秒后释放，导致手机重枚举回 `0x22d9/2764` 并退回「仅充电」（`storages=0`）。
  - 实测验证：以 `IOUSBHostDevice(__ioService: parent, options: [.deviceSeize], ...)` 锁定父级 `IOUSBHostDevice` 后，其他进程尝试打开设备会触发 `Code=-536870203`（`kIOReturnExclusiveAccess`），可阻止 `O+Connect Service` 下发 AOA 指令。
- 修改文档与代码：
  - 更新 [docs/DroidDock-Dev-Spec.md](docs/DroidDock-Dev-Spec.md) 与 [AGENTS.md](AGENTS.md)，记录 `O+Connect Service` AOA 抢占实测结论与父级 `IOUSBHostDevice` 锁护决策。
  - 修改 [Packages/USBMTP/Sources/USBMTP/IOUSBHostTransport.swift](Packages/USBMTP/Sources/USBMTP/IOUSBHostTransport.swift)：在 `init(candidate:)` 中增加锁定父级 `IOUSBHostDevice`（`options: [.deviceSeize]`），并在 `deinit` 中释放 `device?.destroy()`。
  - 修改 [Packages/USBMTP/Sources/MTPSpike/Spike.swift](Packages/USBMTP/Sources/MTPSpike/Spike.swift)：`probe()` 支持最长 120 秒持续监听、500ms 存储轮询与断线 10ms 级重连抢占。

### 2026-11-16 21:55 -- M0 实机联调（一加 13T）：`ptpcamerad` 独占排查与自动抢占落地
- 实机联调（macOS 27.2.1 + OnePlus PKX110 / 一加 13T `vid=22d9 pid=2764`）：
  - 确认 MTP 握手（`GetDeviceInfo`、`OpenSession`、`CloseSession`）正常，`OnePlus PKX110` 声明支持 `GetThumb (0x100A)` 与 `GetPartialObject (0x101B)` / `GetPartialObject64 (0x95C1)`。
  - 复现 `ptpcamerad` 独占：`icdd` 拉起当前用户态 `/usr/libexec/ptpcamerad` 持有 `UsbExclusiveOwner`，导致 `IOUSBHostInterface` 报错 `-536870199`（`kIOReturnInternalError` / `Failed [super init]`）。对比测试确认 `.deviceSeize` 被拒、`.deviceCapture` 需受限权限（`-536870207` / `kIOReturnNotPrivileged`）、`configure(0)` 中断 Android `f_mtp`、`IOUSBHostDevice.reset()` 虽可 8ms 抢先打开接口但会触发 ColorOS 退回「仅充电」。
  - 经用户授权执行 `killall -9 ptpcamerad` 后立即重连，接口无感接管且未重置手机端 USB 状态（因此前 `dev.reset()` 实验已将手机置回「仅充电」，当前 `GetStorageIDs` 返回 0 个存储）。
- 修改文档与代码：
  - 更新 [docs/DroidDock-Dev-Spec.md](docs/DroidDock-Dev-Spec.md) 与 [AGENTS.md](AGENTS.md)，回写 `ptpcamerad` 与空存储 `.locked` 实测结论，明确桌面非沙盒端「热插拔抢先打开 + 遇独占错误自动结束当前用户 `ptpcamerad` 并 5ms 轮询重试接管」决策。
  - 修改 [Packages/USBMTP/Sources/USBMTP/IOUSBHostTransport.swift](Packages/USBMTP/Sources/USBMTP/IOUSBHostTransport.swift)：新增 `openInterface(candidate:)` 自动退避抢占逻辑与 `deinit { interface.destroy() }`。
  - 修改 [Packages/USBMTP/Sources/MTPSpike/Spike.swift](Packages/USBMTP/Sources/MTPSpike/Spike.swift)：无存储提前返回时补全 `closeSession()`，并在 `DCIM` 子目录探测中增加对象元数据、`GetThumb` 与 `GetPartialObject`（64 KB）实测输出。
- 验证：
  - `cd Packages/USBMTP && swift build`：编译成功（Swift 编译器 0 错误 0 警告；CommandLineTools 下仍有 3 条 `ld: warning` 工具链路径警告）。
  - `.build/debug/mtp-spike probe`：接口正常打开、`GetDeviceInfo` 与 `OpenSession` 成功；因手机处于上轮 `reset()` 后的仅充电状态，输出 `无存储（手机可能未解锁或处于仅充电模式）` 并正常关闭会话。

### 2026-11-16 18:44 -- M0 本地编译修复与工具链验证
- 修改 `Packages/USBMTP/Sources/USBMTP/IOUSBHostTransport.swift`：
  - 修正 `IOUSBGetNextEndpointDescriptor` 返回值处理，直接通过 `next.pointee` 读取 `IOUSBEndpointDescriptor`，并将指针转为 `UnsafePointer<IOUSBDescriptorHeader>` 赋给 `current`。
  - 在 `send(_:)` 与 `receive(maxLength:)` 的 `onQueue` 闭包中移除 `[bulkOut, timeout]` / `[bulkIn, timeout]` 捕获列表，改为通过已标记 `@unchecked Sendable` 的 `self` 访问，消除 Swift 6 严格并发 `Sendable` 错误与 `@preconcurrency` 警告，并清理文件顶部的过时待编译注释。
- 验证：
  - `cd Packages/USBMTP && swift package clean && swift build`（MacOSX27.2.sdk / Apple Swift 6.4.2，2026-11-16 18:44）：构建成功，Swift 编译器 0 错误 0 警告。因当前环境仅安装 `/Library/Developer/CommandLineTools`（未安装完整 Xcode），默认 SwiftBuild 链接阶段输出 3 条系统工具链路径警告（`ld: warning: search path '/Library/Developer/CommandLineTools/Developer/...' not found`）；使用 `--build-system native` 时无该 `ld` 警告（仅提示参数已弃用）。
  - `swift run mtp-spike list`：运行成功，退出码 0（未接实机，输出 `共 0 个 USB 接口，其中疑似 MTP 0 个`）。
  - `swift test`：阻塞。本机仅装有 CommandLineTools，缺少 `XCTest.framework`（`unable to resolve module dependency: 'XCTest'`）；临时测试迁移至 Swift 6 `Testing.framework` 执行 `swift test --disable-xctest` 亦因找不到 `TestingMacros` 插件而未通过，已还原 `Tests/USBMTPTests/MTPCodecTests.swift` 为原 `XCTest` 版本。

### 2026-11-16 — M0 骨架搭建（未编译）
- 新增 `Packages/USBMTP`：`MTPCodec.swift`（容器/字符串/DeviceInfo/StorageInfo/ObjectInfo 编解码）、`MTPSession.swift`（actor 串行会话，GetDeviceInfo/OpenSession/GetStorageIDs/GetStorageInfo/GetObjectHandles/GetObjectInfo）、`IOUSBHostTransport.swift`（IORegistry 枚举 + IOUSBHostInterface Bulk 传输）、`Sources/MTPSpike/Spike.swift`（`list`/`probe`）、`Tests/USBMTPTests`（编解码与会话分块拼装）。`.gitignore` 已新增。
- 验证：无。开发机为 Windows 且无 Swift 工具链，代码未编译。`IOUSBHostTransport.swift` 中 `IOUSBGetNextEndpointDescriptor`、`__sendIORequest` 等调用的精确签名依据记忆编写，极可能需要在 Xcode 中修正。
- 遗留：未实现数据阶段发送（上传）、大于 4 GB 数据容器、事件端点、热插拔。
### 2026-11-16 — 补充约束与设计稿
- 用户补充两张 PNG 设计稿，并新增约束：支持 macOS 27、仅 USB、优先官方技术方案、可能开源须规避版权风险（详见 `AGENTS.md` 1.1）。
- 技术路线确认：放弃 Kalam，改为 Swift + IOUSBHost 自研 MTP。规格更新为 v0.2（范围、选型原则、架构、M0、风险、参考）；`AGENTS.md` 同步。

### 2026-11-16 — 规划与评审
- 阅读 `docs/DroidDock-Dev-Spec.md` 并完成可行性评审，结论：方向可行，Kalam 嵌入方式与能力边界需调整（见上）。
- 对照 OpenMTP 源码核实技术假设，结论写入 `AGENTS.md`。
- 新增 `AGENTS.md`、`READMAP.md`。未改动规格文档、未提交 git。
