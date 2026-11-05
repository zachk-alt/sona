#!/usr/bin/env bash
# Pure checks of the Parakeet engine slot: engine choice, the Apple backup over
# the same audio, the pinned and hash-checked model download, the silence check
# and the "engine" config key. Fake engines and local file copies only: no
# microphone, network, speech model, window or AI. ParakeetTranscriber.swift
# (the only FluidAudio file) is not compiled here.
set -euo pipefail
cd "$(dirname "$0")/.."
out=.build/speech-engine
mkdir -p "$out/module-cache"
clang -fobjc-arc -fmodules -c Sources/SonaObjC/SonaObjC.m -I Sources/SonaObjC/include -o "$out/SonaObjC.o"
swiftc -swift-version 5 -D SONA_TEST_LOG -module-cache-path "$out/module-cache" \
  -I Sources/SonaObjC/include "$out/SonaObjC.o" \
  Sources/Murmur/FrameworkException.swift Sources/Murmur/Log.swift Sources/Murmur/Transcriber.swift \
  Sources/Murmur/Config.swift Sources/Murmur/HotKeyBinding.swift Sources/Murmur/SpeechActivity.swift \
  Sources/Murmur/ParakeetModelStore.swift Sources/Murmur/SpeechEngine.swift Sources/Murmur/ThirdPartyCredits.swift \
  Tests/SpeechEngineTests.swift -o "$out/tests"
"$out/tests"
