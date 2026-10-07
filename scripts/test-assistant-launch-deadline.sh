#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/assistant-launch-deadline/module-cache
swiftc -swift-version 5 -module-cache-path .build/assistant-launch-deadline/module-cache \
  Sources/Murmur/AssistantCaptureDeadline.swift Sources/Murmur/AssistantLaunchDispatch.swift \
  scripts/AssistantLaunchDeadlineTests.swift \
  -o .build/assistant-launch-deadline/tests
.build/assistant-launch-deadline/tests
