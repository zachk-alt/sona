#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/assistant-panel-placement/module-cache
swiftc -swift-version 5 -module-cache-path .build/assistant-panel-placement/module-cache \
  Sources/Murmur/AssistantPanelPlacement.swift scripts/AssistantPanelPlacementTests.swift \
  -o .build/assistant-panel-placement/tests
.build/assistant-panel-placement/tests
