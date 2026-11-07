#!/bin/sh
# Installs/repairs the Fire TV Remote Microphone HAL driver. Run as root.
# $1 = path to FireTVRemoteMicrophone.driver (source bundle)
set -e
SRC="$1"
DST="/Library/Audio/Plug-Ins/HAL/FireTVRemoteMicrophone.driver"
[ -d "$SRC" ] || { echo "driver source not found: $SRC" >&2; exit 2; }
mkdir -p /Library/Audio/Plug-Ins/HAL
# Never follow a symlink an attacker may have planted at DST.
if [ -L "$DST" ]; then rm -f "$DST"; fi
rm -rf "$DST"
cp -R "$SRC" "$DST"
chown -R root:wheel "$DST"
chmod -R go-w "$DST"
# Protect against symlink planting in the world-writable shared dir.
if [ -L /Users/Shared/FireTVRemoteStudio ]; then rm -f /Users/Shared/FireTVRemoteStudio; fi
mkdir -p /Users/Shared/FireTVRemoteStudio
chmod 1777 /Users/Shared/FireTVRemoteStudio
# coreaudiod is relaunched by launchd; this is the documented way to load a new HAL plug-in.
killall coreaudiod 2>/dev/null || true
echo "installed $DST"
