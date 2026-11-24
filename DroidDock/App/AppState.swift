import Foundation
import Observation

/// 应用级状态装配：协调 USB/Wi-Fi 双模 `DeviceManager`、`BrowserModel`、`TransferModel`、`ADBDiscoveryService` 与界面主题配色。
@MainActor
@Observable
final class AppState {
    private static let paletteDefaultsKey = "droiddock.selectedPalette"

    let adbClient: ADBClient
    let adbDiscovery: ADBDiscoveryService
    let quickDropServer: QuickDropWebServer
    let deviceManager: DeviceManager
    let browser: BrowserModel
    let transferModel: TransferModel
    let updateService: AppUpdateService
    var showWirelessPairingSheet = false
    var showUpdateSheet = false
    private(set) var currentDeviceStatus: DeviceStatusInfo?
    private(set) var isRefreshingDeviceStatus = false
    var palette: ElegantPalette {
        didSet {
            UserDefaults.standard.set(palette.rawValue, forKey: Self.paletteDefaultsKey)
        }
    }

    private var lastLoadedDeviceID: DeviceID?
    private var lastLoadedState: DeviceState?
    private var statusPollingTask: Task<Void, Never>?
    private var launchUpdateTask: Task<Void, Never>?

    convenience init() {
        let client = ADBClient()
        let discovery = ADBDiscoveryService(adbClient: client)
        let backend = CompositeDeviceBackend(backends: [
            MTPDeviceBackend(),
            ADBDeviceBackend(client: client, discovery: discovery),
        ])
        self.init(
            deviceManager: DeviceManager(backend: backend),
            browser: BrowserModel(),
            transferModel: TransferModel(),
            adbClient: client,
            adbDiscovery: discovery,
            quickDropServer: QuickDropWebServer(),
            updateService: AppUpdateService()
        )
    }

    init(
        deviceManager: DeviceManager,
        browser: BrowserModel = BrowserModel(),
        transferModel: TransferModel = TransferModel(),
        adbClient: ADBClient = ADBClient(),
        adbDiscovery: ADBDiscoveryService? = nil,
        quickDropServer: QuickDropWebServer? = nil,
        updateService: AppUpdateService? = nil
    ) {
        self.adbClient = adbClient
        let resolvedDiscovery = adbDiscovery ?? ADBDiscoveryService(adbClient: adbClient)
        self.adbDiscovery = resolvedDiscovery
        self.quickDropServer = quickDropServer ?? QuickDropWebServer()
        self.deviceManager = deviceManager
        self.browser = browser
        self.transferModel = transferModel
        self.updateService = updateService ?? AppUpdateService()
        if let saved = UserDefaults.standard.string(forKey: Self.paletteDefaultsKey),
           let parsed = ElegantPalette(rawValue: saved) {
            self.palette = parsed
        } else {
            self.palette = .songIndigo
        }
        resolvedDiscovery.configureOnConnected { [weak deviceManager] in
            Task { await deviceManager?.refresh() }
        }
        browser.configureDisconnectHandler { [weak deviceManager] id in
            deviceManager?.markDisconnected(id)
        }
        transferModel.configureCallbacks(
            onUploadCompleted: { [weak browser] in
                Task { await browser?.reload() }
            },
            onDisconnectDetected: { [weak deviceManager] id in
                deviceManager?.markDisconnected(id)
            },
            onTransferActivityChanged: { [weak browser] isActive in
                Task { await browser?.setTransferPrioritized(isActive) }
            }
        )
        deviceManager.onUpdate = { [weak self] in
            guard let self else { return }
            Task { await self.syncWithCurrentDeviceIfNeeded() }
        }
    }

    var effectiveDeviceState: DeviceState? {
        if deviceManager.currentDevice != nil && browser.isDeviceLocked {
            return .locked
        }
        return deviceManager.currentState
    }

    func start() {
        deviceManager.start()
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else {
            return
        }
        guard launchUpdateTask == nil else { return }
        launchUpdateTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled, let self else { return }
            await self.updateService.checkForUpdatesOnLaunchIfNeeded()
        }
    }

    func stop() {
        launchUpdateTask?.cancel()
        launchUpdateTask = nil
        stopStatusPolling()
        deviceManager.stop()
    }

    func refreshDeviceStatus(force: Bool = false) async {
        guard force || (transferModel.activeCount == 0 && !transferModel.isPreparing) else {
            return
        }
        guard deviceManager.currentState == .ready,
              let devID = deviceManager.selectedDeviceID,
              let session = deviceManager.currentSession else {
            currentDeviceStatus = nil
            return
        }
        guard !isRefreshingDeviceStatus else { return }
        isRefreshingDeviceStatus = true
        defer { isRefreshingDeviceStatus = false }

        if let status = try? await session.deviceStatus(),
           deviceManager.selectedDeviceID == devID,
           deviceManager.currentState == .ready {
            currentDeviceStatus = status
        }
    }

    func refreshDevices() async {
        await deviceManager.refresh()
        await syncWithCurrentDeviceIfNeeded(forceReload: true)
    }

    func selectDevice(_ id: DeviceID) async {
        deviceManager.selectDevice(id)
        await syncWithCurrentDeviceIfNeeded(forceReload: true)
    }

    func syncWithCurrentDeviceIfNeeded(forceReload: Bool = false) async {
        let deviceID = deviceManager.selectedDeviceID
        let state = deviceManager.currentState
        let session = deviceManager.currentSession

        if !forceReload && deviceID == lastLoadedDeviceID && state == lastLoadedState {
            return
        }
        lastLoadedDeviceID = deviceID
        lastLoadedState = state

        guard let deviceID else {
            stopStatusPolling()
            currentDeviceStatus = nil
            browser.resetForDisconnectedOrLocked(locked: false)
            await transferModel.attachSession(nil, deviceID: nil)
            return
        }

        switch state {
        case .ready:
            if let session {
                await transferModel.attachSession(session, deviceID: deviceID)
                await browser.attachSession(session, deviceID: deviceID)
                startStatusPollingIfNeeded()
                await refreshDeviceStatus(force: true)
            }
        case .locked:
            stopStatusPolling()
            currentDeviceStatus = nil
            await transferModel.attachSession(nil, deviceID: nil)
            browser.resetForDisconnectedOrLocked(locked: true)
        case .error(let err):
            stopStatusPolling()
            currentDeviceStatus = nil
            await transferModel.attachSession(nil, deviceID: nil)
            browser.resetForDisconnectedOrLocked(locked: false)
            browser.errorMessage = err.localizedDescription
        case .detected, .busy, .none:
            stopStatusPolling()
            currentDeviceStatus = nil
            await transferModel.attachSession(nil, deviceID: nil)
            browser.resetForDisconnectedOrLocked(locked: false)
        }
    }

    private func startStatusPollingIfNeeded() {
        guard statusPollingTask == nil else { return }
        statusPollingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                guard !Task.isCancelled, let self else { return }
                await self.refreshDeviceStatus(force: false)
            }
        }
    }

    private func stopStatusPolling() {
        statusPollingTask?.cancel()
        statusPollingTask = nil
    }
}
