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
    dependencies: [
        // Generator is a *plugin* — attached via `plugins:`, never a target dependency.
        // Floor 1.14.0: the version this package was built and verified with (2026-10-18).
        .package(url: "https://github.com/apple/swift-openapi-generator", from: "1.14.0"),
        .package(url: "https://github.com/apple/swift-openapi-runtime", from: "1.13.0"),
        // YAML round-trip for the maintainer spec tool only.
        .package(url: "https://github.com/jpsim/Yams", from: "6.0.0"),
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
        // Maintainer tool: fetch + normalize the vendored spec. `swift run devin-spec-tool`.
        .executableTarget(
            name: "devin-spec-tool",
            dependencies: [.product(name: "Yams", package: "Yams")],
            swiftSettings: upcoming
        ),
    ]
)
