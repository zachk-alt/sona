# Retired Assistant feature

The second shortcut, selected-text instruction rewriting, screen questions, temporary chat and Assistant model settings were removed on 2026-09-28. Their Windows UI, screenshot worker and action classes are excluded from compilation. Obsolete Assistant worker arguments exit immediately. The running app registers only the chosen dictation shortcut.

Old `commandShortcut` and `assistant` configuration fields are ignored. They cannot enable a second shortcut or prevent otherwise valid dictation settings from loading. The portable Core harness covers valid, malformed and conflicting legacy bindings. The owned Windows self-test verifies that the old command chord and Right Alt tap/hold do not invoke Sona, while the chosen dictation chord and modifier still work.

Run the Core harness, Windows build and the strict native gate in `MANUAL-TESTS.md`. Earlier Assistant validation is not evidence for the current build. This change has not yet been exercised on a real Windows desktop; report the actual current build/test results separately rather than reusing old counts.
