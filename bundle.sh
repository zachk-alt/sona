#!/bin/bash
# Assemble and sign Sona, preserving Murmur's existing app identity.
set -euo pipefail
cd "$(dirname "$0")"

if [ "${1:-}" != "--no-install" ] && [ ! -w /Applications ]; then
  echo 'This account cannot write to /Applications. Ask an administrator to run the local installer; Sona does not change system permissions.' >&2
  exit 1
fi
swift build -c release
SONA_NODE_ROOT=$(bash scripts/bootstrap-node.sh)
STAGING=$(mktemp -d "${TMPDIR:-/tmp}/sona-build.XXXXXX")
APP="$STAGING/Sona.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Murmur "$APP/Contents/MacOS/Murmur"
cp Resources/*.png "$APP/Contents/Resources/"
mkdir -p "$APP/Contents/Resources/bridge/prompts" "$APP/Contents/Resources/runtime" "$APP/Contents/Resources/Sounds"
cp bridge/sona-cleanup.mjs bridge/cleanup.mjs "$APP/Contents/Resources/bridge/"
cp bridge/prompts/*.txt "$APP/Contents/Resources/bridge/prompts/"
cp "$SONA_NODE_ROOT/bin/node" "$APP/Contents/Resources/runtime/node"
cp "$SONA_NODE_ROOT/LICENSE" "$APP/Contents/Resources/runtime/NODE-LICENSE.txt"
cp Resources/Sounds/*.wav "$APP/Contents/Resources/Sounds/"
cp LICENSE "$APP/Contents/Resources/SONA-LICENSE.txt"

# Build the macOS app icon from the exact user-supplied Sona artwork.
# Keep the menu bar resources at their original sizes.
ICONSET="$STAGING/Sona.iconset"
mkdir -p "$ICONSET"
for ICON_SIZE in 16 32 128 256 512; do
  ICON_RETINA_SIZE=$((ICON_SIZE * 2))
  sips -s format png -z "$ICON_SIZE" "$ICON_SIZE" Resources/SonaAppIcon.png \
    --out "$ICONSET/icon_${ICON_SIZE}x${ICON_SIZE}.png" >/dev/null
  sips -s format png -z "$ICON_RETINA_SIZE" "$ICON_RETINA_SIZE" Resources/SonaAppIcon.png \
    --out "$ICONSET/icon_${ICON_SIZE}x${ICON_SIZE}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/Sona.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Sona</string>
  <key>CFBundleDisplayName</key><string>Sona</string>
  <key>CFBundleIdentifier</key><string>dev.murmur.Murmur</string>
  <key>CFBundleExecutable</key><string>Murmur</string>
  <key>CFBundleIconFile</key><string>Sona.icns</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.2.0</string>
  <key>CFBundleVersion</key><string>2</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSUIElement</key><true/>
  <key>NSMicrophoneUsageDescription</key>
  <string>Sona records when you invoke your chosen shortcut, transcribes on this Mac, and inserts your dictation into your text field.</string>
</dict>
</plist>
PLIST

# Keep the original certificate and identifier so rebuilds retain permissions.
if ! security find-identity -p codesigning 2>/dev/null | grep -q "Murmur Dev"; then
  echo "No 'Murmur Dev' signing identity. Run ./make-signing-cert.sh once."
  exit 1
fi
codesign --force --sign "Murmur Dev" "$APP/Contents/Resources/runtime/node"
codesign --force --sign "Murmur Dev" --identifier dev.murmur.Murmur "$APP"
codesign --verify --strict "$APP"
echo "built $APP"
if [ "${1:-}" = "--no-install" ]; then
  exit 0
fi

# Stop only this app, normally. Never interrupt another app or force termination.
cat > "$STAGING/stop.swift" <<'SWIFT'
import AppKit
let paths = ["/Applications/Murmur.app", "/Applications/Sona.app"]
for app in NSRunningApplication.runningApplications(withBundleIdentifier: "dev.murmur.Murmur") {
    guard let path = app.bundleURL?.standardizedFileURL.path, paths.contains(path) else { continue }
    guard app.terminate() else { exit(1) }
    let deadline = Date(timeIntervalSinceNow: 8)
    while !app.isTerminated && Date() < deadline {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
    }
    guard app.isTerminated else { exit(2) }
}
SWIFT
swiftc "$STAGING/stop.swift" -o "$STAGING/stop"

python3 - "$APP" "$STAGING/stop" <<'PY'
from pathlib import Path
import os
import plistlib
import subprocess
import sys

stage = Path(sys.argv[1])
installed = Path('/Applications/Sona.app')
old_paths = [installed, Path('/Applications/Murmur.app')]
backups = []

def verify(bundle):
    subprocess.run(['codesign', '--verify', '--strict', str(bundle)], check=True)

def requirement(bundle):
    result = subprocess.run(['codesign', '-d', '-r-', str(bundle)], check=True, capture_output=True, text=True)
    return next(line for line in (result.stdout + result.stderr).splitlines() if line.startswith('designated =>'))

verify(stage)
new_requirement = requirement(stage)
for old in old_paths:
    if not old.exists():
        continue
    info = plistlib.loads((old / 'Contents/Info.plist').read_bytes())
    if info.get('CFBundleIdentifier') != 'dev.murmur.Murmur':
        raise RuntimeError(f'Refusing to replace a different app at {old}')
    verify(old)
    if requirement(old) != new_requirement:
        raise RuntimeError('Signing identity changed; existing app was left in place')

subprocess.run([sys.argv[2]], check=True)
try:
    for old in old_paths:
        if old.exists():
            backup = stage.parent / ('Previous-' + old.name)
            os.rename(old, backup)
            backups.append((old, backup))
    os.rename(stage, installed)
    verify(installed)
except BaseException:
    if installed.exists() and not stage.exists():
        os.rename(installed, stage)
    for old, backup in reversed(backups):
        os.rename(backup, old)
    raise

lsregister = '/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'
subprocess.run([lsregister, '-f', str(installed)], check=True)
print(f'installed {installed}')
for _, backup in backups:
    print(f'previous app retained at {backup}')
PY

# A rename must update an already-enabled login item's saved app location.
/Applications/Sona.app/Contents/MacOS/Murmur --refresh-login-item
echo "Sona is installed. First launch requests Microphone and Accessibility access if needed."
