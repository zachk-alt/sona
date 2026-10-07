#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/tests .build/module-cache
swiftc -module-cache-path .build/module-cache Sources/Murmur/Config.swift Sources/Murmur/HotKeyBinding.swift Sources/Murmur/FocusedElement.swift Sources/Murmur/SelectionSnapshot.swift Sources/Murmur/CorrectionObservation.swift Tests/FeatureSafetyTests.swift -o .build/tests/features
.build/tests/features
swiftc -module-cache-path .build/module-cache Sources/Murmur/FocusedElement.swift Sources/Murmur/TextInserter.swift Tests/macos-insertion.swift -o .build/tests/insertion
.build/tests/insertion
node_path="$(command -v node)"
swiftc -module-cache-path .build/module-cache Sources/Murmur/Config.swift Sources/Murmur/HotKeyBinding.swift Sources/Murmur/Cleanup/CleanupService.swift Sources/Murmur/Cleanup/BridgeCleanupService.swift Sources/Murmur/AssistantConversation.swift Sources/Murmur/Cleanup/BridgeOperations.swift Tests/BridgeOperationTests.swift -o .build/tests/operations
.build/tests/operations "$node_path" "$PWD/Tests/fake-operations.mjs"
swiftc -module-cache-path .build/module-cache Sources/Murmur/AssistantCaptureDeadline.swift Sources/Murmur/AssistantConversation.swift Tests/AssistantDeadlineTests.swift -o .build/tests/assistant-deadline
.build/tests/assistant-deadline
