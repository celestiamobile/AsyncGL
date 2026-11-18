// swift-tools-version:6.1

import PackageDescription

let package = Package(
    name: "AsyncGL",
    platforms: [
        .iOS(.v16),
        .macCatalyst(.v16),
        .tvOS(.v16),
        .macOS(.v13),
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
            url: "https://github.com/celestiamobile/angle-apple/releases/download/1.1.56/libGLESv2.xcframework.zip",
            checksum: "1faa65ebecc96eeff0594d338b21e32d989d2134a5ebcca7eac5b4c8820ad5cc"
        ),
        .binaryTarget(
            name: "libEGL",
            url: "https://github.com/celestiamobile/angle-apple/releases/download/1.1.56/libEGL.xcframework.zip",
            checksum: "886b0b76fea486f403f5122da0b1f95415d5d900ac16bfee38819501c3fbb95f"
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
