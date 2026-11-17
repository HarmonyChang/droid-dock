import Foundation
import USBMTP

/// M0 spike：`mtp-spike list` 列出 USB 接口；`mtp-spike probe` 打开第一个疑似 MTP 接口并读取设备/存储/根目录/DCIM。
@main
struct MTPSpike {
    static func main() async {
        let cmd = CommandLine.arguments.dropFirst().first ?? "probe"
        switch cmd {
        case "list": list()
        case "probe": await probe()
        default: print("用法：mtp-spike [list|probe]")
        }
    }

    static func list() {
        let all = USBEnumerator.candidates()
        for c in all where c.looksLikeMTP || c.interfaceClass == 255 {
            print(String(format: "%@ vid=%04x pid=%04x serial=%@ if#%d class=%d/%d/%d name=%@ mtp?=%@",
                         c.deviceName, c.vendorID, c.productID, c.serial, c.interfaceNumber,
                         c.interfaceClass, c.interfaceSubClass, c.interfaceProtocol, c.interfaceName,
                         c.looksLikeMTP ? "yes" : "no"))
        }
        print("共 \(all.count) 个 USB 接口，其中疑似 MTP \(all.filter(\.looksLikeMTP).count) 个")
    }

    static func probe() async {
        print("等待 MTP 设备连接并开放存储（最长 120 秒）...")
        fflush(stdout)
        let deadline = Date().addingTimeInterval(120)
        var session: MTPSession?
        var printedDevice = false
        var waitingPromptPrinted = false

        while Date() < deadline {
            if session == nil {
                guard let c = USBEnumerator.candidates().first(where: \.looksLikeMTP) else {
                    try? await Task.sleep(nanoseconds: 10_000_000)
                    continue
                }
                do {
                    let transport = try IOUSBHostTransport(candidate: c)
                    let s = MTPSession(transport: transport)
                    if !printedDevice {
                        print("目标：\(c.deviceName) (\(c.serial))")
                        print("✅ 接口已打开")
                        let info = try await s.deviceInfo()
                        print("设备：\(info.manufacturer) \(info.model) \(info.deviceVersion)")
                        print("GetThumb 支持：\(info.supportsGetThumb)；GetPartialObject 支持：\(info.supportsGetPartialObject)")
                        fflush(stdout)
                        printedDevice = true
                    }
                    try await s.openSession()
                    session = s
                } catch {
                    session = nil
                    try? await Task.sleep(nanoseconds: 10_000_000)
                    continue
                }
            }

            guard let activeSession = session else { continue }
            do {
                let storages = try await activeSession.storages()
                guard let first = storages.first else {
                    if !waitingPromptPrinted {
                        print("无存储（手机可能未解锁或处于仅充电模式），请在手机上解锁并点击「传输文件」，将持续监听最长 120 秒...")
                        fflush(stdout)
                        waitingPromptPrinted = true
                    }
                    try await Task.sleep(nanoseconds: 500_000_000)
                    continue
                }

                for s in storages {
                    print("存储 \(s.id)：\(s.description) 已用 \(s.maxCapacity - s.freeSpace) / \(s.maxCapacity) 字节")
                }
                let root = try await activeSession.list(storage: first.id)
                print("根目录 \(root.count) 项：\(root.map(\.filename).joined(separator: ", "))")
                if let dcim = root.first(where: { $0.filename == "DCIM" }) {
                    let items = try await activeSession.list(storage: first.id, parent: dcim.handle)
                    print("DCIM 下 \(items.count) 项：\(items.prefix(10).map(\.filename).joined(separator: ", "))")
                    let subDirs = items
                        .filter { $0.isDirectory && !$0.filename.hasPrefix(".") }
                        .sorted { ($0.filename == "Camera" ? 0 : 1) < ($1.filename == "Camera" ? 0 : 1) }
                    for sub in subDirs {
                        let handlesRes = try await activeSession.execute(MTPOperation.getObjectHandles, params: [first.id, 0, sub.handle])
                        guard handlesRes.responseCode == MTPResponseCode.ok else { continue }
                        var reader = ByteReader(handlesRes.data)
                        let handles = try reader.u32Array()
                        print("DCIM/\(sub.filename) 下共 \(handles.count) 项")
                        var sample: MTPObjectInfo?
                        for h in handles.prefix(10) {
                            let infoRes = try await activeSession.execute(MTPOperation.getObjectInfo, params: [h])
                            guard infoRes.responseCode == MTPResponseCode.ok else { continue }
                            let item = try MTPObjectInfo.parse(infoRes.data, handle: h)
                            print("  - \(item.filename) size=\(item.compressedSize) thumbFmt=\(String(format: "0x%04x", item.thumbFormat)) created='\(item.dateCreated)' modified='\(item.dateModified)'")
                            let lower = item.filename.lowercased()
                            if sample == nil && !item.isDirectory && (lower.hasSuffix(".jpg") || lower.hasSuffix(".jpeg") || lower.hasSuffix(".heic") || lower.hasSuffix(".png")) {
                                sample = item
                            }
                        }
                        if let sample {
                            let thumb = try await activeSession.execute(MTPOperation.getThumb, params: [sample.handle])
                            print("GetThumb(\(sample.filename))：code=\(String(format: "0x%04x", thumb.responseCode)) bytes=\(thumb.data.count)")
                            let partial = try await activeSession.execute(MTPOperation.getPartialObject, params: [sample.handle, 0, 65536])
                            print("GetPartialObject(\(sample.filename), 0, 64KB)：code=\(String(format: "0x%04x", partial.responseCode)) bytes=\(partial.data.count)")
                            break
                        }
                    }
                }
                fflush(stdout)
                try? await activeSession.closeSession()
                return
            } catch {
                print("连接已断开或模式切换（\(error.localizedDescription)），正在 10ms 级重连抢占...")
                fflush(stdout)
                session = nil
                printedDevice = false
                waitingPromptPrinted = false
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        if let activeSession = session {
            try? await activeSession.closeSession()
        }
        print("❌ 等待超时（120 秒），仍未检测到可用存储")
        fflush(stdout)
    }
}
