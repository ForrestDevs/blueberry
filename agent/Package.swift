// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BlueberryAgent",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "BlueberryCore", targets: ["BlueberryCore"]),
        .executable(name: "blueberry-agent", targets: ["BlueberryAgent"]),
    ],
    targets: [
        .target(name: "BlueberryCore", linkerSettings: [.linkedLibrary("sqlite3")]),
        .executableTarget(name: "BlueberryAgent", dependencies: ["BlueberryCore"]),
        .testTarget(name: "BlueberryCoreTests", dependencies: ["BlueberryCore"]),
    ]
)
