#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="slogcat"
EXEC_NAME="slogcat"        # CFBundleExecutable
BUNDLE_ID="com.slogcat.app"
APP_BUNDLE="$PROJECT_DIR/build/${APP_NAME}.app"
RELEASE_BIN="$PROJECT_DIR/.build/release/Slogcat"   # SPM 产物名是 target name "Slogcat"

echo "==> Building release..."
swift build -c release --package-path "$PROJECT_DIR"

echo "==> Assembling .app bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$RELEASE_BIN" "$APP_BUNDLE/Contents/MacOS/$EXEC_NAME"
cp "$PROJECT_DIR/Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
cp "$PROJECT_DIR/Resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

echo "==> Signing (ad-hoc)..."
codesign --force --deep --sign - "$APP_BUNDLE"

echo "==> Done: $APP_BUNDLE"
echo "    Open with: open \"$APP_BUNDLE\""
