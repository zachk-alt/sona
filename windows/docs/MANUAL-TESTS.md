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

## Provider policy

Auto remains Claude/Codex only. Verify saved Gemini CLI and Custom selections are blocked without launching a process or switching providers. Gemini API remains the distinct `gemini` route. Saving the same provider preserves advanced selectors and unknown fields; switching providers clears previous transport selectors. Normal dictation and setup use the shared fixed economical preset. All routes retain the no-local-session-history policy. Missing login, unavailable executable, invalid response or timeout preserves raw dictation. Provider-account checks require explicit setup and are not claimed by the provider-none CI test.

## Feature update gate

Run `scripts/assert-runtime-qa.ps1 -Report PATH` after the installed app's `--self-test` with the public fixture. Partial/interactive skips fail the feature gate. The owned WPF tests cover complete guarded selection replacement, changed range refusal, verified-empty selection, no helper while learning is off, and content-read counters proving outside/unwitnessed edits do not trigger observation reads.

On actual Windows 11 hardware also test:

- The chosen dictation shortcut, conflicting registration rollback, same-shortcut finish and rapid tap/repeat. Upgrade with a valid, malformed or conflicting old `commandShortcut` and malformed `assistant` profile: dictation preferences still load, and no second hotkey is registered.
- With Right Ctrl selected for dictation, tap and hold the former Right Alt command key. No recording or panel should start. The former command chord must also remain available to other apps. German, Polish and US-International AltGr characters and left Alt keep native behavior.
- Ordinary dictated text pastes using native selection replacement in Notepad, Word and an Electron editor. Selected-text spoken instruction rewriting is not available.
- Dictionary/snippet add, edit, delete, CRLF signatures, literal expansion with cleanup on/off, unknown config fields, malformed config refusal and failed-save rollback.
- Explicit setup assistance with reviewed unchecked proposals; None and blocked providers must never be called, and failure must leave the manual editor unchanged.
- Opt-in learning in an initially empty plain TextBox, selected word replacement, pause, candidate review and dismissal. Append text outside the original word, navigate, paste, change fields, disable the setting or wait 15 seconds: no later content read or helper may remain. Verify the helper is terminated if its UIA provider stalls.

The current Mac cannot verify physical microphone capture, Windows UIA timing, keyboard layout/AltGr behavior, elevated target apps, or these native interaction checks.

## Dictation-only native gate

The strict report now requires `assistant_runtime_excluded`, `single_shortcut_api`, `retired_command_chord_inert`, `retired_right_alt_tap_inert`, `retired_right_alt_hold_inert`, `left_alt_does_not_invoke` and `dictation_modifier_tap_still_works`. The app assembly must omit the Assistant settings window, answer panel and screen-capture worker. Obsolete `--assistant-context`, `--assistant-context-test` and `--assistant-action` launches must exit without running a worker.

Old selection helper tests remain to protect shared insertion primitives and correction learning. They do not expose a command mode or second shortcut. No screenshot or conversation tests are required because those runtime features are removed.
