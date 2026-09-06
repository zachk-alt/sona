# Privacy

Sona has no account, telemetry endpoint or transcript history service. Microphone audio is captured only for an active dictation. Mac uses Apple's on-device Speech framework; Windows uses local Whisper. Speech assets and runtime dependencies require an initial network download.

Raw recordings and dictation results are held in memory. A result that cannot be inserted safely remains in memory for explicit copying. The operating system may page process memory or include it in a crash dump; this is not a guarantee of secure memory erasure.

Optional AI cleanup sends transcript text and configured vocabulary to the selected provider. CLI routes use existing supported CLI authentication and disable tools, hooks and session persistence. API routes use a named environment variable and a single tool-free request. Provider retention, billing, organization policies and account limits still apply. Select None or turn cleanup off to avoid AI requests.

Sona monitors the configured shortcut while running. It does not keep a keyboard history. Nonmodifier shortcut capture requires keyboard events to identify that chosen key. Ordinary text events are not logged. Accessibility/UI automation identifies the focused destination so Sona can refuse insertion after a focus change.

Automatic insertion temporarily uses the clipboard. Sona restores its prior contents only if the clipboard has not been changed by another action. Clipboard managers and the receiving app can retain inserted text independently. Explicit Copy recovery leaves the result on the clipboard intentionally.

Private configuration lives in the user's home/profile directory, outside the repository. Diagnostic logs contain status, counts and generic failure categories, not transcript or credential text. No personal developer configuration, AI credentials or recording media is distributed in this repository.
