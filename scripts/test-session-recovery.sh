#!/usr/bin/env bash
# Drives real AppState sessions with a fake speech engine, microphone and cues:
# stalls at every stage must return Sona to ready. Shows the menu bar icon and
# the recording panel briefly; never records, plays sound or calls an AI.
set -euo pipefail
cd "$(dirname "$0")/.."
out=.build/session-recovery
mkdir -p "$out/module-cache"
# Same sources as the app target: everything but main.swift and the files
# Package.swift excludes.
excluded=$(sed -n '/exclude: \[/,/\]/p' Package.swift | grep -o '"[^"]*\.swift"' | tr -d '"')
sources=()
while IFS= read -r file; do
  name=$(basename "$file")
  [[ "$name" == main.swift ]] && continue
  grep -qx "$name" <<< "$excluded" && continue
  sources+=("$file")
done < <(find Sources/Murmur -name '*.swift' | sort)
clang -fobjc-arc -fmodules -c Sources/SonaObjC/SonaObjC.m -I Sources/SonaObjC/include -o "$out/SonaObjC.o"
swiftc -swift-version 5 -D SESSION_RECOVERY_TESTS -module-cache-path "$out/module-cache" \
  -I Sources/SonaObjC/include "$out/SonaObjC.o" "${sources[@]}" Tests/SessionRecoveryTests.swift -o "$out/tests"
"$out/tests"
