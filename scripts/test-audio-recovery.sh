#!/usr/bin/env bash
# Local check with the real microphone: a busy or vanishing microphone must
# leave Sona able to take the next press. Holds the mic exclusively from a
# child process for about two and a half seconds in total. Skips without a
# microphone or without microphone permission for the terminal.
set -euo pipefail
cd "$(dirname "$0")/.."
out=.build/audio-recovery
mkdir -p "$out/module-cache"
clang -fobjc-arc -fmodules -c Sources/SonaObjC/SonaObjC.m -I Sources/SonaObjC/include -o "$out/SonaObjC.o"
swiftc -swift-version 5 -D SONA_TEST_LOG -module-cache-path "$out/module-cache" \
  -I Sources/SonaObjC/include "$out/SonaObjC.o" \
  Sources/Murmur/FrameworkException.swift Sources/Murmur/Log.swift Sources/Murmur/Transcriber.swift \
  Sources/Murmur/AudioCapture.swift Tests/AudioRecoveryTests.swift -o "$out/tests"
"$out/tests"
