#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
swift build --scratch-path "$root/.build/native-mirroring"
egl="$root/.build/artifacts/asyncgl/libEGL/libEGL.xcframework/macos-arm64_x86_64"
gles="$root/.build/artifacts/asyncgl/libGLESv2/libGLESv2.xcframework/macos-arm64_x86_64"
work="$(mktemp -d "${TMPDIR:-/tmp}/asyncgl-mirroring.XXXXXX")"
mkdir "$work/bin" "$work/Frameworks"
trap 'rm -f "$work/bin/mirroring-tests" "$work/bin/native-mirroring-tests" "$work/Frameworks/libGLESv2.framework"; rmdir "$work/bin" "$work/Frameworks" "$work"' EXIT

xcrun clang -fobjc-arc -fmodules -DGL_SILENCE_DEPRECATION \
    -I "$root/AsyncGL" "$root/Tests/NativeMirroringTests.m" \
    -framework Cocoa -framework QuartzCore -framework OpenGL \
    -o "$work/bin/native-mirroring-tests"
"$work/bin/native-mirroring-tests"

swift build --traits ANGLE
ln -s "$gles/libGLESv2.framework" "$work/Frameworks/libGLESv2.framework"

xcrun clang -fobjc-arc -fmodules -DGL_SILENCE_DEPRECATION \
    -DEGL_EGLEXT_PROTOTYPES -DGL_GLEXT_PROTOTYPES \
    -I "$root/AsyncGL" -F "$egl" -F "$gles" \
    "$root/Tests/MirroringTests.m" \
    -framework Cocoa -framework QuartzCore -framework libEGL -framework libGLESv2 \
    "-Wl,-rpath,$egl" "-Wl,-rpath,$gles" -o "$work/bin/mirroring-tests"
"$work/bin/mirroring-tests"
