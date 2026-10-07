#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/assistant-wait/module-cache
swiftc -swift-version 5 -module-cache-path .build/assistant-wait/module-cache \
  Sources/Murmur/AssistantWait.swift scripts/AssistantWaitTests.swift \
  -o .build/assistant-wait/tests
.build/assistant-wait/tests
