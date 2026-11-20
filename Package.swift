// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MarginNotes",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "MarginCore", targets: ["MarginCore"]),
               .executable(name: "Libere", targets: ["MarginNotes"])],
    targets: [.target(name: "MarginCore"),
              .executableTarget(name: "MarginNotes", dependencies: ["MarginCore"], exclude: ["Resources/Assets.xcassets"],
                                resources: [.copy("Resources/notebook_kernel.py"), .copy("Resources/BrandLogo.png"),
                                            .copy("Resources/libere_agent.py"), .copy("Resources/agent_rules.md"),
                                            .copy("Resources/agent_tools.json"), .copy("Resources/agent_openapi.json"),
                                            .copy("Resources/Showcase.json")]),
              .testTarget(name: "MarginCoreTests", dependencies: ["MarginCore"])]
)
