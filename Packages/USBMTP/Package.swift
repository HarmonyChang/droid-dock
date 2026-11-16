// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "USBMTP",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "USBMTP", targets: ["USBMTP"]),
        .executable(name: "mtp-spike", targets: ["MTPSpike"]),
    ],
    targets: [
        .target(name: "USBMTP"),
        .executableTarget(name: "MTPSpike", dependencies: ["USBMTP"]),
        .testTarget(name: "USBMTPTests", dependencies: ["USBMTP"]),
    ]
)
