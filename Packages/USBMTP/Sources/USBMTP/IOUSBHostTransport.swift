import Foundation
import IOKit
import IOKit.usb
import IOUSBHost

/// 一个可能的 MTP USB 接口（来自 IORegistry）。持有 io_service_t，析构时释放。
public final class USBInterfaceCandidate: @unchecked Sendable {
    public let service: io_service_t
    public let deviceName: String
    public let vendorID: Int
    public let productID: Int
    public let serial: String
    public let locationID: Int
    public let interfaceNumber: Int
    public let interfaceClass: Int
    public let interfaceSubClass: Int
    public let interfaceProtocol: Int
    public let interfaceName: String

    /// PTP/MTP 标准接口为 class 6 / subclass 1 / protocol 1；部分设备用厂商类并以接口名 "MTP" 标识。
    public var looksLikeMTP: Bool {
        (interfaceClass == 6 && interfaceSubClass == 1) || interfaceName.uppercased().contains("MTP")
    }

    init(service: io_service_t, deviceName: String, vendorID: Int, productID: Int, serial: String, locationID: Int,
         interfaceNumber: Int, interfaceClass: Int, interfaceSubClass: Int, interfaceProtocol: Int, interfaceName: String) {
        self.service = service
        self.deviceName = deviceName
        self.vendorID = vendorID
        self.productID = productID
        self.serial = serial
        self.locationID = locationID
        self.interfaceNumber = interfaceNumber
        self.interfaceClass = interfaceClass
        self.interfaceSubClass = interfaceSubClass
        self.interfaceProtocol = interfaceProtocol
        self.interfaceName = interfaceName
    }

    deinit { IOObjectRelease(service) }
}

public enum USBEnumerator {
    private static func prop(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    /// 枚举所有 USB 接口；调用方用 `looksLikeMTP` 过滤。
    public static func candidates() -> [USBInterfaceCandidate] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostInterface"), &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }

        var result: [USBInterfaceCandidate] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            var parent: io_registry_entry_t = 0
            var name = "", serial = ""
            var vid = 0, pid = 0
            var locationID = (prop(service, "locationID") as? Int) ?? 0
            if IORegistryEntryGetParentEntry(service, kIOServicePlane, &parent) == KERN_SUCCESS {
                name = (prop(parent, "USB Product Name") as? String) ?? (prop(parent, "kUSBProductString") as? String) ?? ""
                if name.isEmpty {
                    var nameBuf = [CChar](repeating: 0, count: 128)
                    if IORegistryEntryGetName(parent, &nameBuf) == KERN_SUCCESS {
                        let raw = String(decoding: nameBuf.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
                        name = raw.split(separator: "@", maxSplits: 1).first.map(String.init) ?? raw
                    }
                }
                serial = (prop(parent, "USB Serial Number") as? String) ?? (prop(parent, "kUSBSerialNumberString") as? String) ?? ""
                vid = (prop(parent, "idVendor") as? Int) ?? 0
                pid = (prop(parent, "idProduct") as? Int) ?? 0
                if locationID == 0 {
                    locationID = (prop(parent, "locationID") as? Int) ?? 0
                }
                IOObjectRelease(parent)
            }
            result.append(USBInterfaceCandidate(
                service: service, deviceName: name, vendorID: vid, productID: pid, serial: serial, locationID: locationID,
                interfaceNumber: (prop(service, "bInterfaceNumber") as? Int) ?? -1,
                interfaceClass: (prop(service, "bInterfaceClass") as? Int) ?? -1,
                interfaceSubClass: (prop(service, "bInterfaceSubClass") as? Int) ?? -1,
                interfaceProtocol: (prop(service, "bInterfaceProtocol") as? Int) ?? -1,
                interfaceName: (prop(service, "USB Interface Name") as? String) ?? (prop(service, "kUSBString") as? String) ?? ""))
        }
        return result
    }
}

/// 监听 IOKit `IOUSBHostInterface` 匹配与移除事件，用于触发热插拔重枚举。
public final class USBHotplugMonitor: @unchecked Sendable {
    private final class State: @unchecked Sendable {
        let queue = DispatchQueue(label: "droiddock.usbmtp.hotplug")
        var port: IONotificationPortRef?
        var matchedIter: io_iterator_t = 0
        var terminatedIter: io_iterator_t = 0
        var continuation: AsyncStream<Void>.Continuation?
        var retainedSelf: Unmanaged<State>?
        var isStopped = false

        func stop() {
            queue.async {
                guard !self.isStopped else { return }
                self.isStopped = true
                if self.matchedIter != 0 {
                    IOObjectRelease(self.matchedIter)
                    self.matchedIter = 0
                }
                if self.terminatedIter != 0 {
                    IOObjectRelease(self.terminatedIter)
                    self.terminatedIter = 0
                }
                if let port = self.port {
                    IONotificationPortDestroy(port)
                    self.port = nil
                }
                self.continuation = nil
                self.retainedSelf?.release()
                self.retainedSelf = nil
            }
        }
    }

    public static func events() -> AsyncStream<Void> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let state = State()
            state.continuation = continuation
            let retained = Unmanaged.passRetained(state)
            let refcon = retained.toOpaque()
            state.retainedSelf = retained

            let callback: IOServiceMatchingCallback = { refcon, iterator in
                while case let service = IOIteratorNext(iterator), service != 0 {
                    IOObjectRelease(service)
                }
                guard let refcon else { return }
                let monitorState = Unmanaged<State>.fromOpaque(refcon).takeUnretainedValue()
                guard !monitorState.isStopped else { return }
                monitorState.continuation?.yield(())
            }

            state.queue.sync {
                guard let port = IONotificationPortCreate(kIOMainPortDefault) else {
                    continuation.finish()
                    state.stop()
                    return
                }
                state.port = port
                IONotificationPortSetDispatchQueue(port, state.queue)

                if let matchDict = IOServiceMatching("IOUSBHostInterface") {
                    var iter: io_iterator_t = 0
                    if IOServiceAddMatchingNotification(port, kIOFirstMatchNotification, matchDict, callback, refcon, &iter) == KERN_SUCCESS {
                        state.matchedIter = iter
                        while case let s = IOIteratorNext(iter), s != 0 { IOObjectRelease(s) }
                    }
                }
                if let termDict = IOServiceMatching("IOUSBHostInterface") {
                    var iter: io_iterator_t = 0
                    if IOServiceAddMatchingNotification(port, kIOTerminatedNotification, termDict, callback, refcon, &iter) == KERN_SUCCESS {
                        state.terminatedIter = iter
                        while case let s = IOIteratorNext(iter), s != 0 { IOObjectRelease(s) }
                    }
                }
            }

            continuation.onTermination = { _ in
                state.stop()
            }
        }
    }
}

/// 基于 IOUSBHostInterface 的 Bulk 传输。所有 IO 在专用串行队列执行；同步 API 包成 async。
public final class IOUSBHostTransport: MTPTransport, @unchecked Sendable {
    private let queue = DispatchQueue(label: "droiddock.usbmtp.io")
    private let device: IOUSBHostDevice?
    private let interface: IOUSBHostInterface
    private let bulkIn: IOUSBHostPipe
    private let bulkOut: IOUSBHostPipe
    private let timeout: TimeInterval = 10

    /// 打开接口并定位 Bulk 端点；同时尝试锁定父级 `IOUSBHostDevice`，防止第三方守护进程（如 `O+Connect Service`）
    /// 下发 AOA 模式切换导致设备回落仅充电；若接口被 `ptpcamerad` 独占则自动结束该用户态进程后重试接管。
    public init(candidate: USBInterfaceCandidate) throws {
        let iface = try Self.openInterface(candidate: candidate)
        var inAddr: Int?, outAddr: Int?
        let config = iface.configurationDescriptor
        let ifDesc = iface.interfaceDescriptor
        var current: UnsafePointer<IOUSBDescriptorHeader>? = nil
        while let next = IOUSBGetNextEndpointDescriptor(config, ifDesc, current) {
            let ep = next.pointee
            let isBulk = (ep.bmAttributes & 0x03) == 0x02
            if isBulk {
                if ep.bEndpointAddress & 0x80 != 0 { inAddr = inAddr ?? Int(ep.bEndpointAddress) }
                else { outAddr = outAddr ?? Int(ep.bEndpointAddress) }
            }
            current = UnsafeRawPointer(next).assumingMemoryBound(to: IOUSBDescriptorHeader.self)
        }
        guard let i = inAddr, let o = outAddr else {
            iface.destroy()
            throw MTPError.transport("未找到 Bulk IN/OUT 端点")
        }
        do {
            bulkIn = try iface.copyPipe(withAddress: i)
            bulkOut = try iface.copyPipe(withAddress: o)
        } catch {
            iface.destroy()
            throw error
        }
        interface = iface
        var parent: io_registry_entry_t = 0
        if IORegistryEntryGetParentEntry(iface.ioService, kIOServicePlane, &parent) == KERN_SUCCESS {
            defer { IOObjectRelease(parent) }
            device = try? IOUSBHostDevice(__ioService: parent, options: [.deviceSeize], queue: nil, interestHandler: nil)
        } else {
            device = nil
        }
    }

    deinit {
        interface.destroy()
        device?.destroy()
    }

    private static func openInterface(candidate: USBInterfaceCandidate) throws -> IOUSBHostInterface {
        do {
            return try IOUSBHostInterface(__ioService: candidate.service, options: [], queue: nil, interestHandler: nil)
        } catch let err as NSError where isInterfaceBusyError(err) {
            terminatePTPCameraDaemon()
            for _ in 0..<100 {
                Thread.sleep(forTimeInterval: 0.005)
                if let refreshed = USBEnumerator.candidates().first(where: {
                    $0.vendorID == candidate.vendorID &&
                    $0.productID == candidate.productID &&
                    $0.serial == candidate.serial &&
                    $0.interfaceNumber == candidate.interfaceNumber
                }), let iface = try? IOUSBHostInterface(__ioService: refreshed.service, options: [], queue: nil, interestHandler: nil) {
                    return iface
                }
                if let iface = try? IOUSBHostInterface(__ioService: candidate.service, options: [], queue: nil, interestHandler: nil) {
                    return iface
                }
            }
            throw err
        }
    }

    private static func isInterfaceBusyError(_ error: NSError) -> Bool {
        guard error.domain == IOUSBHostErrorDomain else { return false }
        let code = Int32(truncatingIfNeeded: error.code)
        // ptpcamerad 持有 UsbExclusiveOwner 时实测返回 kIOReturnInternalError (-536870199)
        return code == kIOReturnExclusiveAccess || code == kIOReturnInternalError
    }

    private static func terminatePTPCameraDaemon() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        process.arguments = ["-9", "ptpcamerad"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }

    public func send(_ data: Data) async throws {
        try await onQueue {
            let buf = NSMutableData(data: data)
            var sent = 0
            try self.bulkOut.__sendIORequest(with: buf, bytesTransferred: &sent, completionTimeout: self.timeout)
        }
    }

    public func receive(maxLength: Int) async throws -> Data {
        try await onQueue {
            let buf = NSMutableData(length: maxLength) ?? NSMutableData()
            var got = 0
            try self.bulkIn.__sendIORequest(with: buf, bytesTransferred: &got, completionTimeout: self.timeout)
            return Data(bytes: buf.bytes, count: got)
        }
    }

    private func onQueue<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                do { cont.resume(returning: try work()) } catch { cont.resume(throwing: error) }
            }
        }
    }
}
