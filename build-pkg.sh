#!/bin/zsh
# Builds dist/FireTVRemoteStudio.pkg: installs the app to /Applications and the HAL driver to
# /Library/Audio/Plug-Ins/HAL, then restarts coreaudiod. Signs with "Developer ID Installer" when present.
set -e
cd "$(dirname "$0")"
./build-app.sh
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' FireTVRemoteBridge.app/Contents/Info.plist)
rm -rf dist pkgroot && mkdir -p dist pkgroot/app/Applications pkgroot/driver/Library/Audio/Plug-Ins/HAL pkgroot/scripts
cp -R FireTVRemoteBridge.app "pkgroot/app/Applications/Fire TV Remote Studio.app"
cp -R hal/build/FireTVRemoteMicrophone.driver pkgroot/driver/Library/Audio/Plug-Ins/HAL/
cat > pkgroot/scripts/postinstall <<'POST'
#!/bin/sh
if [ -L /Users/Shared/FireTVRemoteStudio ]; then rm -f /Users/Shared/FireTVRemoteStudio; fi
mkdir -p /Users/Shared/FireTVRemoteStudio && chmod 1777 /Users/Shared/FireTVRemoteStudio
chown -R root:wheel /Library/Audio/Plug-Ins/HAL/FireTVRemoteMicrophone.driver
# make the newly installed HAL plug-in load now (launchd relaunches coreaudiod)
killall coreaudiod 2>/dev/null || true
# a helper from a previous version may still be resident: stop it so the new one loads on demand
launchctl kill TERM system/com.uaaa.firetv-remote-bridge.helper 2>/dev/null || true
exit 0
POST
chmod +x pkgroot/scripts/postinstall
pkgbuild --root pkgroot/app --install-location / --identifier com.uaaa.firetv-remote-studio.app --version "$VERSION" dist/app.pkg >/dev/null
pkgbuild --root pkgroot/driver --install-location / --scripts pkgroot/scripts --identifier com.uaaa.firetv-remote-studio.driver --version "$VERSION" dist/driver.pkg >/dev/null
cat > dist/distribution.xml <<DIST
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
  <title>Fire TV Remote Studio</title>
  <options customize="never" require-scripts="true" hostArchitectures="arm64,x86_64"/>
  <domains enable_localSystem="true"/>
  <welcome language="en" mime-type="text/plain">Installs the app that turns a Fire TV remote into a customizable input device for your Mac, plus the audio driver that exposes its built-in microphone as the macOS input device "Fire TV Remote Microphone".</welcome>
  <choices-outline><line choice="default"><line choice="app"/><line choice="driver"/></line></choices-outline>
  <choice id="default"/>
  <choice id="app" visible="false"><pkg-ref id="com.uaaa.firetv-remote-studio.app"/></choice>
  <choice id="driver" visible="false"><pkg-ref id="com.uaaa.firetv-remote-studio.driver"/></choice>
  <pkg-ref id="com.uaaa.firetv-remote-studio.app" version="$VERSION">app.pkg</pkg-ref>
  <pkg-ref id="com.uaaa.firetv-remote-studio.driver" version="$VERSION">driver.pkg</pkg-ref>
</installer-gui-script>
DIST
INST_ID=$(security find-identity -v 2>/dev/null | grep -o '"Developer ID Installer: [^"]*"' | head -1 | tr -d '"')
if [ -n "$INST_ID" ]; then
  productbuild --distribution dist/distribution.xml --package-path dist --sign "$INST_ID" dist/FireTVRemoteStudio.pkg
  echo "pkg signed with: $INST_ID"
else
  productbuild --distribution dist/distribution.xml --package-path dist dist/FireTVRemoteStudio.pkg
  echo "pkg is UNSIGNED (no 'Developer ID Installer' identity in keychain) — fine locally; needed for public distribution"
fi
rm -rf pkgroot dist/app.pkg dist/driver.pkg
ls -la dist/FireTVRemoteStudio.pkg
