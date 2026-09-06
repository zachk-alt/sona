#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/tests
swiftc Sources/Murmur/Config.swift Sources/Murmur/HotKeyBinding.swift Tests/HotKeyTests.swift -o .build/tests/hotkeys
.build/tests/hotkeys
