#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/cue-playback/module-cache
swiftc -swift-version 5 -D CUE_PLAYBACK_TESTS -module-cache-path .build/cue-playback/module-cache \
  Sources/Murmur/Cue.swift Tests/CuePlaybackTests.swift -o .build/cue-playback/tests
.build/cue-playback/tests
