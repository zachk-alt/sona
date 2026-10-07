# Validation record

Implementation and cross-compilation were completed on macOS ARM64 with the Microsoft .NET 8.0.424 SDK installed inside the task workspace. No Windows microphone, hardware hotkey, real Windows target application, or authenticated AI account was exercised on that host.

Completed checks:

- WPF Release build succeeded with zero compiler warnings and errors.
- Self-contained `win-x64` single-file managed publish succeeded.
- All 36 cross-platform core checks passed: modifier/chord/repeat behavior, foreground/focus/process/password policy, clipboard sequence protection, first-run/corrupt configuration recovery, default-on cleanup and persisted opt-out, valid and corrupt download hashes, initial and mid-stream cancellation, and bounded subprocess success/empty/error/timeout/oversized-output fallback.
- Published executable and all eight Whisper CPU/NoAVX sidecars have valid x64 PE headers.
- Published package contains the runtime bridge files, prompt files, supplied icon, original start/stop cues, and dependency notices. Package inputs use an allowlist; test files, Mac compiler caches, and non-Windows Whisper binaries are excluded.
- The official JFK fixture SHA256 matches `59dfb9a4acb36fe2a2affc14bacbee2920ff435cb13cc314a08c13f66ba7860e`.
- Application icon source SHA256 matches `bffd5aefc54c9b0c1c714774d5ae660bdb874a8f3ea9d5fc671c016e07bc7c89`.

Windows runtime CI passed for source `3306f2610b428f2407bd90b077a65239d5ec8ea7` in [run 34006486400](https://github.com/zachk-alt/sona/actions/runs/34006486400), on Windows Server 2025 build 10.0.26100. The release still targets Windows 11 x64. The report records `status: passed` and `interactiveOutcome: passed`, with no skipped GUI checks.

The workflow installed the actual package using Windows PowerShell 5.1, including its private Node runtime. That installed application downloaded and verified the model, transcribed the full public JFK fixture with CPU Whisper, and preserved exact text through the bridge in provider-none mode. Its owned WPF window passed recording/processing overlay focus preservation, a synthetic registered shortcut, changed-field refusal, Unicode paste, clipboard restoration, and password refusal.

The earlier run 34005956643 passed speech and bridge checks but failed its first owned-field UI Automation capture. The updated bounded readiness handling and diagnostics passed on the first capture in 56 ms in the later run. The earlier failure's exact cause was not recorded, so this is not proof of a specific Windows permissions issue.

No physical microphone, hardware shortcut, elevated target app, or authenticated AI account was exercised by CI. The automated pass does not replace microphone and real-app checks in `MANUAL-TESTS.md`. Future reports distinguish `passed`, `partial`, and `failed`; unavailable owned-window checks are explicitly recorded as skipped and cannot count as full runtime verification.

The CI workflow builds and uploads artifacts only. It does not publish a GitHub release. The release owner must review results and publish the ZIP, installer, and trusted checksums.

The earlier Gemini CLI integration remains packaged for source compatibility, but the current feature update blocks Gemini CLI and Custom under the fixed-preset/no-local-session-history policy. Earlier CI evidence does not verify the new selection or observation features.

The current feature source cross-compiles on Mac, and its portable Core tests pass. New native owned-window checks are authored but have not been executed on this Mac. `scripts/assert-runtime-qa.ps1` requires an explicit complete interactive pass, including no-content-read assertions for outside typing and unwitnessed changes. Real Windows 11 layout, microphone and app checks remain required.

The current source removes the second shortcut and Assistant runtime. The earlier build and CI evidence above does not verify this change. Follow the current `MANUAL-TESTS.md` and strict native gate; do not claim Windows hardware validation based on a Mac cross-build.
