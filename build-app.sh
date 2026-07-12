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

# ---------------------------------------------------------------------------
# DMG packaging (drag-to-Applications installer)
#   ./build-app.sh          -> build .app only
#   ./build-app.sh --dmg    -> also build a distributable .dmg
# ---------------------------------------------------------------------------
MAKE_DMG=false
for arg in "$@"; do
    case "$arg" in
        --dmg|-d) MAKE_DMG=true ;;
    esac
done

if [ "$MAKE_DMG" = true ]; then
    DMG_PATH="$PROJECT_DIR/build/${APP_NAME}.dmg"
    STAGING_DIR="$PROJECT_DIR/build/dmg-staging"
    VOL_NAME="$APP_NAME"

    echo "==> Building DMG..."
    # Fresh staging area containing the app + an /Applications symlink so users can
    # drag the app straight onto Applications inside the mounted volume.
    rm -rf "$STAGING_DIR" "$DMG_PATH"
    mkdir -p "$STAGING_DIR"
    cp -R "$APP_BUNDLE" "$STAGING_DIR/"
    ln -s /Applications "$STAGING_DIR/Applications"

    hdiutil create \
        -volname "$VOL_NAME" \
        -srcfolder "$STAGING_DIR" \
        -fs HFS+ \
        -format UDZO \
        -ov \
        "$DMG_PATH" >/dev/null

    rm -rf "$STAGING_DIR"

    echo "==> Done: $DMG_PATH"
    echo "    Mount with: open \"$DMG_PATH\"  (拖动 ${APP_NAME}.app 到 Applications 即可安装)"
fi
