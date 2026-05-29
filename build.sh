#!/usr/bin/env bash
# Build EngBar.app from EngBar.swift: compile, assemble the .app bundle,
# ad-hoc codesign, and (optionally) install + relaunch.
#
#   ./build.sh          build into ./build/EngBar.app
#   ./build.sh install  also copy to ~/Applications and relaunch
set -euo pipefail

cd "$(dirname "$0")"

APP="build/EngBar.app"
MACOS_DIR="$APP/Contents/MacOS"
TARGET="arm64-apple-macos13.0"

echo "==> compiling EngBar.swift"
mkdir -p "$MACOS_DIR"
swiftc -parse-as-library -O -o "$MACOS_DIR/EngBar" EngBar.swift -target "$TARGET"

echo "==> assembling bundle"
cp Info.plist "$APP/Contents/Info.plist"

echo "==> codesigning (ad-hoc)"
codesign --force --sign - "$MACOS_DIR/EngBar"

echo "==> built $APP"

if [[ "${1:-}" == "install" ]]; then
    DEST="$HOME/Applications/EngBar.app"
    echo "==> installing to $DEST"
    pkill -f '/EngBar.app/Contents/MacOS/EngBar' 2>/dev/null || true
    sleep 1
    rm -rf "$DEST"
    cp -R "$APP" "$DEST"
    open "$DEST"
    echo "==> launched"
fi
