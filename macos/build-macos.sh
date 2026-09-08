#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
SOURCE="$ROOT/Sources/CodexUsageHUD/main.swift"
PLIST="$ROOT/App/Info.plist"
BUILD="$ROOT/build"
APP="$BUILD/CodexUsageHUD.app"

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
    -O -whole-module-optimization \
    -framework AppKit -framework Foundation \
    "$SOURCE" \
    -o "$APP/Contents/MacOS/CodexUsageHUD"
cp "$PLIST" "$APP/Contents/Info.plist"

"$APP/Contents/MacOS/CodexUsageHUD" --self-test
echo "构建完成：$APP"
