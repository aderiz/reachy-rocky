#!/usr/bin/env bash
# Build Rocky as a proper macOS .app bundle.
#
# Why: swift run launches an executable directly, and TCC (the macOS
# permission system) ties prompts + decisions to a code signature.
# Without a real .app bundle with a stable signature, microphone /
# speech-recognition / camera prompts won't fire reliably and the user
# may not see the system permission dialogs at all.
#
# What this does:
#   1. swift build -c release
#   2. Assembles ./build/Rocky.app/Contents/{MacOS,Resources}/
#   3. Writes Info.plist with the required usage descriptions
#   4. Ad-hoc codesigns (no Developer ID needed for personal dev)
#   5. Opens Rocky.app
#
# Run from the repo root: ./scripts/build-app.sh

set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
APP="$REPO/build/Rocky.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RES="$CONTENTS/Resources"
EXEC_NAME="Rocky"

cd "$REPO"

echo "==> Building (release)…"
swift build -c release --product Rocky

BIN_PATH="$(swift build -c release --product Rocky --show-bin-path)/$EXEC_NAME"
if [[ ! -x "$BIN_PATH" ]]; then
    echo "error: built binary not found at $BIN_PATH" >&2
    exit 1
fi

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$MACOS" "$RES"
cp "$BIN_PATH" "$MACOS/$EXEC_NAME"

# App icon — generate AppIcon.icns from Resources/AppIcon.source.png
# on every build. Source of truth is the PNG; the .icns is a build
# artifact so we don't have to keep a binary in version control.
# Each entry in the .iconset directory follows Apple's naming
# convention (icon_<size>.png + icon_<size>@2x.png); `iconutil`
# pacakages them into the final .icns.
ICON_SRC="$REPO/Resources/AppIcon.source.png"
if [[ -f "$ICON_SRC" ]]; then
    echo "==> Generating AppIcon.icns from $ICON_SRC"
    ICONSET="$(mktemp -d)/AppIcon.iconset"
    mkdir -p "$ICONSET"
    sips -z 16   16   "$ICON_SRC" --out "$ICONSET/icon_16x16.png"     >/dev/null
    sips -z 32   32   "$ICON_SRC" --out "$ICONSET/icon_16x16@2x.png"  >/dev/null
    sips -z 32   32   "$ICON_SRC" --out "$ICONSET/icon_32x32.png"     >/dev/null
    sips -z 64   64   "$ICON_SRC" --out "$ICONSET/icon_32x32@2x.png"  >/dev/null
    sips -z 128  128  "$ICON_SRC" --out "$ICONSET/icon_128x128.png"   >/dev/null
    sips -z 256  256  "$ICON_SRC" --out "$ICONSET/icon_128x128@2x.png">/dev/null
    sips -z 256  256  "$ICON_SRC" --out "$ICONSET/icon_256x256.png"   >/dev/null
    sips -z 512  512  "$ICON_SRC" --out "$ICONSET/icon_256x256@2x.png">/dev/null
    sips -z 512  512  "$ICON_SRC" --out "$ICONSET/icon_512x512.png"   >/dev/null
    sips -z 1024 1024 "$ICON_SRC" --out "$ICONSET/icon_512x512@2x.png">/dev/null
    iconutil -c icns "$ICONSET" -o "$RES/AppIcon.icns"
    rm -rf "$(dirname "$ICONSET")"
else
    echo "==> WARN: $ICON_SRC missing — building without an app icon"
fi

cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>                 <string>Rocky</string>
    <key>CFBundleDisplayName</key>          <string>Rocky</string>
    <key>CFBundleIdentifier</key>           <string>ai.amplified.Rocky</string>
    <key>CFBundleVersion</key>              <string>0.1.0</string>
    <key>CFBundleShortVersionString</key>   <string>0.1.0</string>
    <key>CFBundleExecutable</key>           <string>Rocky</string>
    <key>CFBundleIconFile</key>             <string>AppIcon</string>
    <key>CFBundlePackageType</key>          <string>APPL</string>
    <key>LSMinimumSystemVersion</key>       <string>15.0</string>
    <key>LSUIElement</key>                  <false/>
    <key>NSHighResolutionCapable</key>      <true/>
    <key>NSPrincipalClass</key>             <string>NSApplication</string>

    <!-- Permissions Rocky needs at runtime -->
    <key>NSMicrophoneUsageDescription</key>
    <string>Rocky listens for the wake word "Rocky" and your follow-ups so it can respond.</string>

    <key>NSSpeechRecognitionUsageDescription</key>
    <string>Rocky transcribes your speech locally so it can decide whether you addressed it.</string>

    <key>NSCameraUsageDescription</key>
    <string>Rocky may use the Mac camera as a fallback when the robot's camera isn't available.</string>

    <key>NSCalendarsUsageDescription</key>
    <string>Rocky reads your calendar so he can answer questions about your schedule and what's coming up.</string>

    <key>NSCalendarsFullAccessUsageDescription</key>
    <string>Rocky reads your calendar so he can answer questions about your schedule and what's coming up.</string>

    <key>NSLocationUsageDescription</key>
    <string>Rocky uses your approximate location so he can tell you the local weather without having to ask which city.</string>

    <key>NSLocationWhenInUseUsageDescription</key>
    <string>Rocky uses your approximate location so he can tell you the local weather without having to ask which city.</string>

    <!-- Allow plain HTTP to the local-network daemon and LM Studio. -->
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsLocalNetworking</key>
        <true/>
    </dict>
</dict>
</plist>
PLIST

# Sign with the first available code-signing identity, preferring
# Developer ID > Apple Development > ad-hoc. macOS Sequoia's TCC
# keys grants for sensitive permissions (Calendar, Location,
# Camera) by Bundle ID + Team ID — with ad-hoc signing the Team
# ID is empty, so a different CDHash on each rebuild made TCC
# re-prompt every cycle. A real cert (even the free "Apple
# Development" cert Xcode auto-generates from an Apple ID)
# supplies a stable Team ID, so granted permissions persist
# across rebuilds.
SIGN_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -E "Developer ID Application|Apple Development" \
    | head -1 \
    | awk -F'"' '{print $2}')

if [[ -n "$SIGN_IDENTITY" ]]; then
    echo "==> Signing with: $SIGN_IDENTITY"
    codesign --force --sign "$SIGN_IDENTITY" --timestamp=none "$APP" >/dev/null
else
    # Hardened runtime (--options runtime) is for notarised distribution.
    # With ad-hoc signing + hardened runtime + no entitlements file,
    # macOS Sequoia silently refuses Calendar / EventKit prompts —
    # `requestFullAccessToEvents()` returns false without ever
    # showing the system dialog. Plain ad-hoc is what local dev
    # falls back to when no signing identity is available.
    echo "==> Ad-hoc signing (no Developer ID / Apple Development cert found)"
    codesign --force --sign - --timestamp=none "$APP" >/dev/null
fi

echo
echo "Built: $APP"
echo "Run with:  open '$APP'"
echo "Or:        '$APP/Contents/MacOS/$EXEC_NAME'"
