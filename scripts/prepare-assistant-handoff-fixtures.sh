#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
test "$#" -eq 1 || { echo "Usage: bash scripts/prepare-assistant-handoff-fixtures.sh ABSOLUTE_OUTPUT_DIRECTORY" >&2; exit 2; }
case "$1" in /*) fixture_root="$1";; *) echo "Output directory must be absolute" >&2; exit 2;; esac
mkdir -p "$fixture_root" .build/assistant-handoff-fixtures/module-cache
swiftc -parse-as-library -swift-version 5 -module-cache-path .build/assistant-handoff-fixtures/module-cache \
  scripts/AssistantHandoffFixture.swift -o .build/assistant-handoff-fixtures/AssistantHandoffFixture
for role in origin target; do
  fixture_app="$fixture_root/SonaHandoff-$role.app"
  mkdir -p "$fixture_app/Contents/MacOS"
  cp .build/assistant-handoff-fixtures/AssistantHandoffFixture "$fixture_app/Contents/MacOS/AssistantHandoffFixture"
  cat > "$fixture_app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.sona.qa.$role</string>
<key>CFBundleName</key><string>Sona Handoff $role Fixture</string>
<key>CFBundleExecutable</key><string>AssistantHandoffFixture</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>26.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
  /usr/bin/codesign --force --sign - "$fixture_app"
  /usr/bin/codesign --verify --strict "$fixture_app"
done
echo "Prepared two distinct signed fixtures. Neither app has been launched."
