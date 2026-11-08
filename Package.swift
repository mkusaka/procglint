// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Procglint",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "ProcglintCore", targets: ["ProcglintCore"]),
        .library(name: "ProcglintIPC", targets: ["ProcglintIPC"]),
        .library(name: "ProcglintMCPKit", targets: ["ProcglintMCPKit"]),
        .library(name: "ProcglintApp", targets: ["ProcglintApp"]),
        .executable(name: "procglint-agent", targets: ["ProcglintAgent"]),
        .executable(name: "procglint-mcp", targets: ["ProcglintMCP"]),
        .executable(name: "procglint", targets: ["ProcglintCLI"]),
        .executable(name: "Procglint", targets: ["ProcglintAppMain"]),
        .executable(name: "procglint-workload", targets: ["WorkloadGenerator"]),
    ],
    targets: [
        .target(name: "CProcglintDarwin"),
        .target(name: "ProcglintCore", dependencies: ["CProcglintDarwin"]),
        .target(name: "ProcglintIPC", dependencies: ["ProcglintCore"]),
        .target(name: "ProcglintAgentKit", dependencies: ["ProcglintCore", "ProcglintIPC"]),
        .executableTarget(name: "ProcglintAgent", dependencies: ["ProcglintAgentKit"]),
        .target(name: "ProcglintMCPKit", dependencies: ["ProcglintCore"]),
        .executableTarget(name: "ProcglintMCP", dependencies: ["ProcglintMCPKit", "ProcglintIPC"]),
        .executableTarget(name: "ProcglintCLI", dependencies: ["ProcglintCore", "ProcglintIPC"]),
        .target(name: "ProcglintApp", dependencies: ["ProcglintCore", "ProcglintIPC"], path: "App"),
        .executableTarget(name: "ProcglintAppMain", dependencies: ["ProcglintApp"]),
        .executableTarget(name: "WorkloadGenerator", path: "Fixtures/WorkloadGenerator"),
        .testTarget(name: "CoreTests", dependencies: ["ProcglintCore"]),
        .testTarget(name: "IPCTests", dependencies: ["ProcglintIPC", "ProcglintCore"]),
        .testTarget(name: "AgentTests", dependencies: ["ProcglintAgentKit", "ProcglintIPC", "ProcglintCore"]),
        .testTarget(name: "MCPTests", dependencies: ["ProcglintMCPKit", "ProcglintCore"]),
        .testTarget(name: "AppTests", dependencies: ["ProcglintApp", "ProcglintCore"]),
        .testTarget(name: "IntegrationTests", dependencies: ["ProcglintAgentKit", "ProcglintIPC", "ProcglintMCPKit", "ProcglintCore"]),
        .testTarget(name: "PerformanceTests", dependencies: ["ProcglintAgentKit", "ProcglintCore"]),
    ]
)
