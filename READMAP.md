# READMAP — DroidDock 开发记录与进度

本文件记录各阶段完成内容，供不同 Agent 了解进度。每个阶段或子任务完成后必须更新（规则见 `AGENTS.md` 第 8 节）。倒序追加到「开发日志」。

## 当前状态

- 当前阶段：**M0 进行中——骨架已搭建，待在 macOS 27 + Android 17 实机编译与验证**
- 代码：`Packages/USBMTP`（Swift Package：`USBMTP` 库 + `mtp-spike` 命令行 + 单元测试）。**全部代码在 Windows 环境编写，尚未编译、尚未运行任何测试**
- 下一步：在 Mac 上执行 `cd Packages/USBMTP && swift build && swift test`，修正 IOUSBHost 相关编译错误；再 `swift run mtp-spike list` / `probe`，把结果（尤其 ptpcamerad 独占、GetThumb/GetPartialObject 支持）记入开发日志并回写规格

## 里程碑进度

| 阶段 | 内容 | 状态 | 验收标准（摘要） |
|---|---|---|---|
| 文档 | 规格与原型设计 | ✅ 已完成（规格 v0.2） | — |
| M0 | IOUSBHost 打开 MTP 接口、OpenSession、列出存储与 `DCIM`，完成全部【待验证】项实测 | ⬜ 未开始 | 实机列出存储与 DCIM；实测记录回写规格 |
| M1 | 设备层与文件视图：热插拔、存储、导航、锁定态 | ⬜ 未开始 | 拔插 UI 正确更新；锁屏有明确提示 |
| M2 | 传输：下载、上传、队列、托盘、拖拽、冲突策略 | ⬜ 未开始 | 1 GB 级混合批量双向成功；取消与断线无残留 `.part` |
| M3 | 相册与缩略图：索引、网格、缓存、预览 | ⬜ 未开始 | 5000 张首屏可交互、滚动流畅、重连增量刷新 |
| M4 | 打磨与分发：错误/空状态、日志、签名公证 | ⬜ 未开始 | 干净 Mac 上可安装运行 |

## 已确定的技术决策（2026-11-16）

- 放弃 Kalam，改为 Swift + Apple IOUSBHost 自研纯 Swift MTP 客户端（`USBMTP` Package）；不使用 libusb/libmtp，规避 LGPL。
- SQLite 用系统 SQLite3 自行封装，不引入 GRDB。
- 支持 macOS 27，最低 macOS 14；仅 USB，Wi-Fi 与无线配对界面后续阶段再做。
- 仍待实测：ptpcamerad 独占与 entitlement、沙盒可行性、`GetThumb`/`GetPartialObject` 各厂商支持、MTP 日期字段、大于 4 GB 传输、非法文件名集合。

## 评审核实记录（2026-11-16，针对已放弃的 Kalam 路线）


方式：读取 OpenMTP 仓库源码（`ffi/kalam/native` 的 `kalam.go`、`helpers.go`、`structs.go`、`go.mod`、`README.md`）、`go-mtpx` 与 `go-mtpfs` 仓库、GitHub release 页面。详细结论见 `AGENTS.md` 第 4 节。

- 与规格一致：Kalam 可编为动态库；OpenMTP 3.3.0 修复 macOS 27 arm64 崩溃（发布于 2026-08-22）；OpenMTP、go-mtpx 为 MIT。
- 与规格不一致或需补充：见 `AGENTS.md` 第 4 节。
- 未核实：`ptpcamerad` 现象仅有二手描述，未实机验证；4 GB 传输仅为官方宣称。
- 设计稿 HTML 为打包页面，未做视觉评审。

## 开发日志`n`n### 2026-11-16 — M0 骨架搭建（未编译）`n- 新增 `Packages/USBMTP`：`MTPCodec.swift`（容器/字符串/DeviceInfo/StorageInfo/ObjectInfo 编解码）、`MTPSession.swift`（actor 串行会话，GetDeviceInfo/OpenSession/GetStorageIDs/GetStorageInfo/GetObjectHandles/GetObjectInfo）、`IOUSBHostTransport.swift`（IORegistry 枚举 + IOUSBHostInterface Bulk 传输）、`Sources/MTPSpike/Spike.swift`（`list`/`probe`）、`Tests/USBMTPTests`（编解码与会话分块拼装）。`.gitignore` 已新增。`n- 验证：无。开发机为 Windows 且无 Swift 工具链，代码未编译。`IOUSBHostTransport.swift` 中 `IOUSBGetNextEndpointDescriptor`、`__sendIORequest` 等调用的精确签名依据记忆编写，极可能需要在 Xcode 中修正。`n- 遗留：未实现数据阶段发送（上传）、大于 4 GB 数据容器、事件端点、热插拔。`n
### 2026-11-16 — 补充约束与设计稿
- 用户补充两张 PNG 设计稿，并新增约束：支持 macOS 27、仅 USB、优先官方技术方案、可能开源须规避版权风险（详见 `AGENTS.md` 1.1）。
- 技术路线确认：放弃 Kalam，改为 Swift + IOUSBHost 自研 MTP。规格更新为 v0.2（范围、选型原则、架构、M0、风险、参考）；`AGENTS.md` 同步。

### 2026-11-16 — 规划与评审
- 阅读 `docs/DroidDock-Dev-Spec.md` 并完成可行性评审，结论：方向可行，Kalam 嵌入方式与能力边界需调整（见上）。
- 对照 OpenMTP 源码核实技术假设，结论写入 `AGENTS.md`。
- 新增 `AGENTS.md`、`READMAP.md`。未改动规格文档、未提交 git。
