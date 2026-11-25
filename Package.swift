// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "NVMeter",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "NVMeter", targets: ["NVMeter"])],
    targets: [
        // Tiny C shim: calls the COM-style IONVMeSMARTInterface vtable from Apple's
        // NVMeSMARTLibExternal.h, which Swift cannot import (CFUUID macros, CFPlugIn COM).
        .target(name: "CNVMe", path: "Sources/CNVMe"),
        .executableTarget(
            name: "NVMeter",
            dependencies: ["CNVMe"],
            path: "Sources/NVMeter",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("DiskArbitration"),
            ]
        ),
    ]
)
