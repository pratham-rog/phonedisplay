// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PhoneDisplay",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "PhoneDisplay", targets: ["PhoneDisplay"]),
        .library(name: "PhoneDisplayCore", targets: ["PhoneDisplayCore"]),
    ],
    targets: [
        .target(name: "PhoneDisplayCore"),
        .executableTarget(
            name: "PhoneDisplay",
            dependencies: ["PhoneDisplayCore"]
        ),
        .executableTarget(
            name: "PhoneDisplayCoreChecks",
            dependencies: ["PhoneDisplayCore"]
        ),
    ]
)
