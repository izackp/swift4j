// swift-tools-version:5.10

import PackageDescription
import CompilerPluginSupport

let package = Package(
    name: "Java",
    platforms: [.macOS(.v10_15), .iOS(.v13), .tvOS(.v13), .watchOS(.v6), .visionOS(.v1)],
    
    products: [
        .library(name: "Java", targets: ["Java"]),
        .library(name: "Swift4j", targets: ["Swift4j"]),

        .executable(name: "swift4j-cli", targets: ["swift4j-cli"]),

        // Test-only. Loaded by a host JVM in scripts/run-jvm-integration-tests.sh,
        // which is the only place RegisterNatives and the borrow semantics
        // actually run.
        .library(name: "Swift4jFixtures", type: .dynamic, targets: ["Swift4jFixtures"]),

        .plugin(name: "swift4j-plugin", targets: ["swift4j-plugin"]),
        .plugin(name: "generate-java-bridging", targets: ["generate-java-bridging"])
    ],

    dependencies: [
      .package(url: "https://github.com/swiftlang/swift-syntax", from: "600.0.0"),
      .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.2.0"),
    ],

    targets: [
        .systemLibrary(name: "CJNI"),
        
        .target(name: "CAndroid"),

        .target(name: "Java",
                dependencies: [
                  "CJNI",
                  .target(name: "CAndroid", condition: .when(platforms: [.android])),
                ]),

        .target(name: "SwiftSyntaxExtensions",
                dependencies: [
                  .product(name: "SwiftSyntax", package: "swift-syntax")
                ]),

        .macro(name: "Swift4jMacros",
               dependencies: [
                  "SwiftSyntaxExtensions",
                   .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                   .product(name: "SwiftCompilerPlugin", package: "swift-syntax")
               ]),

        .target(name: "Swift4j",
                dependencies: [
                  "Java",
                  "Swift4jMacros"
                ],
                resources: [
                  .process("java/io/scade/swift4j/Result.java"),
                  .process("java/io/scade/swift4j/SwiftError.java"),
                  .process("java/io/scade/swift4j/SwiftPtr.java"),
                  .process("java/io/scade/swift4j/SwiftBorrow.java")
                ]),

        .executableTarget(name: "swift4j-cli",
                         dependencies: [
                          "SwiftSyntaxExtensions",
                          .product(name: "ArgumentParser", package: "swift-argument-parser"),
                          .product(name: "SwiftParser", package: "swift-syntax")
                         ]),

        .plugin(name: "swift4j-plugin",
                capability: .buildTool(),
                dependencies: ["swift4j-cli"]),

        
        .plugin(name: "generate-java-bridging",
                capability: .command(
                  intent: .custom(verb: "generate-java-bridging",
                                  description: "Generate Java bridging proxies for the Swift classes"),
                  permissions: []),
                dependencies: ["swift4j-cli"]
               ),

        // Test-only. Declares the @jvm family without Swift4j's
        // `#if os(Android)` gate, which a consumer's .define cannot lift.
        .target(name: "Swift4jHostMacros",
                dependencies: ["Java", "Swift4jMacros"]),

        // Compiles the real @jvm expansions on the host. Nothing imports it;
        // building it IS the test, and without it no emitted thunk is
        // type-checked until an Android build runs.
        .target(name: "Swift4jFixtures",
                dependencies: ["Swift4jHostMacros"]),

        // Depends on both generators so the scoped-borrow rule can be checked
        // for agreement across them: they must emit identical native sets or
        // RegisterNatives unbinds the whole class.
        .testTarget(name: "Swift4jTests",
                    dependencies: [
                      "Swift4jMacros",
                      "swift4j-cli",
                      "SwiftSyntaxExtensions",
                      .product(name: "SwiftParser", package: "swift-syntax")
                    ])
    ]
)

