// swift-tools-version: 6.4
// Layout mirrors deepwiki-mcp (laconicman/deepwiki-mcp) and GitLabKit (laconicman/swift-gitlab):
// a generated OpenAPI target that holds only the vendored spec + generator config (the build
// plugin emits the code; nothing generated is committed), a thin handwritten façade on top,
// executables at the edge, and a maintainer tool that re-vendors and normalizes the spec.
import PackageDescription

/// Swift 7 upcoming features, on for every handwritten target (see the Design article).
/// `InternalImportsByDefault` turns the layering into a compiler rule: the Kit can only expose
/// a dependency's types through an explicit `public import`.
let upcoming: [SwiftSetting] = [
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("MemberImportVisibility"),
    .enableUpcomingFeature("InternalImportsByDefault"),
    .enableUpcomingFeature("ImmutableWeakCaptures"),
]

let package = Package(
    name: "devin-kick",
    platforms: [
        // macOS 15 for `Synchronization.Mutex`; this is a CLI/MCP tool for a Mac.
        .macOS(.v15),
    ],
    products: [
        // Façade: the API the CLI and the MCP server share.
        .library(name: "DevinKickKit", targets: ["DevinKickKit"]),
        // One binary, both faces: CLI subcommands + `kick serve` (MCP stdio).
        .executable(name: "kick", targets: ["kick"]),
    ],
    dependencies: [
        // Generator is a *plugin* — attached via `plugins:`, never a target dependency.
        // Floor 1.14.0: the version this package was built and verified with (2026-10-18).
        .package(url: "https://github.com/apple/swift-openapi-generator", from: "1.14.0"),
        .package(url: "https://github.com/apple/swift-openapi-runtime", from: "1.13.0"),
        .package(url: "https://github.com/apple/swift-openapi-urlsession", from: "1.1.0"),
        // Named directly because the Kit imports it (MemberImportVisibility makes that explicit).
        .package(url: "https://github.com/apple/swift-http-types", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
        // The official MCP Swift SDK (product `MCP`), for `kick serve`; linked only into KickMCP.
        // Pinned to a minor, as deepwiki-mcp pins it: pre-1.0, its README states that a minor
        // bump (0.X.0) may break. 0.12.1 is the latest release (2026-05-07), the source M2 was
        // planned against.
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", .upToNextMinor(from: "0.12.1")),
        // YAML round-trip for the maintainer spec tool only.
        .package(url: "https://github.com/jpsim/Yams", from: "6.0.0"),
        // DocC catalog rendering via `swift package generate-documentation`.
        .package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.4.0"),
    ],
    targets: [
        // Generated target: holds only the normalized openapi.yaml + the generator config.
        // Left at default language settings: its code is the generator's, not ours.
        .target(
            name: "DevinOpenAPI",
            dependencies: [
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
            ],
            plugins: [
                .plugin(name: "OpenAPIGenerator", package: "swift-openapi-generator"),
            ]
        ),
        // Thin façade: configuration, client factory, settlement, errors. Never imports
        // MCP or ArgumentParser — those live in KickMCP and the executable.
        .target(
            name: "DevinKickKit",
            dependencies: [
                "DevinOpenAPI",
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
                .product(name: "OpenAPIURLSession", package: "swift-openapi-urlsession"),
            ],
            swiftSettings: upcoming
        ),
        // The MCP server `kick serve` runs: its tools, their dispatch and their renderers, over
        // the Kit. A library target, so tests reach the server's logic, which deepwiki-mcp's
        // executable kept out of their reach.
        .target(
            name: "KickMCP",
            dependencies: [
                "DevinKickKit",
                .product(name: "MCP", package: "swift-sdk"),
            ],
            swiftSettings: upcoming
        ),
        // The `kick` binary: CLI subcommands (and, from M2, `serve`).
        .executableTarget(
            name: "kick",
            dependencies: [
                "DevinKickKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: upcoming
        ),
        // Maintainer tool: fetch + normalize the vendored spec. `swift run devin-spec-tool`.
        .executableTarget(
            name: "devin-spec-tool",
            dependencies: [.product(name: "Yams", package: "Yams")],
            swiftSettings: upcoming
        ),
        // Also KickMCP's tests (`KickMCP/`), which drive the server over the Kit's scripted
        // transport. A separate test target can't share these helpers: one test target depending
        // on another makes an unscoped `swift build -c release` compile the depended-on tests
        // without testability, and `@testable import` fails (SwiftPM 6.4, probed 2026-10-19).
        .testTarget(
            name: "DevinKickKitTests",
            dependencies: [
                "DevinKickKit",
                "DevinOpenAPI",
                "KickMCP",
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
            ],
            resources: [.copy("Fixtures")],
            swiftSettings: upcoming
        ),
    ]
)
