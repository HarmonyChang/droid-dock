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

已知坑（M0 阶段逐项确认，已验证项标 **【已验证】**）：

- **【已验证 2026-11-16】** `ptpcamerad` 独占问题（macOS 27.2.1 + OnePlus 13T 实测）：手机开启文件传输后，`icdd` 会拉起当前用户（非 root）的 `/usr/libexec/ptpcamerad` 独占 `IOUSBHostInterface`（`UsbExclusiveOwner`），导致 `IOUSBHostInterface` 初始化报错 `-536870199`（`kIOReturnInternalError` / `Failed [super init]`；同理独占场景亦可能触发 `kIOReturnExclusiveAccess`）。实测 `.deviceSeize` 被拒、`.deviceCapture` 需受限虚拟化权限（`-536870207` / `kIOReturnNotPrivileged`）、`configure(0)` 会中断 Android `f_mtp`、`IOUSBHostDevice.reset()` 会触发 ColorOS 退回「仅充电」。**【决策】** 采用「热插拔监听抢先打开 + 若遇独占错误自动结束当前用户的 `ptpcamerad` 进程并在毫秒级重试打开接口」，无需 `sudo` 或特殊权限，且不重置手机端 USB 状态。
- **【已验证 2026-11-16】** 第三方跨屏助手 AOA 抢占（macOS 27.2.1 + OnePlus 13T + `O+Connect Service` 实测）：若 Mac 安装有厂商跨屏工具（如 `O+Connect Service`），其后台服务会在手机枚举为 MTP（`0x22d9/2764`）约 1.9 秒后打开父级 `IOUSBHostDevice` 并向 endpoint 0 下发 AOA 切换指令，将手机切至 `0x18d1/2d00` 后退出，导致手机回落「仅充电」（`GetStorageIDs` 返回 0 个存储）；且在我方释放 `IOUSBHostDevice` 后约 1.8 秒内该服务会再次介入劫持。**【决策】** 打开 MTP `IOUSBHostInterface` 的同时通过 `IOUSBHostDevice(..., options: [.deviceSeize])` **持续锁定**父级 `IOUSBHostDevice` 直至设备断开或应用退出（可阻止其他进程打开设备发送控制请求，`kIOReturnExclusiveAccess` / `-536870203`）。
- **【已验证 2026-11-16】** 手机锁屏或 USB 用途为"仅充电"时，MTP 允许 `OpenSession` 但 `GetStorageIDs` 返回 `0x2001` 且存储列表为空（0 项），必须映射为 `.locked` 并引导用户，不能表现为"空设备"。
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
- 按日期降序、按自然日分组；日期取对象信息中的拍摄或修改时间，缺失则回退文件修改时间。**【部分验证 2026-11-16】** OnePlus 13T 实测对象返回 `YYYYMMDDThhmmss` 无时区后缀格式（如 `20260115T201015`）；其余厂商及夏令时/时区行为 **【待验证】**。
- 首次连接在后台低优先级递归扫描，结果写入 SQLite 表 `media_index(device, storage, path, size, mtime, kind)`；重连时用目录列表比对做增量刷新；UI 按每批 500 项增量更新。

**缩略图流水线**（按顺序，命中即停）：内存 `NSCache` → 磁盘缓存 → 后端原生缩略图（`FileProvider.thumbnail`）→ 兜底：下载到临时文件后，照片用 ImageIO `CGImageSourceCreateThumbnailAtIndex`、视频用 `AVAssetImageGenerator` 生成，写入缓存。

- 缩略图最长边 320 px；磁盘缓存键为 `sha1(deviceID|storage|path|size|mtime)`；默认总上限 2 GB，LRU 淘汰，位于系统 Caches 目录。
- 设备 IO 遵守第 4 节串行约束；Mac 侧解码并发上限为 `min(4, 核心数)`。
- 可见优先：单元格滚出视口时取消其未开始的请求。
- 可选优化 **【部分验证 2026-11-16】**：对 JPEG 用部分读取前 64 KB 提取 EXIF 内嵌缩略图；OnePlus 13T 实测 `GetPartialObject` 返回 `0x2001` 成功读取（已在 `.nomedia` 验证），真实 JPEG 64 KB 截断提取与原生 `GetThumb` 数据对比 **【待验证】**。
- **预览与查看**：双击照片打开内建高清图片查看器（支持**双击图片在 1.0x ↔ 2.5x 间放大/还原**、双指捏合 1.0x–4.0x、拖拽平移及左右切换相邻照片）；空格键触发图片查看器或调用系统 `QLPreviewPanel` 预览视频与文档。

## 7. UI 规格

设计稿（画布，含主窗口与无线配对两个画板）：https://claude.ai/artifact/CnE8tsvWgLGkGTxhfXqf3u ，链接默认仅作者可见，需要时由作者分享。v0.1 **不实现**无线配对画板，仅作为后续参考；USB 场景的连接引导用空状态页代替。

**主窗口**（`NavigationSplitView`）：

- 侧栏宽 232 pt。顶部设备卡片（设备名、连接状态点、"USB 有线"文案）；分组"媒体"（相册、视频、截图，带计数）、"文件"（内部存储、下载、文档）、"传输"（传输队列，带进行中计数）；底部存储用量条（已用/总量）。
- 工具栏高 52 pt：前进后退、标题加"总数 · 已选数"、网格/列表切换、搜索框、"上传到手机"、主按钮"导入到 Mac"。
- 内容区：过滤标签（全部、照片、视频、截图）；按日期分组的缩略图网格，单元格为正方形，最小宽 132 pt，间距 6 pt，圆角 8 pt；选中为 3 pt 主色描边加右上角对勾徽标；视频单元格左下角显示时长徽标。
- 传输托盘：窗口底部悬浮，高 56 pt，圆角 12 pt，带轻阴影；显示任务名、`已传/总量 · 速度 · 剩余时间`、进度条、取消按钮。

**设计取值**（已实装 4 套可实时切换并持久化于 `UserDefaults` 的「儒雅彩色」温润浅色配色，默认**方案 B · 黛蓝宋锦 `songIndigo`**）：

- **方案 A · 竹青宣纸（`bambooPaper`）**：侧栏底 `#F4F1EA`、内容底 `#FAF8F3`、主色 `#2E6F65`、主字 `#1E2421`、次字 `#626C66`。
- **方案 B · 黛蓝宋锦（`songIndigo`，默认）**：侧栏底 `#F2EFE9`、内容底 `#FBF9F5`、主色 `#355C7D`、主字 `#1D2228`、次字 `#616873`。
- **方案 C · 松烟茶白（`pineTea`）**：侧栏底 `#F3EFE7`、内容底 `#FAF8F2`、主色 `#4A6B53`、主字 `#23221E`、次字 `#6E685F`。
- **方案 D · 晨雾晴岚（`morningMist`）**：侧栏底 `#EEF2F7`、内容底 `#F9FBFD`、主色 `#3B66B0`、主字 `#1C222B`、次字 `#5E6877`。
- 字体用系统字体（`-apple-system`），中文回退 PingFang SC；导航与文件分类采用低饱和彩色徽标卡片。

**交互**：双击目录进入、双击照片打开内建查看器（支持双击图片在 1.0x ↔ 2.5x 间放大/还原，左右方向键与左右浮层按钮切换相邻照片，其余非目录文件下载后调用 Quick Look）；空格预览；⌘A 全选；Shift/⌘ 多选；Delete 键触发删除确认；拖出到 Finder 为下载，拖入窗口为上传；支持菜单「设备与诊断 → 导出诊断日志…」。

**必须覆盖的状态**：无设备（连接引导）、设备已连接但尚未开放文件权限（自动轮询存储就绪并支持立即重试）、首次扫描中、目录为空、错误横幅、传输中途断线。

## 8. 里程碑与验收

- **M0 可行性验证（spike）**：最小命令行工具，用 IOUSBHost 在 macOS 27 Apple Silicon 实机上打开手机 MTP 接口，完成 `OpenSession`、列出存储并列出 `DCIM`。首要验证 `ptpcamerad` 独占问题。验收：完成第 4、6 节全部 **【待验证】** 项的实测记录并回写本文；若 ptpcamerad 问题无合规解，停止并重新评估路线。
- **M1 设备层与文件视图**：热插拔、存储列表、目录导航、锁定态识别。验收：拔插设备 UI 正确更新，锁屏有明确提示。
- **M2 传输**：下载、上传、队列、托盘、拖入拖出、冲突策略。验收：混合 1 GB 级文件批量双向传输成功，取消与断线后无残留 `.part` 文件。
- **M3 相册与缩略图**：媒体索引、网格、缓存、预览。验收：5000 张照片的相册首屏可交互，滚动无明显卡顿，重连后增量刷新。
- **M4 打磨与分发**：品牌 Logo 与 `AppIcon.appiconset`、错误与空状态补全、进程内日志导出（`OSLogStore`）、`codesign` 签名与 `.dmg` 安装包（[package-app.sh](scripts/package-app.sh)）。验收：独立构建的 `dist/DroidDock.app` 与 `.dmg` 签名校验通过并在本机可安装运行。
- **M5（第二阶段）双模式同网无线传输与连接**：
  - **默认 · 新手扫码快传（[QuickDropWebServer](DroidDock/Services/QuickDropWebServer.swift)）**：Mac 端基于 `Network.framework` 启动带一次性安全令牌的局域网 HTTP 传图/传文件/传文件夹服务，手机相机或微信/浏览器扫码即开极简中文网页（免安装端侧 App、免开开发者选项、手机不断网），支持手机批量传图/视频或整个文件夹（保留目录结构）到 Mac，以及 Mac 拖放文件或文件夹后在手机端按 3 列缩略图网格预览相册（含全屏大图/视频灯箱切换）并一键 ZIP 打包下载文件夹。
  - **进阶 · 同网无线调试发现与扫码直连**：基于 Android 系统内置无线调试 + Bonjour（`_adb-tls-connect._tcp.` / `_adb-tls-pairing._tcp.`）实现同一 Wi-Fi 下自动发现、扫码配对（`WIFI:T:ADB;S:...;P:...;;`）与 6 位配对码直连，不切换热点、不影响手机正常上网，并通过 [ADBFileProvider](DroidDock/Device/ADB/ADBProvider.swift) 与 [CompositeDeviceBackend](DroidDock/Device/DeviceManager.swift) 无缝接入统一相册、缩略图与双向拖拽传输（界面内置各品牌手机无线调试分步开启教程）。

## 9. 工程约定

- Swift 6 严格并发保持开启；非测试代码禁止强制解包；日志用 `os.Logger`，统一 subsystem。
- 单元测试必须覆盖：`TransferQueue` 状态机、文件名预检与冲突重命名、相册分组、缩略图缓存键与淘汰；以 `FakeFileProvider` 隔离设备。真机测试走手动清单（不同品牌各至少一台）。
- 不得引入本文未列出的第三方依赖，必须引入时先更新本文并说明理由。
- 所有标 **【待验证】** 的结论在验证前不得当作事实写入代码注释或文档。

## 10. 风险汇总

1. ~~`ptpcamerad` 独占问题~~（已于 2026-11-16 在 macOS 27.2.1 实机验证：采用热插拔抢先打开 + 遇 `kIOReturnExclusiveAccess` 自动结束当前用户 `ptpcamerad` 并重试接管，后续随 macOS 升级需继续回归，且仅适用非沙盒环境）。
2. 沙盒与 USB entitlement 的组合未验证（v0.1 默认关闭沙盒；若未来需上架沙盒化，结束外部用户态进程 `ptpcamerad` 将受沙盒限制）。
3. macOS 守护进程占用 USB 接口的问题需实机确认。
4. MTP 日期字段、缩略图支持、大于 4 GB 传输、非法文件名集合在不同厂商设备上可能表现不一。
5. 系统大版本兼容：每次 macOS 大版本发布都需要回归测试（同类竞品 OpenMTP、MacDroid 均发布过系统兼容修复），这是长期维护成本。
6. 设备碎片化：国产 ROM 的 USB 模式弹窗与权限行为差异，需多机型测试。

## 11. 参考

- 协议：USB-IF《Media Transfer Protocol》公开规范；Apple IOUSBHost 官方文档。竞品 OpenMTP（MIT）仅作行为参考，不引入其代码。
- 竞品：MacDroid（官网 macdroid.app，USB 与 Wi-Fi，挂载进 Finder，PRO 买断价格以官网为准）；HandShaker（已停更，仅 x86-64）。
- 设计稿：见第 7 节链接。
