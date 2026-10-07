#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/assistant-accessibility-preparation/module-cache
swiftc -swift-version 5 -module-cache-path .build/assistant-accessibility-preparation/module-cache \
  Sources/Murmur/AssistantAccessibilityPreparation.swift scripts/AssistantAccessibilityPreparationTests.swift \
  -o .build/assistant-accessibility-preparation/tests
.build/assistant-accessibility-preparation/tests
