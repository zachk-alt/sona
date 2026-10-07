#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/cue-playback/module-cache
clang -fobjc-arc -fmodules -c Sources/SonaObjC/SonaObjC.m -I Sources/SonaObjC/include -o .build/cue-playback/SonaObjC.o
swiftc -swift-version 5 -D CUE_PLAYBACK_TESTS -module-cache-path .build/cue-playback/module-cache \
  -I Sources/SonaObjC/include .build/cue-playback/SonaObjC.o \
  Sources/Murmur/FrameworkException.swift Sources/Murmur/Cue.swift Tests/CuePlaybackTests.swift -o .build/cue-playback/tests
.build/cue-playback/tests
