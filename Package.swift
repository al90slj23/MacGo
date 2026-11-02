// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MacGo",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "MacGo", targets: ["MacGo"]),
        .executable(name: "MacToolboxFanHelper", targets: ["MacToolboxFanHelper"])
    ],
    targets: [
        .target(name: "ToolboxCore"),
        .target(name: "SMCController", dependencies: ["ToolboxCore"], exclude: ["Stats-MIT.txt"]),
        .target(name: "FanHelperProtocol", dependencies: ["ToolboxCore"]),
        .executableTarget(name: "MacToolboxFanHelper", dependencies: ["ToolboxCore", "SMCController", "FanHelperProtocol"]),
        .executableTarget(name: "MacGo", dependencies: ["ToolboxCore", "SMCController", "FanHelperProtocol"]),
        .testTarget(name: "ToolboxCoreTests", dependencies: ["ToolboxCore"]),
        .testTarget(name: "SMCControllerTests", dependencies: ["SMCController", "ToolboxCore"])
    ]
)
