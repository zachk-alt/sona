#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/assistant-capture-policy/module-cache
swiftc -swift-version 5 -module-cache-path .build/assistant-capture-policy/module-cache \
  Sources/Murmur/AssistantCapturePolicy.swift scripts/AssistantCapturePolicyTests.swift \
  -o .build/assistant-capture-policy/tests
.build/assistant-capture-policy/tests
