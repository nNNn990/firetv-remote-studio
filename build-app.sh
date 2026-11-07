#!/bin/zsh
# Builds FireTVRemoteBridge.app (release) next to this script. No Xcode project needed.
# Requirements: Xcode Command Line Tools (Swift 5.9+), `brew install opus pkg-config`.
# Signing: uses "Developer ID Application" if present, else "Apple Development", else ad-hoc.
# Set CODESIGN_IDENTITY to force a specific identity.
set -e
cd "$(dirname "$0")"
# Prefer the full Xcode toolchain when available: the Command Line Tools alone
# fail to drive SwiftPM's default build system on recent macOS betas.
if [ -z "$DEVELOPER_DIR" ] && [ -d /Applications/Xcode.app/Contents/Developer ]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
swift build -c release --product FireTVRemoteApp
swift build -c release --product FireTVHelper
APP="FireTVRemoteBridge.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Library/LaunchDaemons"
cp .build/release/FireTVHelper "$APP/Contents/MacOS/FireTVHelper"
cat > "$APP/Contents/Library/LaunchDaemons/com.uaaa.firetv-remote-bridge.helper.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.uaaa.firetv-remote-bridge.helper</string>
  <key>BundleProgram</key><string>Contents/MacOS/FireTVHelper</string>
  <key>MachServices</key><dict><key>com.uaaa.firetv-remote-bridge.helper</key><true/></dict>
  <key>AssociatedBundleIdentifiers</key><array><string>com.uaaa.firetv-remote-bridge</string></array>
</dict></plist>
PLIST
cp .build/release/FireTVRemoteApp "$APP/Contents/MacOS/FireTVRemoteBridge"
cp icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# UI localisations (English source keys + Japanese table)
for lproj in Resources/*.lproj; do
  [ -d "$lproj" ] && cp -R "$lproj" "$APP/Contents/Resources/"
done
# --- microphone: HAL driver, install/uninstall scripts, bundled libopus
./hal/build-driver.sh >/dev/null
cp -R hal/build/FireTVRemoteMicrophone.driver "$APP/Contents/Resources/"
cp scripts/install-mic-driver.sh scripts/uninstall.sh "$APP/Contents/Resources/"
mkdir -p "$APP/Contents/Frameworks"
# libopus: prefer the redistributable build from scripts/build-libopus.sh (universal, macOS 14+),
# otherwise bundle the pkg-config one (Homebrew/MacPorts; linked for this machine's OS only).
OPUS_LIBDIR=$(pkg-config --variable=libdir opus)
if [ -f vendor/libopus/libopus.0.dylib ]; then
  cp vendor/libopus/libopus.0.dylib "$APP/Contents/Frameworks/libopus.0.dylib"
else
  echo "note: bundling libopus from $OPUS_LIBDIR (run scripts/build-libopus.sh for a redistributable build)"
  cp "$OPUS_LIBDIR/libopus.0.dylib" "$APP/Contents/Frameworks/libopus.0.dylib"
fi
chmod 644 "$APP/Contents/Frameworks/libopus.0.dylib"
install_name_tool -id @rpath/libopus.0.dylib "$APP/Contents/Frameworks/libopus.0.dylib"
LINKED=$(otool -L "$APP/Contents/MacOS/FireTVRemoteBridge" | awk '/libopus/ {print $1; exit}')
install_name_tool -change "$LINKED" @rpath/libopus.0.dylib "$APP/Contents/MacOS/FireTVRemoteBridge"
install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/FireTVRemoteBridge" 2>/dev/null || true
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>FireTVRemoteBridge</string>
  <key>CFBundleDisplayName</key><string>Fire TV Remote Studio</string>
  <key>CFBundleIdentifier</key><string>com.uaaa.firetv-remote-bridge</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array><string>en</string><string>ja</string></array>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleExecutable</key><string>FireTVRemoteBridge</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSInputMonitoringUsageDescription</key><string>Fire TV Remote Studio reads button presses from your paired Fire TV remote.</string>
  <key>NSAccessibilityUsageDescription</key><string>Fire TV Remote Studio sends the keyboard shortcuts and media keys you assign to the remote.</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHumanReadableCopyright</key><string>MIT License. Not affiliated with Amazon.</string>
</dict></plist>
PLIST
# Prefer a real identity so macOS privacy grants (Input Monitoring, Accessibility) survive rebuilds.
IDENTITY="${CODESIGN_IDENTITY:-}"
[ -z "$IDENTITY" ] && IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"')
[ -z "$IDENTITY" ] && IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep -o '"Apple Development: [^"]*"' | head -1 | tr -d '"')
if [ -n "$IDENTITY" ]; then
  codesign --force --options runtime --sign "$IDENTITY" "$APP/Contents/Frameworks/libopus.0.dylib"
  codesign --force --options runtime --sign "$IDENTITY" "$APP/Contents/Resources/FireTVRemoteMicrophone.driver"
  codesign --force --options runtime --sign "$IDENTITY" "$APP/Contents/MacOS/FireTVHelper"
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP" 2>/dev/null \
    || codesign --force --options runtime --sign "$IDENTITY" "$APP"
  echo "signed with: $IDENTITY"
else
  codesign --force --sign - "$APP/Contents/Frameworks/libopus.0.dylib" "$APP/Contents/Resources/FireTVRemoteMicrophone.driver" "$APP/Contents/MacOS/FireTVHelper"
  codesign --force --sign - "$APP" && echo "signed ad-hoc (permissions reset on every rebuild)"
fi
echo "built $APP"
