#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/assistant-window-policy/module-cache
swiftc -swift-version 5 -module-cache-path .build/assistant-window-policy/module-cache \
  Sources/Murmur/AssistantWindowPolicy.swift scripts/AssistantWindowPolicyTests.swift \
  -o .build/assistant-window-policy/tests
.build/assistant-window-policy/tests
