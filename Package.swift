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
            url: "https://github.com/celestiamobile/angle-apple/releases/download/1.1.51/libGLESv2.xcframework.zip",
            checksum: "13a45fe4b91183a56f1c0245f741a945fb4b97c659608a8a429d5517f14afd11"
        ),
        .binaryTarget(
            name: "libEGL",
            url: "https://github.com/celestiamobile/angle-apple/releases/download/1.1.51/libEGL.xcframework.zip",
            checksum: "5cd1426af56de7e08a14b21c2ea6fbd56e7ba1a9c32f954c3332dd57c235b3a0"
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
