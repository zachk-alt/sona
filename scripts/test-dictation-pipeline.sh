#!/usr/bin/env bash
# Pure checks of the dictation pipeline: never-final transcript text, the
# sample-rate converter's quality and end-of-recording flush, and the text-free
# session diagnostics, the opt-in debug text log and the session metrics line.
# No microphone, speech engine, sound, window or AI.
set -euo pipefail
cd "$(dirname "$0")/.."
out=.build/dictation-pipeline
mkdir -p "$out/module-cache"
clang -fobjc-arc -fmodules -c Sources/SonaObjC/SonaObjC.m -I Sources/SonaObjC/include -o "$out/SonaObjC.o"
swiftc -swift-version 5 -D SONA_TEST_LOG -module-cache-path "$out/module-cache" \
  -I Sources/SonaObjC/include "$out/SonaObjC.o" \
  Sources/Murmur/FrameworkException.swift Sources/Murmur/Log.swift Sources/Murmur/Transcriber.swift \
  Sources/Murmur/AudioCapture.swift Sources/Murmur/DictationMetrics.swift Sources/Murmur/Config.swift \
  Sources/Murmur/HotKeyBinding.swift Sources/Murmur/DebugTextLog.swift Tests/DictationPipelineTests.swift -o "$out/tests"
"$out/tests"
