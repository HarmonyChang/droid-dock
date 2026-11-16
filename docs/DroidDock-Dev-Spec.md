# DroidDock 开发与设计文档 v0.2（仅 USB，自研 MTP）

面向协作 Agent 的单文件规格。工作名 DroidDock，可更换。标记约定：**【决策】** 已确定，直接执行；**【待验证】** 来自经验推断或未经实机/源码确认，实现前必须先验证，验证后回写本文。

## 1. 目标与范围

目标：macOS（仅 Apple Silicon，支持 macOS 27，最低 macOS 14）原生应用，管理 Android 设备，覆盖两个场景：S1 浏览设备上的图片与文件；S2 在 Mac 与 Android 之间双向传输文件。定位为已停更的 HandShaker 的现代替代品，设计取向是原生质感与高颜值。

v0.1 范围：仅 USB 有线（当前阶段不考虑 Wi-Fi，后续阶段再做），协议为 MTP，手机端零安装。

v0.1 明确不做：Wi-Fi 连接及无线配对界面、Android 伴生 App、ADB 后端、App Store 上架、Intel Mac、字节级断点续传、应用私有目录访问、联系人/短信/备份、暗色模式专项设计。设计稿中的「有线/Wi-Fi」切换在 v0.1 只保留有线。

演进预留（不实现，但接口不得阻碍）：ADB 有线后端；Wi-Fi（ADB 无线调试或 Kotlin 伴生 App）。因此设备层必须按 `FileProvider` 协议抽象，上层不得依赖 MTP 细节。

## 2. 技术决策

- **【决策】选型原则**：优先 Apple 官方框架与公开规范；零第三方运行时依赖；项目可能开源，禁止引入有版权或许可证风险的代码（含 GPL/LGPL，禁止复制 libmtp 等项目源码，MTP 协议依据 USB-IF 公开规范实现）。
- **【决策】语言与 USB/MTP**：Swift 6（开启严格并发检查）。通过 Apple 官方 IOUSBHost 框架访问 USB，自研纯 Swift 的 MTP 客户端（模块 `USBMTP`）。不使用 Kalam、libusb、libmtp。
- **【决策】UI**：SwiftUI 为主，AppKit 补足（拖拽 `NSFilePromiseProvider`、Quick Look `QLPreviewPanel`；大相册滚动性能不足时下沉 `NSCollectionView`）。
- **【决策】系统与架构**：最低 macOS 14（需要 `@Observable`），必须支持 macOS 27，仅 arm64；每个 macOS 大版本需实机回归。
- **【决策】并发**：`async/await` + `actor`；UI 状态使用 `@MainActor @Observable`。
- **【决策】持久化**：缩略图与媒体索引用 SQLite（系统 SQLite3 自行封装，不引入 GRDB，符合官方优先与零第三方依赖）；偏好设置用 `UserDefaults`。
- **【决策】工程组织**：Xcode 工程加本地 Swift Package 分模块，`USBMTP` 为独立 Package，不依赖 UI。
- **【决策】分发**：先本机运行与自签；对外分发走 Developer ID 加公证。
- **【待验证】权限与沙盒**：IOUSBHost 在非沙盒、沙盒（`com.apple.security.device.usb`）下分别能否打开 MTP 接口，是否需要额外 entitlement，未验证；v0.1 默认关闭沙盒。

选型依据：MTP 为公开协议，自研可获得缩略图（`GetThumb`）、部分读取（`GetPartialObject`）、每设备独立会话、Swift 并发原生适配，并规避 LGPL。备选方案：ImageCaptureCore（官方，但面向 PTP/相机，是否能满足浏览与上传未验证，不作为主路线）；ADB（需用户开启调试，后续可作为额外后端）。已评估并放弃：OpenMTP Kalam（个人维护，依赖 LGPL 的 libusb，无缩略图接口，单设备全局会话）。

## 3. 架构

自上而下四层，依赖只能向下，上层只依赖下层的协议。

1. **UI 层**（SwiftUI）：窗口、侧栏、网格、传输托盘。不得 import `USBMTP` 或 IOKit。
2. **应用状态层**（`@MainActor @Observable`）：`AppState`、`DeviceListModel`、`BrowserModel`、`TransferModel`。
3. **服务层**：`TransferQueue`（actor）、`MediaIndex`、`ThumbnailService`（actor）。
4. **设备层**：`DeviceManager`、`DeviceSession`（actor）、`FileProvider` 的 MTP 实现，其下是独立 Package `USBMTP`（IOUSBHost 传输、MTP 容器与操作码、会话）。只有设备层可以 import `USBMTP`。

建议目录：

```
DroidDock/
  App/            入口、AppState、依赖装配
  UI/             Sidebar, Browser(Grid/List), TransferTray, Preview, Components
  Services/       TransferQueue, MediaIndex, ThumbnailService
  Device/         DeviceManager, DeviceSession, FileProvider.swift, MTP/MTPProvider.swift
  （仓库根）Packages/USBMTP/  独立 Package：USB 传输层、MTP 容器与操作码、会话；含 M0 命令行 spike `mtp-spike`
  Persistence/    Database, Migrations, CacheStore
  Support/        Logger, Errors, PathUtils
  Tests/          Unit, Fakes(FakeFileProvider)
  scripts/        构建与辅助脚本（按需）
```

## 4. 设备层

核心协议（签名可微调，语义不得改变）：

```swift
struct DeviceID: Hashable, Sendable { let rawValue: String }   // 序列号优先，退化为 vid:pid+locationID
struct StorageInfo: Sendable { let id: UInt32; let name: String; let totalBytes: UInt64; let freeBytes: UInt64 }
enum MediaKind: Sendable { case photo, video, audio, document, other }   // 由扩展名推断

struct RemoteNode: Sendable, Identifiable {
    let id: String              // backend 内唯一；MTP 为 storageID+object handle 的组合
    let storageID: UInt32
    let path: String            // 以存储根为基准的 POSIX 风格路径
    let name: String
    let isDirectory: Bool
    let size: UInt64
    let modified: Date?
    let kind: MediaKind
}

protocol FileProvider: Sendable {
    func storages() async throws -> [StorageInfo]
    func list(dir: String, storage: UInt32) async throws -> [RemoteNode]
    func thumbnail(for node: RemoteNode) async throws -> Data?   // 后端原生缩略图，无则返回 nil
    func download(_ node: RemoteNode, to url: URL, progress: @Sendable (UInt64) -> Void) async throws
    func upload(from url: URL, toDir: String, storage: UInt32, progress: @Sendable (UInt64) -> Void) async throws -> RemoteNode
    func delete(_ node: RemoteNode) async throws
    func makeDirectory(_ name: String, in dir: String, storage: UInt32) async throws
}

enum DeviceEvent: Sendable { case attached(DeviceInfo), detached(DeviceID), stateChanged(DeviceID, DeviceState) }
protocol DeviceBackend: Sendable { func events() -> AsyncStream<DeviceEvent>; func open(_ id: DeviceID) async throws -> FileProvider }
```

`DeviceState`：`.detected`、`.locked`（手机未解锁或 USB 用途非"文件传输"）、`.ready`、`.busy`、`.error(DeviceError)`。`DeviceError`：`deviceLocked`、`permissionDenied`、`busy`、`disconnected`、`storageFull`、`invalidName`、`unsupported`、`underlying(String)`。

约束：

- **【决策】串行化**：每台设备一个 `DeviceSession` actor，该设备所有 `FileProvider` 调用都经它串行执行。MTP 会话基本不支持并发事务。
- **【决策】热插拔**：用 IOKit `IOServiceAddMatchingNotification`（first-match 与 terminated）作为触发器，触发后重新枚举设备。具体 USB 接口类匹配以实机为准，不硬编码。
- **【决策】断线处理**：任何调用遇到断线都抛 `.disconnected`，会话销毁，未完成传输标记失败并保留 `.part` 清理逻辑。

已知坑（均为 **【待验证】**，M0 阶段逐项确认）：

- macOS 自带的 `ptpcamerad` 等图像捕获守护进程可能独占设备的 MTP/PTP 接口，导致 IOUSBHost 打开接口失败（`kIOReturnExclusiveAccess`）。需在 macOS 27 实机确认现象，并找到不关闭系统服务、不使用私有权限的合规方案；若无，则需重新评估方案。
- 手机锁屏或 USB 用途为"仅充电"时，MTP 存储为空或枚举失败，必须映射为 `.locked` 并引导用户，不能表现为"空设备"。
- 大目录（DCIM 数千项）首次 `list` 很慢，UI 必须流式或分批呈现。

## 5. 传输层

`TransferTask`：`id`、`direction`（`.download`/`.upload`）、`items`、`destination`、`state`（`.queued`/`.running`/`.completed`/`.failed(DeviceError)`/`.cancelled`）、`bytesDone`、`bytesTotal`、`speed`（3 秒窗口指数滑动平均）。

`TransferQueue`（actor）规则：

- 每台设备内串行执行，多设备之间可并行；取消为协作式，在块边界检查。
- **下载**：先写 `<name>.droiddock-part` 到目标目录，完成后校验大小，再原子重命名；失败或取消则删除 part 文件。
- **冲突策略**：默认自动重命名为 `name (1).ext`，设置中可改为覆盖或跳过。
- **上传**：发送前预检文件名，遇到 Android 端不接受的字符（至少包含 `:`，其余集合 **【待验证】**）则提示或替换，不得静默失败；失败项必须在 UI 的传输详情中可见并可重试。
- **重试**：不做字节级断点续传（MTP 无可靠语义），失败重试即整文件重来，自动重试至多 1 次。
- **【待验证】** 单文件大于 4 GB 的传输。

拖拽：拖出到 Finder 使用 `NSFilePromiseProvider`，在 `writePromiseTo` 回调里启动下载，不得同步阻塞主线程；拖入窗口接收文件 URL，上传到当前目录。

## 6. 媒体与缩略图

**相册聚合**（客户端实现，MTP 没有相册语义）：

- 扫描根目录为主存储的 `DCIM/**`、`Pictures/**`、`Movies/**`。照片扩展名：jpg、jpeg、png、heic、heif、webp、gif、dng；视频扩展名：mp4、mov、mkv、3gp、webm。
- 截图判定：路径含 `Screenshots`。
- 按日期降序、按自然日分组；日期取对象信息中的拍摄或修改时间，缺失则回退文件修改时间。**【待验证】** MTP 日期字段的质量与时区行为。
- 首次连接在后台低优先级递归扫描，结果写入 SQLite 表 `media_index(device, storage, path, size, mtime, kind)`；重连时用目录列表比对做增量刷新；UI 按每批 500 项增量更新。

**缩略图流水线**（按顺序，命中即停）：内存 `NSCache` → 磁盘缓存 → 后端原生缩略图（`FileProvider.thumbnail`）→ 兜底：下载到临时文件后，照片用 ImageIO `CGImageSourceCreateThumbnailAtIndex`、视频用 `AVAssetImageGenerator` 生成，写入缓存。

- 缩略图最长边 320 px；磁盘缓存键为 `sha1(deviceID|storage|path|size|mtime)`；默认总上限 2 GB，LRU 淘汰，位于系统 Caches 目录。
- 设备 IO 遵守第 4 节串行约束；Mac 侧解码并发上限为 `min(4, 核心数)`。
- 可见优先：单元格滚出视口时取消其未开始的请求。
- 可选优化 **【待验证】**：对 JPEG 用部分读取前 64 KB 提取 EXIF 内嵌缩略图，依赖设备是否支持部分读取。
- 预览：空格键触发，将文件下载到临时缓存后用 `QLPreviewPanel` 展示。

## 7. UI 规格

设计稿（画布，含主窗口与无线配对两个画板）：https://claude.ai/artifact/CnE8tsvWgLGkGTxhfXqf3u ，链接默认仅作者可见，需要时由作者分享。v0.1 **不实现**无线配对画板，仅作为后续参考；USB 场景的连接引导用空状态页代替。

**主窗口**（`NavigationSplitView`）：

- 侧栏宽 232 pt。顶部设备卡片（设备名、连接状态点、"USB 有线"文案）；分组"媒体"（相册、视频、截图，带计数）、"文件"（内部存储、下载、文档）、"传输"（传输队列，带进行中计数）；底部存储用量条（已用/总量）。
- 工具栏高 52 pt：前进后退、标题加"总数 · 已选数"、网格/列表切换、搜索框、"上传到手机"、主按钮"导入到 Mac"。
- 内容区：过滤标签（全部、照片、视频、截图）；按日期分组的缩略图网格，单元格为正方形，最小宽 132 pt，间距 6 pt，圆角 8 pt；选中为 3 pt 主色描边加右上角对勾徽标；视频单元格左下角显示时长徽标。
- 传输托盘：窗口底部悬浮，高 56 pt，圆角 12 pt，带轻阴影；显示任务名、`已传/总量 · 速度 · 剩余时间`、进度条、取消按钮。

**设计取值**（实现时优先用系统语义色与 Asset Catalog 的 AccentColor，下表为设计稿数值，便于对照）：主色 `#2B5FE0`，侧栏底 `#EEEEF1`，分割线 `#E5E5EA`，主文字 `#1D1D1F`，次文字 `#636366`，成功 `#1E7A3C`，警告 `#B7791F`。字体用系统字体（`-apple-system`），中文回退 PingFang SC。

**交互**：双击目录进入、双击文件预览；空格 Quick Look；⌘A 全选；Shift/⌘ 多选；Delete 键触发删除确认；拖出到 Finder 为下载，拖入窗口为上传。

**必须覆盖的状态**：无设备（连接引导）、设备已连接但被锁定（提示"解锁手机，并在 USB 用途中选择文件传输"）、首次扫描中、目录为空、错误横幅、传输中途断线。

## 8. 里程碑与验收

- **M0 可行性验证（spike）**：最小命令行工具，用 IOUSBHost 在 macOS 27 Apple Silicon 实机上打开手机 MTP 接口，完成 `OpenSession`、列出存储并列出 `DCIM`。首要验证 `ptpcamerad` 独占问题。验收：完成第 4、6 节全部 **【待验证】** 项的实测记录并回写本文；若 ptpcamerad 问题无合规解，停止并重新评估路线。
- **M1 设备层与文件视图**：热插拔、存储列表、目录导航、锁定态识别。验收：拔插设备 UI 正确更新，锁屏有明确提示。
- **M2 传输**：下载、上传、队列、托盘、拖入拖出、冲突策略。验收：混合 1 GB 级文件批量双向传输成功，取消与断线后无残留 `.part` 文件。
- **M3 相册与缩略图**：媒体索引、网格、缓存、预览。验收：5000 张照片的相册首屏可交互，滚动无明显卡顿，重连后增量刷新。
- **M4 打磨与分发**：错误与空状态补全、日志、签名与公证。验收：干净 Mac 上安装可运行。

## 9. 工程约定

- Swift 6 严格并发保持开启；非测试代码禁止强制解包；日志用 `os.Logger`，统一 subsystem。
- 单元测试必须覆盖：`TransferQueue` 状态机、文件名预检与冲突重命名、相册分组、缩略图缓存键与淘汰；以 `FakeFileProvider` 隔离设备。真机测试走手动清单（不同品牌各至少一台）。
- 不得引入本文未列出的第三方依赖，必须引入时先更新本文并说明理由。
- 所有标 **【待验证】** 的结论在验证前不得当作事实写入代码注释或文档。

## 10. 风险汇总

1. IOUSBHost 能否在 macOS 27 上合规打开 MTP 接口（`ptpcamerad` 独占问题），是 M0 的首要风险，也决定路线是否成立。
2. 沙盒与 USB entitlement 的组合未验证。
3. macOS 守护进程占用 USB 接口的问题需实机确认。
4. MTP 日期字段、缩略图支持、大于 4 GB 传输、非法文件名集合在不同厂商设备上可能表现不一。
5. 系统大版本兼容：每次 macOS 大版本发布都需要回归测试（同类竞品 OpenMTP、MacDroid 均发布过系统兼容修复），这是长期维护成本。
6. 设备碎片化：国产 ROM 的 USB 模式弹窗与权限行为差异，需多机型测试。

## 11. 参考

- 协议：USB-IF《Media Transfer Protocol》公开规范；Apple IOUSBHost 官方文档。竞品 OpenMTP（MIT）仅作行为参考，不引入其代码。
- 竞品：MacDroid（官网 macdroid.app，USB 与 Wi-Fi，挂载进 Finder，PRO 买断价格以官网为准）；HandShaker（已停更，仅 x86-64）。
- 设计稿：见第 7 节链接。
