#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
backend="${1:-native}"
case "$backend" in
    native) flags=(-framework OpenGL) ;;
    angle)
        cd "$root"
        swift build --traits ANGLE
        egl="$root/.build/artifacts/asyncgl/libEGL/libEGL.xcframework/macos-arm64_x86_64"
        gles="$root/.build/artifacts/asyncgl/libGLESv2/libGLESv2.xcframework/macos-arm64_x86_64"
        flags=(-DEGL_EGLEXT_PROTOTYPES -DGL_GLEXT_PROTOTYPES
            -F "$egl" -F "$gles" -framework libEGL -framework libGLESv2
            "-Wl,-rpath,$egl" "-Wl,-rpath,$gles")
        ;;
    *) echo "Usage: $0 [native|angle]" >&2; exit 2 ;;
esac
work="$(mktemp -d "${TMPDIR:-/tmp}/asyncgl-sample-tests.XXXXXX")"
mkdir "$work/bin" "$work/Frameworks"
binary="$work/bin/sample-tests"
trap 'rm -f "$binary" "$work/Frameworks/libGLESv2.framework"; rmdir "$work/bin" "$work/Frameworks" "$work"' EXIT
if [[ "$backend" == angle ]]; then
    ln -s "$gles/libGLESv2.framework" "$work/Frameworks/libGLESv2.framework"
fi
xcrun clang -fobjc-arc -fmodules -DGL_SILENCE_DEPRECATION \
    -I "$root/AsyncGL" "$root/Tests/SampleBufferOutputTests.m" \
    "$root/AsyncGL/AsyncGLSampleBufferOutput.m" \
    -framework Cocoa -framework QuartzCore "${flags[@]}" -o "$binary"
"$binary"
