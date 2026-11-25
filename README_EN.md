<div align="center">

# DroidDock

**Native macOS Android File & Photo Manager -- Pure Swift, Zero Companion App Required**

![Platform](https://img.shields.io/badge/macOS-14.0%2B%20(Apple%20Silicon)-1D2228?style=flat-square)
![Swift](https://img.shields.io/badge/Swift-6.0-355C7D?style=flat-square)
![Version](https://img.shields.io/badge/Release-v0.2.0-2B7A58?style=flat-square)
![Dependencies](https://img.shields.io/badge/Dependencies-Zero%20Third--Party-4A6B53?style=flat-square)

[简体中文](./README.md) | **English**

</div>

---

DroidDock is a native macOS utility built for Apple Silicon Macs (`Swift 6` + `SwiftUI` + `AppKit`) to browse photos and manage bidirectional file transfers with Android devices. Rather than wrapping `libmtp` / `libusb` (which carry GPL/LGPL obligations), DroidDock implements its own clean-room USB MTP stack directly on top of Apple's `IOUSBHost` framework and the public USB-IF MTP specification, alongside dual-mode local Wi-Fi transfer and management.

---

## Key Features

### 1. Pure-Swift USB MTP Client (Zero Phone App Install)
- **In-house `USBMTP` Package**: Built directly on `IOUSBHost` (`USBInterfaceCandidate`, `IOUSBHostTransport`, `MTPCodec`, `MTPSession`) with zero third-party runtime dependencies or copyleft linking risks.
- **macOS Interface Takeover & AOA Protection**: Automatically claims MTP interfaces held exclusively by `ptpcamerad` and acquires `.deviceSeize` on the parent `IOUSBHostDevice` to prevent OEM cross-screen daemons from hijacking the session into AOA/charge-only mode mid-transfer.
- **USB 2.0 Packet Boundary ZLP & Reconnect Recovery**: Sends true Zero-Length Packets (ZLP) on exact Bulk-OUT `wMaxPacketSize` (`512` B) container boundaries so `MtpFfsHandle::receiveFile` on Android never stalls on boundary-aligned files; separates transient timeouts/busy stalls from permanent disconnects and automatically resets stale handles via `invalidateAndReconnect`.
- **Lock & Charge-Only Awareness**: Explicitly surfaces locked / charge-only USB modes as `.locked` instead of showing an empty storage root, and automatically transitions to `.ready` once unlocked.

### 2. High-Scale Batch Transfer Engine (40 GB / 150k+ Files Ready)
- **Streaming Scanner & O(1) Queue Scheduling**: Background `AsyncStream` scans large folder trees in 500-item batches so uploads start immediately without freezing the UI. Queue scheduling, progress accounting, and 10 Hz throttled UI snapshots use O(1) dictionary/cursor lookups and a 300-item display window to avoid O(N^2) stalls.
- **Remote Directory & Existence Cache**: Caches created directories and directory listings (`ensuredDirectories` & `cachedRemoteDirectories`) across consecutive sibling uploads, and defers `browser.reload()` until the whole batch completes.
- **Atomic Downloads, Conflict Policies & Finder Drag-and-Drop**: Downloads stream into `<name>.droiddock-part` and replace atomically on completion (cleaned up on cancel/failure); supports **Rename**, **Overwrite**, and **Skip** strategies, plus drag-in upload and `NSFilePromiseProvider` drag-out directly to Finder.
- **App Nap Suppression & Bandwidth Prioritization**: Holds `ProcessInfo` user-initiated / idle-sleep prevention assertions and pauses background grid thumbnail USB fetches while active transfers run.

### 3. Media Gallery, Fast Thumbnails & HD Photo Lightbox
- **SQLite3 Media Index**: Incremental local indexing built directly on system `SQLite3` C APIs to organize Photos, Videos, and Screenshots.
- **LIFO Viewport Priority & Partial EXIF Extraction**: Prioritizes currently visible grid cells (LIFO), reads the first `128 KB` via `GetPartialObject` to extract embedded EXIF thumbnails when `GetThumb` is unavailable, and caches decoded bitmaps off the main thread.
- **HD Preview & EXIF Overlay Card**: Double-clicking a photo pauses background thumbnails, loads and pre-decodes the full image with EXIF orientation correction, provides keyboard stepping (`←` / `→`) with 250 ms silent neighbor prefetch, Quick Look (`Space`), and a frosted top-right metadata card (dimensions, camera/lens, focal length, aperture, shutter, ISO, timestamp, color profile, GPS, and path).

### 4. Dual-Mode Local Wi-Fi Connectivity
- **QR Quick Drop Web Server (Zero Mobile App Required)**: Embedded `QuickDropWebServer` lets any Android device scan a QR code with its stock camera to exchange files, photos, or entire folders (streamed as ZIP archives) over the local Wi-Fi without cutting off internet access.
- **Wireless ADB Full File Management**: Uses Apple `Network.framework` (`_adb-tls-pairing._tcp.` and `_adb-tls-connect._tcp.`) for QR/code pairing and auto-reconnect over Wi-Fi, with one-click setup for Google's official Android `platform-tools` when `adb` is not already installed.

### 5. Phone Telemetry Card, Themes & Built-in Auto-Updater
- **Sidebar Status Pills & Details Popover**: Displays battery level/charging state and phone network or USB link speed pills right under the sidebar device card; clicking opens a details popover showing battery temperature, Wi-Fi SSID, `5G` / `4G` / `3G` status, LAN IPv4 (click to copy), OS/firmware version, USB link speed, storage usage, and copyable serial number. Polling pauses automatically while transfers are active.
  > Note on protocol capabilities: Pure USB MTP can only report battery level (if exposed by the device via property `0x5001`) and IORegistry USB speed, not cellular/Wi-Fi state; connecting via **Wireless ADB** unlocks full battery temperature, Wi-Fi/cellular status, SSID, and IPv4 telemetry.
- **Four Curated Light Palettes**: Bamboo Paper, Song Indigo (default), Pine Tea, and Morning Mist.
- **Version History & GitHub Releases Auto-Updater**: Zero-dependency updater checks `HarmonyChang/droid-dock` GitHub Releases (auto-check on launch with 6-hour cooldown or manual check), streams `.dmg` / `.zip` updates with `CryptoKit` SHA-256 and `codesign --verify --deep --strict` verification, blocks installs while file transfers are active, backs up the existing `.app`, clears `com.apple.quarantine`, and relaunches automatically with rollback protection.
- **Diagnostics Export**: Exports device state, storage summary, failed transfer items, and recent in-process `OSLog` entries to a text report.

---

## UI Design Previews

> Design references from `docs/` representing the main album workspace and wireless pairing modal:

| Main Window · Album View | Device Connection · Wireless Pairing |
| :---: | :---: |
| ![Main Window Album View](./docs/%E4%B8%BB%E7%AA%97%E5%8F%A3%20%C2%B7%20%E7%9B%B8%E5%86%8C%E8%A7%86%E5%9B%BE.png) | ![Wireless Pairing Modal](./docs/%E8%AE%BE%E5%A4%87%E8%BF%9E%E6%8E%A5%20%C2%B7%20%E6%97%A0%E7%BA%BF%E9%85%8D%E5%AF%B9.png) |

---

## Requirements & Installation

### System Requirements
- **Mac**: Apple Silicon (`arm64`)
- **macOS**: macOS `14.0` or newer (supports macOS `27`)
- **Android**: Any MTP / Wireless Debugging capable Android phone (no companion app required)

### Installing & First Launch
1. Download the latest `DroidDock-<version>-arm64.dmg` (and optional `.dmg.sha256`) from [GitHub Releases](https://github.com/HarmonyChang/droid-dock/releases) .
2. Open the `.dmg` and drag `DroidDock.app` into `/Applications`.
3. **First-launch note**: Current releases are signed ad-hoc (`-`) without Apple Developer notarization. If macOS Gatekeeper blocks the downloaded app on first launch, remove the quarantine attribute once in Terminal:

```bash
xattr -dr com.apple.quarantine /Applications/DroidDock.app
```

*(Subsequent in-app auto-updates remove the quarantine attribute automatically before relaunching.)*

---

## Building, Testing & Packaging

DroidDock relies solely on Apple system frameworks and the local `USBMTP` Swift package:

```bash
# 1. Run USBMTP protocol unit tests
cd Packages/USBMTP && swift test && cd ../..

# 2. Build the macOS app and run the full XCTest suite
#    (Test host skips live USB initialization when XCTestConfigurationFilePath is set)
xcodebuild \
  -project DroidDock.xcodeproj \
  -scheme DroidDock \
  -destination 'platform=macOS,arch=arm64' \
  build test
```

### Release DMG & Checksum Packaging

```bash
bash scripts/package-app.sh
```

The script reads `MARKETING_VERSION` from `DroidDock.xcodeproj/project.pbxproj`, builds an `arm64` Release binary, verifies `codesign`, and produces:
- `dist/DroidDock.app`
- `dist/DroidDock-<version>-arm64.dmg`
- `dist/DroidDock-<version>-arm64.dmg.sha256`

To sign and notarize with a Developer ID certificate:

```bash
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
NOTARIZE_PROFILE="notary-profile" \
bash scripts/package-app.sh
```

---

## Keyboard Shortcuts

| Shortcut | Action |
| --- | --- |
| `⌘ + Shift + W` | Open Wireless Connection / QR Pairing sheet |
| `⌘ + Shift + R` | Rescan USB and wireless devices |
| `⌘ + R` | Reload current directory or album |
| `⌘ + A` | Select all items in the current view |
| `Space` | Toggle Quick Look preview (or close HD lightbox) |
| `←` / `→` / `Esc` | Step between photos or exit the HD lightbox |

---

## Architecture & Repository Layout

Dependencies strictly flow downward under Swift 6 complete concurrency checking: `UI` -> `App` (`@MainActor @Observable`) -> `Services` (`actor` / `@MainActor`) -> `Device` (`FileProvider` protocol & serialized `DeviceSession`) -> `Packages/USBMTP` (imported exclusively in [MTPProvider.swift](./DroidDock/Device/MTP/MTPProvider.swift) ).

```text
droid-dock/
├── DroidDock/
│   ├── App/                        # App entry & observable models: DroidDockApp, AppState, BrowserModel, TransferModel
│   ├── UI/                         # SwiftUI & AppKit views: SidebarView, BrowserContentView, PhotoPreviewView, TransferTrayView, AppUpdateSheetView, etc.
│   ├── Services/                   # TransferQueue, ThumbnailPipeline, MediaIndexStore, QuickDropWebServer, AppUpdateService
│   ├── Device/                     # FileProvider abstraction, DeviceSession, DeviceManager, MTP/, ADB/
│   ├── Support/                    # DiagnosticsService, PathUtils, Errors, Logger
│   ├── Resources/                  # AppIcon & asset catalog (Assets.xcassets)
│   └── Tests/                      # Unit tests backed by FakeFileProvider (USB-isolated)
├── Packages/
│   └── USBMTP/                     # Local Swift package: IOUSBHostTransport, MTPCodec, MTPSession, mtp-spike CLI & tests
├── scripts/
│   └── package-app.sh              # Release build, codesign verify, DMG & SHA-256 generator
├── docs/                           # Development specification & UI design previews
├── CHANGELOG.md                    # Release changelog
├── READMAP.md                      # Milestone progress & verification log (Chinese)
└── AGENTS.md                       # Engineering guidelines & constraints (Chinese)
```

---

## Related Documentation

- [Changelog](./CHANGELOG.md)
- [Development Roadmap & Verification Log](./READMAP.md)
- [Development Specification](./docs/DroidDock-Dev-Spec.md)
- [Engineering Guidelines](./AGENTS.md)
