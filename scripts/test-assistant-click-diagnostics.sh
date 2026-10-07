#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/assistant-click-diagnostics/module-cache
swiftc -swift-version 5 -module-cache-path .build/assistant-click-diagnostics/module-cache \
  Sources/Murmur/AssistantClickDiagnostics.swift scripts/AssistantClickDiagnosticsTests.swift \
  -o .build/assistant-click-diagnostics/tests
.build/assistant-click-diagnostics/tests
swiftc -swift-version 5 -module-cache-path .build/assistant-click-diagnostics/module-cache \
  Sources/Murmur/AssistantSemanticSearch.swift Sources/Murmur/AssistantAXReadPolicy.swift \
  scripts/AssistantSemanticSearchTests.swift \
  -o .build/assistant-click-diagnostics/search-tests
.build/assistant-click-diagnostics/search-tests
