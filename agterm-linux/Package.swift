// swift-tools-version:6.0
import PackageDescription
import Foundation

let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let vendor = "\(packageRoot)/vendor/ghostty"

let home = ProcessInfo.processInfo.environment["HOME"] ?? ""
var cIncludePaths: [String] = ["\(vendor)/include"]
var extraLinkerFlags: [String] = [
    "-L\(vendor)/lib", "-lghostty", "-lepoxy",
    "-Xlinker", "-rpath", "-Xlinker", "\(vendor)/lib",
]
if !home.isEmpty && FileManager.default.fileExists(atPath: "\(home)/.local/include/webkitgtk-6.0") {
    cIncludePaths.append(contentsOf: [
        "\(home)/.local/include/webkitgtk-6.0",
        "\(home)/.local/include/javascriptcoregtk-6.0",
        "\(home)/.local/include/libsoup-3.0",
    ])
}
if !home.isEmpty && FileManager.default.fileExists(atPath: "\(home)/.local/lib") {
    extraLinkerFlags.append(contentsOf: [
        "-L\(home)/.local/lib",
        "-lwebkitgtk-6.0",
        "-ljavascriptcoregtk-6.0",
    ])
}
let targetSwiftSettings: [SwiftSetting] = cIncludePaths.map { .unsafeFlags(["-Xcc", "-I\($0)"]) }

let package = Package(
    name: "agterm-linux",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "AgtermLinux", targets: ["AgtermLinux"]),
        .executable(name: "agtermctl-linux", targets: ["agtermctlLinux"]),
        .library(name: "LinuxIntegrations", targets: ["LinuxIntegrations"]),
    ],
    dependencies: [
        .package(name: "agtermCore", path: "../agtermCore"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
    ],
    targets: [
        .systemLibrary(name: "CGtk", path: "Sources/CGtk", pkgConfig: "libadwaita-1"),
        .systemLibrary(name: "CWebKit", path: "Sources/CWebKit", pkgConfig: "webkitgtk-6.0"),
        .target(
            name: "LinuxIntegrations",
            dependencies: [.product(name: "agtermCore", package: "agtermCore")]
        ),
        .executableTarget(
            name: "AgtermLinux",
            dependencies: [
                "CGtk",
                "CWebKit",
                "LinuxIntegrations",
                .product(name: "agtermCore", package: "agtermCore"),
            ],
            resources: [.copy("Resources/hud")],
            swiftSettings: targetSwiftSettings,
            linkerSettings: [ .unsafeFlags(extraLinkerFlags) ]
        ),
        .executableTarget(
            name: "agtermctlLinux",
            dependencies: [
                "LinuxIntegrations",
                .product(name: "agtermctlKit", package: "agtermCore"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/agtermctl"
        ),
        .testTarget(
            name: "LinuxIntegrationsTests",
            dependencies: ["LinuxIntegrations", .product(name: "agtermCore", package: "agtermCore")]
        ),
        .testTarget(
            name: "agtermctlLinuxTests",
            dependencies: ["agtermctlLinux", "LinuxIntegrations",
                           .product(name: "agtermCore", package: "agtermCore"),
                           .product(name: "ArgumentParser", package: "swift-argument-parser")]
        ),
        .testTarget(
            name: "AgtermLinuxTests",
            // CGtk (+ the ghostty header path its umbrella pulls in) so the GLib timer seam can be pumped
            // headlessly with `g_main_context_iteration` — no display and no gtk_init needed.
            dependencies: ["AgtermLinux", "CGtk", .product(name: "agtermCore", package: "agtermCore")],
            swiftSettings: targetSwiftSettings
        ),
    ],
    swiftLanguageModes: [.v6]
)
