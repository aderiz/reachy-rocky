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

echo "==> Ad-hoc signing"
# Hardened runtime (--options runtime) is for notarised distribution.
# With ad-hoc signing + hardened runtime + no entitlements file,
# macOS Sequoia silently refuses Calendar / EventKit prompts —
# `requestFullAccessToEvents()` returns false without ever showing
# the system dialog. Plain ad-hoc is what local dev needs.
codesign --force --sign - --timestamp=none "$APP" >/dev/null

echo
echo "Built: $APP"
echo "Run with:  open '$APP'"
echo "Or:        '$APP/Contents/MacOS/$EXEC_NAME'"
