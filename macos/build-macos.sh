#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
SOURCE="$ROOT/Sources/CodexUsageHUD/main.swift"
PLIST="$ROOT/App/Info.plist"
BUILD="$ROOT/build"
APP="$BUILD/CodexUsageHUD.app"
ARM64_BINARY="$BUILD/CodexUsageHUD-arm64"
X86_64_BINARY="$BUILD/CodexUsageHUD-x86_64"

if ! xcrun --find swiftc >/dev/null 2>&1; then
    echo "未找到 Swift 编译器。请先运行 xcode-select --install，安装完成后重试。" >&2
    exit 1
fi

case "$BUILD" in
    "$ROOT"/*) ;;
    *) echo "拒绝清理项目目录外的构建路径：$BUILD" >&2; exit 1 ;;
esac

rm -rf "$BUILD"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
xcrun swiftc \
    -target arm64-apple-macosx12.0 \
    -O -whole-module-optimization \
    -framework AppKit -framework Foundation \
    "$SOURCE" \
    -o "$ARM64_BINARY"
xcrun swiftc \
    -target x86_64-apple-macosx12.0 \
    -O -whole-module-optimization \
    -framework AppKit -framework Foundation \
    "$SOURCE" \
    -o "$X86_64_BINARY"
xcrun lipo -create "$ARM64_BINARY" "$X86_64_BINARY" \
    -output "$APP/Contents/MacOS/CodexUsageHUD"
cp "$PLIST" "$APP/Contents/Info.plist"

if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
    codesign --force --deep --options runtime --timestamp \
        --sign "$CODESIGN_IDENTITY" "$APP"
    codesign --verify --deep --strict "$APP"
fi

"$APP/Contents/MacOS/CodexUsageHUD" --self-test
echo "构建完成：$APP"
