import Foundation
import Observation

/// 维护连接设备列表、当前设备状态以及对应 `DeviceSession` 的应用级设备管理器。
@MainActor
@Observable
final class DeviceManager {
    private(set) var devices: [DeviceInfo] = []
    private(set) var selectedDeviceID: DeviceID?
    private(set) var deviceStates: [DeviceID: DeviceState] = [:]

    private let backend: any DeviceBackend
    private var sessions: [DeviceID: DeviceSession] = [:]
    private var eventTask: Task<Void, Never>?
    var onUpdate: (@MainActor () -> Void)?

    init(backend: any DeviceBackend = MTPDeviceBackend()) {
        self.backend = backend
    }

    var currentDevice: DeviceInfo? {
        guard let selectedDeviceID else { return nil }
        return devices.first { $0.id == selectedDeviceID }
    }

    var currentState: DeviceState? {
        guard let selectedDeviceID else { return nil }
        return deviceStates[selectedDeviceID]
    }

    var currentSession: DeviceSession? {
        guard let selectedDeviceID else { return nil }
        return sessions[selectedDeviceID]
    }

    func start() {
        guard eventTask == nil else { return }
        let stream = backend.events()
        eventTask = Task { [weak self] in
            guard let self else { return }
            for await event in stream {
                guard !Task.isCancelled else { break }
                await handle(event)
            }
        }
    }

    func stop() {
        eventTask?.cancel()
        eventTask = nil
    }

    func refresh() async {
        await backend.refresh()
    }

    func selectDevice(_ id: DeviceID) {
        guard devices.contains(where: { $0.id == id }) else { return }
        selectedDeviceID = id
        onUpdate?()
    }

    func markDisconnected(_ id: DeviceID) {
        sessions[id] = nil
        if deviceStates[id] != nil {
            deviceStates[id] = .error(.disconnected)
        }
        onUpdate?()
        Task {
            await backend.invalidateAndReconnect(id)
        }
    }

    private func handle(_ event: DeviceEvent) async {
        switch event {
        case .attached(let info):
            if let index = devices.firstIndex(where: { $0.id == info.id }) {
                devices[index] = info
            } else {
                devices.append(info)
            }
            if deviceStates[info.id] == nil {
                deviceStates[info.id] = .detected
            }
            if selectedDeviceID == nil {
                selectedDeviceID = info.id
            }

        case .detached(let id):
            devices.removeAll { $0.id == id }
            deviceStates[id] = nil
            sessions[id] = nil
            if selectedDeviceID == id {
                selectedDeviceID = devices.first?.id
            }

        case .stateChanged(let id, let state):
            deviceStates[id] = state
            if state == .ready {
                do {
                    let provider = try await backend.open(id)
                    if devices.contains(where: { $0.id == id }) {
                        sessions[id] = DeviceSession(provider: provider)
                    }
                } catch let error as DeviceError {
                    deviceStates[id] = .error(error)
                } catch {
                    deviceStates[id] = .error(.underlying(error.localizedDescription))
                }
            } else {
                sessions[id] = nil
            }
        }
        onUpdate?()
    }
}

/// 组合多个设备后端（USB MTP + 局域网无线 ADB），统一合并事件流并路由到所属后端。
final class CompositeDeviceBackend: DeviceBackend, @unchecked Sendable {
    private let backends: [any DeviceBackend]
    private let lock = NSLock()
    private var ownerByDeviceID: [String: Int] = [:]

    init(backends: [any DeviceBackend]) {
        self.backends = backends
    }

    func events() -> AsyncStream<DeviceEvent> {
        let indexedStreams = backends.enumerated().map { ($0.offset, $0.element.events()) }
        return AsyncStream { continuation in
            let tasks = indexedStreams.map { index, stream in
                Task { [weak self] in
                    for await event in stream {
                        if case .attached(let info) = event {
                            self?.lock.withLock {
                                self?.ownerByDeviceID[info.id.rawValue] = index
                            }
                        } else if case .detached(let id) = event {
                            _ = self?.lock.withLock {
                                self?.ownerByDeviceID.removeValue(forKey: id.rawValue)
                            }
                        }
                        continuation.yield(event)
                    }
                }
            }
            continuation.onTermination = { _ in
                for task in tasks {
                    task.cancel()
                }
            }
        }
    }

    func open(_ id: DeviceID) async throws -> any FileProvider {
        if let index = lock.withLock({ ownerByDeviceID[id.rawValue] }), backends.indices.contains(index) {
            return try await backends[index].open(id)
        }
        for backend in backends {
            if let provider = try? await backend.open(id) {
                return provider
            }
        }
        throw DeviceError.disconnected
    }

    func refresh() async {
        for backend in backends {
            await backend.refresh()
        }
    }

    func invalidateAndReconnect(_ id: DeviceID) async {
        if let index = lock.withLock({ ownerByDeviceID[id.rawValue] }), backends.indices.contains(index) {
            await backends[index].invalidateAndReconnect(id)
            return
        }
        for backend in backends {
            await backend.invalidateAndReconnect(id)
        }
    }
}
