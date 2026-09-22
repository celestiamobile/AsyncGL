// swift-tools-version:6.1

import PackageDescription

let package = Package(
    name: "AsyncGL",
    platforms: [
        .iOS(.v15),
        .macCatalyst(.v15),
        .tvOS(.v15),
        .macOS(.v12),
        .visionOS(.v1),
    ],
    products: [
        .library(
            name: "AsyncGL",
            targets: ["AsyncGL"]
        ),
        .library(name: "ANGLE", targets: [
            "libGLESv2",
            "libEGL",
        ]),
    ],
    traits: [
        .trait(name: "OpenGL", description: "Use native OpenGL (default)"),
        .trait(name: "ANGLE", description: "Use ANGLE for OpenGL ES via EGL"),
        .default(enabledTraits: ["OpenGL"]),
    ],
    targets: [
        .binaryTarget(
            name: "libGLESv2",
            url: "https://github.com/celestiamobile/angle-apple/releases/download/1.1.48/libGLESv2.xcframework.zip",
            checksum: "658007b975b2884a5112d04fa7ca9f8d965f6cd689e536fdd8e9775f3fab5ed1"
        ),
        .binaryTarget(
            name: "libEGL",
            url: "https://github.com/celestiamobile/angle-apple/releases/download/1.1.48/libEGL.xcframework.zip",
            checksum: "e010c06048f043420e5c545eb5b743f40f417029c10f860a4bfc9c2148d8d754"
        ),
        .target(
            name: "AsyncGL",
            dependencies: [
                .target(name: "libGLESv2", condition: .when(traits: ["ANGLE"])),
                .target(name: "libEGL", condition: .when(traits: ["ANGLE"])),
            ],
            path: "AsyncGL",
            publicHeadersPath: "include",
            cSettings: [
                .define("GL_SILENCE_DEPRECATION"),
                .define("GL_GLEXT_PROTOTYPES", .when(traits: ["ANGLE"])),
                .define("EGL_EGLEXT_PROTOTYPES", .when(traits: ["ANGLE"])),
            ]
        ),
    ]
)
