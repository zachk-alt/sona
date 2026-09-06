# Validation record

Implementation and cross-compilation were completed on macOS ARM64 with the Microsoft .NET 8.0.424 SDK installed inside the task workspace. No Windows microphone, hardware hotkey, real Windows target application, or authenticated AI account was exercised on that host.

Completed checks:

- WPF Release build succeeded with zero compiler warnings and errors.
- Self-contained `win-x64` single-file managed publish succeeded.
- All 34 cross-platform core checks passed: modifier/chord/repeat behavior, foreground/focus/process/password policy, clipboard sequence protection, first-run/corrupt configuration recovery, valid and corrupt download hashes, initial and mid-stream cancellation, and bounded subprocess success/empty/error/timeout/oversized-output fallback.
- Published executable and all eight Whisper CPU/NoAVX sidecars have valid x64 PE headers.
- Published package contains the runtime bridge files, prompt files, supplied icon, original start/stop cues, and dependency notices. Package inputs use an allowlist; test files, Mac compiler caches, and non-Windows Whisper binaries are excluded.
- The official JFK fixture SHA256 matches `59dfb9a4acb36fe2a2affc14bacbee2920ff435cb13cc314a08c13f66ba7860e`.
- Application icon source SHA256 matches `bffd5aefc54c9b0c1c714774d5ae660bdb874a8f3ea9d5fc671c016e07bc7c89`.

Windows runtime validation is pending the repository's Windows workflow. Its report distinguishes `passed`, `partial`, and `failed`; unavailable owned-window checks are explicitly recorded as skipped. A partial result must not be described as full Windows runtime verification. A full automated pass still does not replace microphone and real-app checks in `MANUAL-TESTS.md`.

The CI workflow builds and uploads artifacts only. It does not publish a GitHub release. The release owner must review results and publish the ZIP, installer, and trusted checksums.
