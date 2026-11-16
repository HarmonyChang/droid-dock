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
        guard let c = USBEnumerator.candidates().first(where: \.looksLikeMTP) else {
            print("未发现 MTP 接口：请解锁手机并将 USB 用途设为「文件传输」"); return
        }
        print("目标：\(c.deviceName) (\(c.serial))")
        do {
            let session = MTPSession(transport: try IOUSBHostTransport(candidate: c))
            print("✅ 接口已打开")
            let info = try await session.deviceInfo()
            print("设备：\(info.manufacturer) \(info.model) \(info.deviceVersion)")
            print("GetThumb 支持：\(info.supportsGetThumb)；GetPartialObject 支持：\(info.supportsGetPartialObject)")
            try await session.openSession()
            let storages = try await session.storages()
            for s in storages { print("存储 \(s.id)：\(s.description) 已用 \(s.maxCapacity - s.freeSpace) / \(s.maxCapacity) 字节") }
            guard let first = storages.first else { print("无存储（手机可能未解锁）"); return }
            let root = try await session.list(storage: first.id)
            print("根目录 \(root.count) 项：\(root.map(\.filename).joined(separator: ", "))")
            if let dcim = root.first(where: { $0.filename == "DCIM" }) {
                let items = try await session.list(storage: first.id, parent: dcim.handle)
                print("DCIM 下 \(items.count) 项：\(items.prefix(10).map(\.filename).joined(separator: ", "))")
            }
            try await session.closeSession()
        } catch {
            print("❌ 失败：\(error)")
            print("请完整记录此错误（尤其 kIOReturnExclusiveAccess / 权限类），回写 READMAP.md")
        }
    }
}
