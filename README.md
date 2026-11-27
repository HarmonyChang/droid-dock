<div align="center">

# DroidDock

**原生 macOS Android 文件与相册管理助手 -- 纯 Swift 打造，零手机端强制依赖**

![Platform](https://img.shields.io/badge/macOS-14.0%2B%20(Apple%20Silicon)-1D2228?style=flat-square)
![Swift](https://img.shields.io/badge/Swift-6.0-355C7D?style=flat-square)
![Version](https://img.shields.io/badge/Release-v0.2.1-2B7A58?style=flat-square)
![Dependencies](https://img.shields.io/badge/Dependencies-Zero%20Third--Party-4A6B53?style=flat-square)

**简体中文** | [English](./README_EN.md)

</div>

---

DroidDock 是一款专为 Apple Silicon Mac 设计的原生 Android 设备管理桌面应用（Swift 6 + SwiftUI + AppKit），定位为现代、高速、可靠的文件与媒体双向传输工具。底层不依赖 `libmtp` / `libusb` 等 GPL/LGPL 库，完全基于 Apple 官方 `IOUSBHost` 与公开 USB-IF MTP 规范自主实现，同时支持同局域网无线连接双模式，开箱即用。

---

## 核心特性

### 1. 纯 Swift USB MTP 有线传输（零手机端安装）
- **自研 `USBMTP` 协议栈**：基于 Apple `IOUSBHost` 实现设备枚举、会话管理、对象读写与缩略图拉取，无第三方开源协议库版权风险。
- **系统级接口接管与防劫持**：自动接管被 `ptpcamerad` 占用的 MTP 接口，并通过父级 `IOUSBHostDevice` 的 `.deviceSeize` 锁护防止第三方跨屏守护进程（如厂商 AOA 服务）在传输途中抢占连接导致掉线。
- **USB 2.0 大包边界与断线恢复**：针对 High-Speed Bulk-OUT（`512` 字节 `wMaxPacketSize`）补发真实 Zero-Length Packet（ZLP），避免恰逢 512 字节整数倍文件在 Android 端阻塞超时；区分瞬时超时/忙等待与真实硬件拔出，支持自动重试与 `invalidateAndReconnect` 连接自愈。
- **锁定与仅充电态识别**：锁屏或 USB 处于「仅充电」模式时明确提示等待解锁/切换传输模式，不误报为空设备，解锁后自动轮询恢复就绪状态。

### 2. 十万级目录高速稳定双向传输
- **流式扫盘与零卡顿队列**：通过后台 `AsyncStream` 每 `500` 项分批扫描本地大目录并立即启动传输；队列调度与进度累计全面采用 O(1) 字典与游标索引，超 `400` 项时自动以 10 Hz 节流窗口化渲染 UI 快照，支持数十 GB / 十万级文件稳定上传不假死。
- **目录存在性与列表缓存**：逐级建目录与重名检查引入 `ensuredDirectories` 与 `cachedRemoteDirectories` 缓存，消除海量冗余 MTP 往返；整批上传完毕后再统一刷新文件浏览器视图，避免每传一个文件触发全盘重载。
- **原子传输与冲突策略**：下载采用 `<filename>.droiddock-part` 临时文件写入并校对后原子替换（取消/失败自动清理残留）；支持「重命名」「覆盖」「跳过」三种同名冲突策略；支持从 Finder 拖入上传及通过 `NSFilePromiseProvider` 直接拖出到桌面/文件夹。
- **防休眠与通道优先级**：批量传输期间自动申请系统防 App Nap 与防空闲休眠断言，同时自动暂停后台网格缩略图拉取，将完整 USB 带宽优先让渡给文件传输。

### 3. 媒体相册网格与高清 EXIF 查看器
- **流畅相册索引与网格视图**：内置 SQLite3（系统原生 C API，无 ORM 依赖）增量媒体索引，按日期/分类呈现全部照片、视频与截屏。
- **LIFO 可见优先与极速缩略图**：设备端缩略图加载采用 LIFO 策略，滑停后当前视口图片最先出图；原生 `GetThumb` 缺失时自动通过 `GetPartialObject` 读取文件前 `128 KB` 提取内嵌 EXIF 缩略图并做后台解码位图缓存。
- **高清大图预览与 EXIF 浮窗**：双击照片自动抢占设备通道加载原图并在后台完成高分辨率预解码（已处理 EXIF 方向矫正），支持 `←` / `→` 切换相邻照片、250 ms 静默预取、Quick Look（空格键）以及右上角半透明 EXIF 拍摄参数浮窗（尺寸、相机/镜头、光圈快门 ISO、时间、色彩配置、GPS 与路径）。

### 4. 同局域网无线连接双模式
- **扫码网页快传（零手机 App 依赖）**：内置轻量级 HTTP 服务器 `QuickDropWebServer`，支持同一 Wi-Fi 下手机系统相机扫码即刻互传单文件、多图与完整文件夹（目录自动 ZIP 打包流式下载），且不影响手机正常接入互联网。
- **无线调试全盘管理（ADB）**：通过原生 `Network.framework`（Bonjour / mDNS `_adb-tls-pairing._tcp.` 与 `_adb-tls-connect._tcp.`）自动发现并支持二维码/配对码一键配对及同 Wi-Fi 静默重连；未内置环境时支持在引导弹窗一键获取 Google 官方 Android `platform-tools`。

### 5. 手机状态展示、主题与自动升级
- **设备状态胶囊与详情浮窗**：侧边栏设备卡展示电池电量、充放电状态、网络方式或 USB 链路速率胶囊，点击可展开完整设备详情（电量温度、Wi-Fi 名称 SSID、`5G` / `4G` / `3G` 网络、局域网 IPv4、系统/固件版本、内部存储及一键复制 IP 与序列号）；传输进行中自动跳过 60 秒后台轮询以保护带宽。
  > 说明：USB 有线 MTP 协议依据设备上报能力读取电池电量与 IORegistry USB 链路速率，协议本身不暴露手机 Wi-Fi/蜂窝网络状态；连接「无线调试」后可获取完整电量温度、网络制式、SSID 与局域网 IP。
- **四套「儒雅彩色」浅色主题**：内置竹青宣纸、黛蓝宋锦（默认）、松烟茶白、晨雾晴岚配色，支持即时切换并持久化。
- **版本记录与 GitHub Releases 自动升级**：内置完整变更日志面板，可按开关启动检查（6 小时频控）或手动检查 [GitHub Releases](https://github.com/HarmonyChang/droid-dock/releases) ，支持后台流式下载、SHA-256 与 `codesign` 双重校验、传输进行中安全拦截以及带老版本备份回滚的自动替换重启。
- **诊断报告导出**：一键汇总设备状态、存储信息、传输失败明细与最近 `OSLog` 日志导出纯文本报告。

---

## 界面设计预览

> 以下为 `docs/` 目录中的界面设计参考图（对应当前主窗口与无线配对核心交互规划）：

| 主窗口 · 相册视图 | 设备连接 · 无线配对 |
| :---: | :---: |
| ![主窗口与相册视图](./docs/%E4%B8%BB%E7%AA%97%E5%8F%A3%20%C2%B7%20%E7%9B%B8%E5%86%8C%E8%A7%86%E5%9B%BE.png) | ![无线配对界面](./docs/%E8%AE%BE%E5%A4%87%E8%BF%9E%E6%8E%A5%20%C2%B7%20%E6%97%A0%E7%BA%BF%E9%85%8D%E5%AF%B9.png) |

---

## 环境要求与安装

### 系统要求
- **硬件平台**：Apple Silicon Mac（`arm64`）
- **操作系统**：macOS `14.0` 或更高版本（支持 macOS `27`）
- **移动端**：Android 设备，无需安装额外手机客户端

### 安装与首次启动说明
1. 前往 [GitHub Releases](https://github.com/HarmonyChang/droid-dock/releases) 下载最新版本的 `DroidDock-<version>-arm64.dmg`（可搭配同页面 `.dmg.sha256` 校验文件完整性）。
2. 双击打开 `.dmg` 镜像，将 `DroidDock.app` 拖入「应用程序」文件夹。
3. **首次运行提示**：当前 Release 包使用本地 Ad-hoc 签名（未经过 Apple Developer 公证）。如从网络下载后系统提示「已损坏」或「无法验证开发者」，可在终端执行一次以下命令清理下载隔离属性后即可正常打开（通过应用内自动升级替换时会由安装脚本自动清理）：

```bash
xattr -dr com.apple.quarantine /Applications/DroidDock.app
```

---

## 开发构建、测试与打包

### 源码构建与运行测试
项目仅依赖 Apple 系统框架与内置 Swift Package（`USBMTP`），克隆仓库后无需额外包管理器拉取依赖即可在 macOS + Xcode 环境下构建：

```bash
# 1. 运行底层 USBMTP 协议栈单元测试
cd Packages/USBMTP && swift test && cd ../..

# 2. 构建主工程并运行完整单元测试（单元测试已隔离，不会抢占真机 USB）
xcodebuild \
  -project DroidDock.xcodeproj \
  -scheme DroidDock \
  -destination 'platform=macOS,arch=arm64' \
  build test
```

### Release 打包（DMG + SHA-256）

```bash
bash scripts/package-app.sh
```

脚本会自动读取工程 `MARKETING_VERSION`，以 Release 模式编译 `arm64` 应用、签名校验并输出到 `dist/` 目录：
- `dist/DroidDock.app`
- `dist/DroidDock-<version>-arm64.dmg`
- `dist/DroidDock-<version>-arm64.dmg.sha256`

如持有正式开发者签名证书，可通过环境变量传入身份与公证配置：

```bash
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
NOTARIZE_PROFILE="notary-profile" \
bash scripts/package-app.sh
```

---

## 常用快捷键

| 快捷键 | 作用 |
| --- | --- |
| `⌘ + Shift + W` | 打开「无线连接手机」配对与扫码快传面板 |
| `⌘ + Shift + R` | 重新检测 USB / 无线设备连接 |
| `⌘ + R` | 刷新当前目录或相册内容 |
| `⌘ + A` | 全选当前视图中的文件或媒体项目 |
| `Space`（空格） | 打开/关闭系统 Quick Look 预览当前选中文件；大图查看器内关闭预览 |
| `←` / `→` / `Esc` | 在高清大图查看器中切换上一张 / 下一张照片或退出预览 |

---

## 项目架构与目录结构

架构遵循**单向向下依赖**与 strict concurrency（Swift 6）：`UI` -> `App`（`@MainActor @Observable`）-> `Services`（`actor` / `@MainActor`）-> `Device`（协议抽象 `FileProvider` 与 `DeviceSession`）-> `Packages/USBMTP`（仅在 [MTPProvider.swift](./DroidDock/Device/MTP/MTPProvider.swift) 引入，UI 层完全隔离 USB 与底层协议细节）。

```text
droid-dock/
├── DroidDock/
│   ├── App/                        # 应用入口与状态层：DroidDockApp、AppState、BrowserModel、TransferModel
│   ├── UI/                         # SwiftUI 与 AppKit 视图：SidebarView、BrowserContentView、PhotoPreviewView、TransferTrayView、AppUpdateSheetView 等
│   ├── Services/                   # 业务服务：TransferQueue、ThumbnailPipeline、MediaIndexStore、QuickDropWebServer、AppUpdateService
│   ├── Device/                     # 设备抽象与双模后端：FileProvider、DeviceSession、DeviceManager、MTP/、ADB/
│   ├── Support/                    # 基础设施：DiagnosticsService、PathUtils、Errors、Logger
│   ├── Resources/                  # 应用图标与资源清单（Assets.xcassets）
│   └── Tests/                      # 主工程单元测试（FakeFileProvider 隔离真机硬件）
├── Packages/
│   └── USBMTP/                     # 独立 Swift Package：IOUSBHostTransport、MTPCodec、MTPSession、mtp-spike CLI 及单测
├── scripts/
│   └── package-app.sh              # Release 编译、codesign 校验、DMG 封装与 SHA-256 生成脚本
├── docs/                           # 开发设计规格、UI 设计稿与静态预览截图
├── CHANGELOG.md                    # 正式版本变更记录
├── READMAP.md                      # 阶段里程碑与实机验证日志
└── AGENTS.md                       # 项目工程规范与边界约定
```

---

## 相关文档

- [版本记录（CHANGELOG）](./CHANGELOG.md)
- [开发进度与实机记录（READMAP）](./READMAP.md)
- [开发与设计规格（Dev Spec）](./docs/DroidDock-Dev-Spec.md)
- [项目工程规范（AGENTS）](./AGENTS.md)
