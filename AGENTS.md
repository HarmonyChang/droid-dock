# AGENTS.md — DroidDock

所有 Agent 开始工作前必须阅读：本文件、`READMAP.md`（进度）、`docs/DroidDock-Dev-Spec.md`（完整规格）。全局规则（用户级 AGENTS.md）依然生效，本文件在不降低全局红线的前提下优先。

## 1. 项目简介

DroidDock：macOS（仅 Apple Silicon，最低 macOS 14）原生应用，用于管理 Android 设备上的图片与文件，覆盖 S1 浏览设备图片与文件、S2 Mac 与 Android 双向传输。定位为已停更 HandShaker 的现代替代品。

- v0.1 范围：仅 USB 有线，协议 MTP，手机端零安装。
- v0.1 不做：Wi-Fi、Android 伴生 App、ADB 后端、App Store 上架、Intel Mac、字节级断点续传、应用私有目录、联系人/短信/备份、暗色模式专项。
- 演进预留：ADB 有线后端、Wi-Fi。设备层必须按 `FileProvider` 协议抽象，上层不得依赖 MTP 细节。

## 1.1 硬性约束（用户指定，2026-11-16）

1. 必须支持 macOS 27（同时保持最低 macOS 14 的现有决策，后续如要调整须先改规格）。
2. 当前阶段只做 USB 连接下的 Android 文件获取、展示与传输；Wi-Fi 留到后续阶段，设计稿中的 Wi-Fi 切换与无线配对界面本阶段不实现。
3. 技术选型优先官方推荐方案（Apple 官方框架、Android 官方工具与规范），避免依赖个人维护的第三方库。
4. 项目可能开源：禁止引入有版权或许可证风险的依赖与代码（GPL/LGPL 静态链接、来源不明或无许可证的代码、复制 LGPL/GPL 项目源码）。引入任何依赖前必须核实许可证并更新规格。

> 技术路线已于 2026-11-16 确认：放弃 Kalam，改为 Swift + Apple IOUSBHost 自研纯 Swift MTP 客户端（模块 `USBMTP`）。规格已更新为 v0.2。

## 2. 文档索引

| 文件 | 用途 |
|---|---|
| `docs/DroidDock-Dev-Spec.md` | 开发与设计规格（唯一的需求与设计来源） |
| `docs/主窗口 · 相册视图.png` | 主窗口设计稿（本阶段实现；图中「有线/Wi-Fi」切换本阶段只保留有线） |
| `docs/设备连接 · 无线配对.png` | 无线配对设计稿（本阶段不实现，仅作后续参考） |
| `docs/DroidDock — Android 文件管理 UI 设计.html` | 原型设计稿 HTML（打包页面，需在浏览器中打开） |
| `AGENTS.md` | 项目信息与规则（本文件） |
| `READMAP.md` | 开发进度与阶段记录 |
| `docs/架构演进与关键排障笔记.md` | 纯 Swift MTP 路线、ZLP/十万级队列修复及无线/更新机制专题总结 |

## 3. 技术栈与架构

- Swift 6（严格并发开启）；SwiftUI 为主，AppKit 补足（`NSFilePromiseProvider`、`QLPreviewPanel`，必要时 `NSCollectionView`）。
- 并发：`async/await` + `actor`；UI 状态 `@MainActor @Observable`。
- 持久化：系统 SQLite3 自行封装（不引入 GRDB）+ `UserDefaults`。
- USB/MTP：Apple IOUSBHost + 自研 `USBMTP` Package，依据 USB-IF 公开 MTP 规范实现；禁止复制 libmtp 等 GPL/LGPL 代码。已放弃 OpenMTP Kalam。
- 分层（依赖只能向下）：UI → 应用状态（`AppState`/`DeviceListModel`/`BrowserModel`/`TransferModel`）→ 服务（`TransferQueue`/`MediaIndex`/`ThumbnailService`）→ 设备（`DeviceManager`/`DeviceSession`/`FileProvider`/`KalamBridge`）。
- 只有设备层可以 import `USBMTP`；UI 层不得 import `USBMTP` 或 IOKit。
- 目录结构：`DroidDock/{App,UI,Services,Device,Persistence,Support,Tests}`，独立 Package 位于仓库根 `Packages/USBMTP`。以规格第 3 节为准。

## 4. 已核实事实与待验证事项（2026-11-16）

以下为放弃 Kalam 路线的依据（来源：`github.com/ganeshrvel/openmtp` 的 `ffi/kalam/native`、`go-mtpx`、`go-mtpfs` 源码与 GitHub release），同时保留对自研方案仍有意义的结论。

- ✅ Kalam 以 `go build -buildmode=c-shared` 产出 `kalam.dylib`，通过 cgo 链接 `libusb`（构建依赖 brew 的 `libusb`、`pkg-config`）。
- ✅ OpenMTP 与 go-mtpx 为 MIT；go-mtpfs 为 New BSD。**libusb 为 LGPL**，因此 Kalam 路线同样有 LGPL 问题：必须动态链接并随 app 打包，禁止静态链入。
- ✅ OpenMTP 3.3.0 发布于 2026-08-22，修复 macOS 27 arm64 启动崩溃；官方称下一代版本在开发中。
- ✅ Kalam 仅导出 11 个函数：`Initialize`、`FetchDeviceInfo`、`FetchStorages`、`MakeDirectory`、`FileExists`、`DeleteFile`、`RenameFile`、`Walk`、`UploadFiles`、`DownloadFiles`、`Dispose`。
- ✅ 调用约定：入参为 JSON 字符串（`*C.char`），结果经回调 `void(*)(char*)` 以 JSON 字符串返回；上传/下载有 preprocess、progress、done 三个回调。
- ✅ **没有缩略图接口，没有部分读取（partial read）接口。** 规格第 6 节中「后端原生缩略图」与「前 64 KB 取 EXIF」在 Kalam 路线下不可用，除非修改 Go 层增加导出。
- ✅ **Kalam 是单设备单全局会话**（全局 `deviceContainer`），且全局 `lockMtp()` 在已有操作时直接返回 `ErrorMtpLockExists`，并非排队等待。因此「多设备并行」在同一个 Kalam 实例内不成立；上层的串行化必须由 `DeviceSession` 自己保证，不能依赖 Kalam。
- ✅ `Walk` 支持 `recursive`/`skipHiddenFiles` 等参数；`DownloadFiles`/`UploadFiles` 以路径列表为单位，不是单文件句柄接口。
- ✅ OpenMTP 宣称支持大于 4 GB 文件传输（官方 README 说明，未实测）。
- ✅ （2026-11-16 macOS 27.2.1 + OnePlus 13T 实机验证）手机开启文件传输后，`icdd` 会拉起当前用户的 `/usr/libexec/ptpcamerad` 独占 `IOUSBHostInterface`（`UsbExclusiveOwner`），导致 `IOUSBHostInterface` 报错 `-536870199`（`kIOReturnInternalError` / `Failed [super init]`）。实测 `.deviceSeize` 被拒、`.deviceCapture` 需受限权限（`kIOReturnNotPrivileged`）、`configure(0)` 会中断 Android `f_mtp`、`reset()` 会导致 ColorOS 退回「仅充电」。
- ✅ （2026-11-16 决策）针对 `ptpcamerad` 独占，在非沙盒桌面端采用「热插拔抢先打开 + 遇独占错误（`kIOReturnExclusiveAccess` / `kIOReturnInternalError`）自动 `killall ptpcamerad`（仅当前用户进程，无需 `sudo`）并在 5ms 轮询重试接管」，不重置手机 USB 状态且不影响后续系统相机功能。
- ✅ （2026-11-16 macOS 27.2.1 + OnePlus 13T 实机验证）本机若运行 `O+Connect Service` 等厂商跨屏守护进程，会在手机切入 MTP 约 1.9 秒后打开父级 `IOUSBHostDevice` 下发 AOA 切换指令（切至 `0x18d1/2d00` 后退出），导致手机退回「仅充电」；且在我方释放 `IOUSBHostDevice` 后约 1.8 秒内该服务会再次介入劫持。因此打开 `IOUSBHostInterface` 时同步以 `.deviceSeize` 持续锁定父级 `IOUSBHostDevice` 直至设备断开或应用退出，可由内核拦截后续 `IOUSBHostDevice` 打开请求（`-536870203`）从而避免 AOA 抢占。
- ✅ （2026-11-16 实机验证）在锁护 `IOUSBHostDevice` 期间，`OnePlus PKX110` 实机成功完成 `OpenSession`、存储枚举（`65537` 内部共享存储空间 `151.8 GB / 492.2 GB`）、根目录 32 项与 `DCIM` 8 项枚举、`GetPartialObject`（`0x2001` 读取 `.nomedia` 48 字节），以及 `YYYYMMDDThhmmss` 无时区后缀日期格式确认；锁屏或「仅充电」模式下 `GetStorageIDs` 返回 0 个存储（非报错）。待补测 `DCIM/Camera` 图片原生 `GetThumb`、> 4 GB 传输与非法文件名集合。

## 5. 标记约定

- **【决策】**：已确定，直接执行。
- **【待验证】**：未经实机或源码确认，实现前必须验证，验证后回写规格文档。验证前不得当作事实写入代码注释或文档。
- 第 4 节所列为已核实事实；与规格文档冲突时，先更新规格再写代码（见第 8 节）。

## 6. 开发规则

- 不得引入未在规格中列出的第三方依赖；必须引入时先更新规格并说明理由（理由格式：「加 X 是因为 Y，现有依赖都不行」）。
- 非测试代码禁止强制解包；日志用 `os.Logger`，统一 subsystem。
- 每台设备所有 `FileProvider` 调用经该设备的 `DeviceSession` actor 串行；任何调用遇断线抛 `.disconnected`。
- 下载先写 `<name>.droiddock-part`，校验大小后原子重命名；失败或取消必须清理 part 文件。
- 上传前预检文件名，禁止静默失败。
- 拖出到 Finder 用 `NSFilePromiseProvider`，下载不得阻塞主线程。
- 锁屏或 USB 非「文件传输」模式必须映射为 `.locked`，不得表现为「空设备」。
- 单元测试必须覆盖：`TransferQueue` 状态机、文件名预检与冲突重命名、相册分组、缩略图缓存键与淘汰；以 `FakeFileProvider` 隔离设备。
- 设计数值（主色 `#2B5FE0` 等）以规格第 7 节为准，实现优先使用系统语义色与 AccentColor。

## 7. 里程碑

M0 内核验证 → M1 设备层与文件视图 → M2 传输 → M3 相册与缩略图 → M4 打磨与分发。验收标准见规格第 8 节，当前进度见 `READMAP.md`。

## 8. 文档维护规则（强制）

- **每个阶段或子任务完成后，必须及时更新 `READMAP.md`**（做了什么、改了哪些路径、验证结果、遗留问题、下一步）。
- 项目事实、规则、已核实/待验证结论发生变化时，同步更新本文件；规格变化先改 `docs/DroidDock-Dev-Spec.md`，再按新规格实现。
- 不得把未验证的推断写成事实；验证结果标注日期与方式（源码 / 实机 / 官方文档）。
- 更新文档不等于提交：**禁止执行 `git commit`、`git push` 等提交与推送操作**，由用户手动完成。

## 9. 红线（沿用全局规则）

以下操作必须先停下问用户：删除文件/目录或 git 回滚；修改 `.env`、密钥、token、CI/CD 配置；数据库 schema 变更或数据迁移；安装全局依赖或修改系统配置（例如 `brew install libusb`、`killall ptpcamerad` 都属于此类，须先征得同意）；公开发布。密钥不进代码、不进日志。

## 10. Git 与提交信息

- 可直接执行：`status`、`diff`、`log`、`show`、`init`、`add`、`branch --show-current`。
- 提交信息规范（供用户提交时参考）：中文，前缀 `init:`/`feat:`/`fix:`/`refactor:`/`docs:`/`chore:`，描述具体，不加 `Co-Authored-By`。
- `.gitignore` 至少排除依赖、构建产物、`.env*`、系统文件、编辑器配置和 AI 本地配置。
