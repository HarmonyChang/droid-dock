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
    var showWirelessPairingSheet = false
    var palette: ElegantPalette {
        didSet {
            UserDefaults.standard.set(palette.rawValue, forKey: Self.paletteDefaultsKey)
        }
    }

    private var lastLoadedDeviceID: DeviceID?
    private var lastLoadedState: DeviceState?

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
            quickDropServer: QuickDropWebServer()
        )
    }

    init(
        deviceManager: DeviceManager,
        browser: BrowserModel = BrowserModel(),
        transferModel: TransferModel = TransferModel(),
        adbClient: ADBClient = ADBClient(),
        adbDiscovery: ADBDiscoveryService? = nil,
        quickDropServer: QuickDropWebServer? = nil
    ) {
        self.adbClient = adbClient
        let resolvedDiscovery = adbDiscovery ?? ADBDiscoveryService(adbClient: adbClient)
        self.adbDiscovery = resolvedDiscovery
        self.quickDropServer = quickDropServer ?? QuickDropWebServer()
        self.deviceManager = deviceManager
        self.browser = browser
        self.transferModel = transferModel
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
    }

    func stop() {
        deviceManager.stop()
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
            browser.resetForDisconnectedOrLocked(locked: false)
            await transferModel.attachSession(nil, deviceID: nil)
            return
        }

        switch state {
        case .ready:
            if let session {
                await transferModel.attachSession(session, deviceID: deviceID)
                await browser.attachSession(session, deviceID: deviceID)
            }
        case .locked:
            await transferModel.attachSession(nil, deviceID: nil)
            browser.resetForDisconnectedOrLocked(locked: true)
        case .error(let err):
            await transferModel.attachSession(nil, deviceID: nil)
            browser.resetForDisconnectedOrLocked(locked: false)
            browser.errorMessage = err.localizedDescription
        case .detected, .busy, .none:
            await transferModel.attachSession(nil, deviceID: nil)
            browser.resetForDisconnectedOrLocked(locked: false)
        }
    }
}
