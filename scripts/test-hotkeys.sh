#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/tests .build/module-cache
swiftc -module-cache-path .build/module-cache Sources/Murmur/Config.swift Sources/Murmur/HotKeyBinding.swift Sources/Murmur/HotKeyRouter.swift Tests/HotKeyTests.swift -o .build/tests/hotkeys
.build/tests/hotkeys
