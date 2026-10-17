// swift-tools-version: 5.9
import Foundation
import PackageDescription

let fileManager = FileManager.default
// Prefer the directory containing *this* Package.swift so the local-vendor
// preference works the same way whether Termini is built directly or as a
// SwiftPM dependency of another package (where PWD/cwd point at the
// consumer, not Termini).
let packageRootCandidates = [
    URL(fileURLWithPath: #filePath).deletingLastPathComponent(),
    ProcessInfo.processInfo.environment["PWD"].map(URL.init(fileURLWithPath:)),
    URL(fileURLWithPath: fileManager.currentDirectoryPath),
].compactMap { $0 }
let packageRoot = packageRootCandidates.first(where: {
    fileManager.fileExists(atPath: $0.appending(path: "Package.swift").path)
}) ?? packageRootCandidates[0]
let localGhosttyKitRelativePath = "vendor/ghostty/macos/GhosttyKit.xcframework"
let localGhosttyKitAbsolutePath = packageRoot.appending(path: localGhosttyKitRelativePath).path
// Embedding ABI that Termini's sources call. A local framework built before
// these declarations existed is ignored so it cannot shadow the release.
let requiredGhosttyKitDeclarations = [
    "ghostty_surface_snapshot_cb",
    "ghostty_surface_request_snapshot",
]
let bundledGhosttyKitExists: Bool = {
    let frameworkURL = URL(fileURLWithPath: localGhosttyKitAbsolutePath)
    guard fileManager.fileExists(atPath: frameworkURL.appending(path: "Info.plist").path),
          let slices = try? fileManager.contentsOfDirectory(atPath: frameworkURL.path)
    else { return false }
    let headers = slices.compactMap { slice in
        try? String(
            contentsOf: frameworkURL.appending(path: "\(slice)/Headers/ghostty.h"),
            encoding: .utf8
        )
    }
    return !headers.isEmpty && headers.allSatisfy { header in
        requiredGhosttyKitDeclarations.allSatisfy(header.contains)
    }
}()
// 0.1.6 tracks Ghostty main (d71bcd105, Jun 2026) plus Termini embedding
// APIs (`write_to_host_cb`, `ghostty_surface_process_output`, font config
// setters, and durable surface snapshots). Upstream already includes the iOS
// Metal surface-attach fixes.
//
// Local development: drop the rebuilt xcframework into
// `vendor/ghostty/macos/GhosttyKit.xcframework` and the local-vendor
// preference above will use it. The URL below is consumed when no current
// local vendor is present (CI, downstream packages). SwiftPM caches manifest
// evaluation, so after adding or removing a local framework run
// `swift package purge-cache` or build once with `--manifest-cache none`.
let releaseGhosttyKitURL = "https://github.com/FauxFoxIO/Termini/releases/download/ghosttykit-0.3.0-appstore-safe/GhosttyKit.xcframework.zip"
let releaseGhosttyKitChecksum = "7bb1fe5f0030ebcdb5592ebc1b110001dff3f926306165e0dcaa87f4d1739c66"

let ghosttyKitTarget: Target =
    if bundledGhosttyKitExists {
        .binaryTarget(
            name: "GhosttyKit",
            path: localGhosttyKitRelativePath
        )
    } else {
        .binaryTarget(
            name: "GhosttyKit",
            url: releaseGhosttyKitURL,
            checksum: releaseGhosttyKitChecksum
        )
    }

let terminalLinkerSettings: [LinkerSetting] = [
    .linkedLibrary("c++"),
    .linkedFramework("AppKit", .when(platforms: [.macOS])),
    .linkedFramework("Carbon", .when(platforms: [.macOS])),
    .linkedFramework("CoreGraphics"),
    .linkedFramework("CoreText"),
    .linkedFramework("Metal"),
    .linkedFramework("UIKit", .when(platforms: [.iOS, .visionOS])),
    .linkedFramework("QuartzCore", .when(platforms: [.iOS, .visionOS]))
]

let package = Package(
    name: "Termini",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
        .visionOS(.v1)
    ],
    products: [
        .library(
            name: "Termini",
            targets: ["Termini"]
        ),
        .library(
            name: "TerminiSSH",
            targets: ["TerminiSSH"]
        ),
        .executable(
            name: "TerminiDemo",
            targets: ["TerminiDemo"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.97.0"),
        .package(url: "https://github.com/apple/swift-nio-ssh.git", from: "0.9.1"),
        .package(url: "https://github.com/apple/swift-nio-transport-services.git", from: "1.26.0")
    ],
    targets: [
        ghosttyKitTarget,
        .target(
            name: "Termini",
            dependencies: [
                "GhosttyKit"
            ],
            linkerSettings: terminalLinkerSettings
        ),
        .target(
            name: "TerminiSSH",
            dependencies: [
                "Termini",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
                .product(name: "NIOTransportServices", package: "swift-nio-transport-services")
            ]
        ),
        .executableTarget(
            name: "TerminiDemo",
            dependencies: ["Termini"],
            path: "Examples/TerminiDemo"
        ),
        .testTarget(
            name: "TerminiTests",
            dependencies: ["Termini"]
        ),
        .testTarget(
            name: "TerminiSSHTests",
            dependencies: [
                "TerminiSSH",
                .product(name: "NIOSSH", package: "swift-nio-ssh")
            ]
        )
    ]
)
