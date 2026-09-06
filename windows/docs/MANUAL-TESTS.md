# Windows release checks

Record the Windows version, CPU, microphone, build SHA, result, and any skipped case. These checks require a real Windows machine and cannot be replaced by a Mac cross-compile.

1. Install on a clean Windows 11 x64 user account with no .NET or Node. Verify checksum/signature errors stop setup, VC runtime preparation succeeds, the Start menu shortcut uses the supplied mark, and Sona opens setup. Confirm it requests no provider credential.
2. Cancel a partially downloaded speech model, retry, and verify its pinned hash. Restart offline and verify the model is reused.
3. Disable desktop microphone permission. Start a dictation and verify recovery guidance and no insertion. Enable it, choose a microphone, and record two consecutive phrases. Unplug a device during recording and verify clean recovery.
4. Choose Ctrl + Alt + Space, an unused bare key, Right Ctrl, and Right Shift. Tap to start/stop, hold the modifier, and use it in ordinary shortcuts. Verify no accidental toggle from repeats or normal chords. Reject a conflicting Windows shortcut and retry another choice.
5. Dictate into Notepad, a browser textarea, and an Electron editor. Verify the panel never activates, processing appears before text, the waveform tracks speech, both cues play, text replaces a selection normally, and the panel dismisses.
6. Change app, change field in the same app, focus a password box, or switch to an administrator window while processing. Verify no automatic insertion and the correct last transcript remains manually copyable.
7. Preload the clipboard with text, HTML, an image, and a file list separately. Verify successful ordinary paste restores the original. If a format cannot be safely copied, verify paste is refused. Copy something else while processing and while the temporary paste payload is active; verify newer clipboard content is not overwritten.
8. Start a long dictation, cancel from the tray, and test automatic duration stop. Cancel during transcription and AI cleanup. Quit during each state. Verify no stray microphone use or later paste.
9. With cleanup enabled, test a signed-in supported CLI, a missing executable, signed-out CLI, malformed AI config, API error, empty output, oversized output, and timeout. Verify original text is retained and secrets do not appear in Sona files. Explicitly assess the selected provider's own billing/session behavior.
10. Check 100%, 150%, and 200% DPI across multiple monitors, Windows dark/light appearance, transparency off, screen reader navigation, keyboard-only setup, and hidden/overflowed tray placement. Verify readable panel placement and accessible controls.
11. Enable and disable sign-in startup. Upgrade from an earlier installed build and verify settings/model retention. Check that the installer keeps the previous app version for recovery and never modifies user AI CLI credentials.
