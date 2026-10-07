#!/usr/bin/env bash
# Real unwrapped Objective-C exceptions in child processes: a wedged main queue
# is detected, a healthy one is left alone, and an aborting raise runs Sona's
# relaunch handler first. Nothing appears on screen and nothing is relaunched.
set -euo pipefail
cd "$(dirname "$0")/.."
out=.build/exception-recovery
mkdir -p "$out/module-cache"
swiftc -swift-version 5 -D SONA_TEST_LOG -module-cache-path "$out/module-cache" \
  Sources/Murmur/Log.swift Sources/Murmur/ExceptionRecovery.swift Tests/ExceptionRecoveryTests.swift -o "$out/tests"
"$out/tests"
