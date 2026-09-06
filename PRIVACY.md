# Privacy

Sona has no account, telemetry endpoint or transcript history service. Microphone audio is captured only for an active dictation. Mac uses Apple's on-device Speech framework; Windows uses local Whisper. Speech assets and runtime dependencies require an initial network download.

Sona holds raw recordings and dictation results in memory. A result that cannot be inserted safely remains in memory for explicit copying. The operating system may page process memory or include it in a crash dump; this is not a guarantee of secure memory erasure. An optional AI client may retain its own copy as described below.

Optional AI cleanup sends transcript text and configured vocabulary to the selected provider. CLI routes use existing supported CLI authentication with execution tools and hooks disabled. Claude and Codex routes disable session persistence. The explicitly selected Gemini CLI route can retain its own local session history in the Gemini user directory; Sona does not read, copy, publish or delete that history. API routes use a named environment variable and a single tool-free request. Provider retention, billing, organization policies and account limits still apply. Select None or turn cleanup off to avoid AI requests.

Sona monitors the configured shortcut while running. It does not keep a keyboard history. Nonmodifier shortcut capture requires keyboard events to identify that chosen key. Ordinary text events are not logged. Accessibility/UI automation identifies the focused destination so Sona can refuse insertion after a focus change.

During a Mac dictation session, a compatibility guard also observes mouse-down and key-down events in other applications and application activation changes. It retains a session identifier and activity revision, not typed characters, key identities, or mouse positions. The configured finish key is compared only inside the callback. This allows an editor with unavailable or coarse Accessibility data to receive a paste only while its PID, available window identity, and session activity remain unchanged. Known protected fields are refused. An inaccessible field's identity and protection status cannot be fully determined, so this fallback is weaker than exact field matching. The guard uses existing Accessibility access.

Automatic insertion temporarily uses the clipboard. Sona restores its prior contents only if the clipboard has not been changed by another action. Clipboard managers and the receiving app can retain inserted text independently. Explicit Copy recovery leaves the result on the clipboard intentionally.

Private configuration lives in the user's home/profile directory, outside the repository. Diagnostic logs contain status, counts and generic failure categories, not transcript or credential text. No personal developer configuration, AI credentials or recording media is distributed in this repository.
