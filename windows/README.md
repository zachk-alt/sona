# Sona for Windows

A native Windows tray dictation client. Tap your chosen shortcut to record, tap again to finish, and Sona transcribes locally with Whisper. Optional cleanup uses the shared Sona AI bridge and an account or API configuration you choose.

This release targets **Windows 11 x64**. It does not support Windows 10, Windows on ARM, or UWP/mobile. The Windows app is separate from the macOS AppKit client.

## Install

Download `install-windows.ps1` from a published [Sona release](https://github.com/zachk-alt/sona/releases/latest), inspect it, then run it in PowerShell:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\install-windows.ps1
```

This only changes execution policy for this process. The script verifies the release ZIP checksum, installs Sona under `%LOCALAPPDATA%\Programs\Sona`, creates a Start menu shortcut, and downloads a private, SHA256-verified Node runtime for the AI bridge. It installs the signed Microsoft Visual C++ redistributable if needed; Windows may show its normal administrator prompt. No global Node/npm or .NET installation is needed to run Sona.

For an already downloaded package:

```powershell
.\install-windows.ps1 -PackagePath .\Sona-windows-x64.zip -Sha256 '<hash from trusted SHA256SUMS.txt>'
```

First launch lets you select a keyboard shortcut and microphone, then downloads the multilingual Whisper base model (147,951,465 bytes). The model URL is pinned to a source revision and its SHA256 is checked before use. Cancel or retry the download in setup. Speech recognition works offline after setup. Optional remote AI cleanup requires its own connection.

## Microphone access

In **Settings > Privacy & security > Microphone**, enable **Microphone access** and **Let desktop apps access your microphone**. Windows desktop apps do not always get a separate app-specific prompt. Sona opens the microphone only during a recording and uses the Windows communications input by default. A selected device can be changed in Sona settings. See [Microsoft's microphone permission guide](https://support.microsoft.com/en-us/windows/privacy/turn-on-app-permissions-for-your-microphone-in-windows).

## Shortcuts and insertion

Choose a single key or a modifier chord in settings. The default is Ctrl + Alt + Space. A bare character key is reserved while Sona runs. Left/right Ctrl, Alt, or Shift can be selected as a single short tap. A modifier hold longer than 650 ms or a modifier combined with another key is ignored. F12 and the Windows key alone are reserved. Windows may reject an already registered chord; choose another when prompted.

Ordinary keys/chords remain reserved with Windows `RegisterHotKey`. Dictation keeps its existing repeat-suppressed trigger. For a modifier shortcut, the callback observes only the selected key and a boolean indicating chord use. It never stores or logs other key identities or typed text. Native modifier/chord behavior passes through.

The recording and processing panel is a native WPF window with nonactivating Win32 styles, a waveform, a Windows backdrop where available, the supplied Sona mark, and the original Sona sound cues. Windows' backdrop and accessibility settings control its appearance. It does not steal focus from the target field.

Automatic paste requires the same foreground window, process, focused child, and UI Automation element as at recording start. Password fields, noneditable controls, unavailable UI Automation targets, changed focus, held modifiers, or blocked input are refused. Sona never brings an old app back to the front. The transcript then remains available through **Copy last dictation** or **Review last dictation** in the tray menu. Selection replacement follows the target app's normal paste behavior.

The clipboard is eagerly snapshotted before use and restored after a short paste interval, only if no other app or user has changed it in the meantime. Rich clipboard formats that cannot be safely snapshotted cause automatic paste to be refused. Windows clipboard history/cloud hints are disabled for the temporary payload. Apps running as administrator can block input from a normal Sona process. Use manual copying for those targets. As with normal keyboard paste, Windows does not provide an atomic focus-and-paste API or a universal delivery acknowledgment.

## Privacy and AI configuration

Local settings and the verified model live in `%LOCALAPPDATA%\Sona`:

- `settings.json`: selected shortcut, device, language, startup and cleanup preferences.
- `ai.json`: shared bridge configuration, vocabulary, and snippets.
- `models\ggml-base.bin`: local speech model.

Recordings and the last transcript are held in memory. Sona does not write dictation history. Explicit manual copying changes the clipboard normally. Cleanup is enabled for new setups and can be turned off in settings. Auto selection only uses an installed supported CLI and falls back to the raw transcript when none is available. With cleanup on, the transcript is sent to the configured AI provider; account limits or API charges still apply. Existing CLI sign-in stays with that CLI. API credentials must be supplied via the provider's environment variable, not copied into Sona configuration.

Auto selection uses supported installed Claude/Codex CLIs. The bridge enforces a fixed economical preset and no local session history. Dictation and snippet setup use the fixed economical preset. Gemini CLI and Custom remain identifiable in old settings but are blocked under this policy; Sona never switches a selected provider or runs a sign-in flow. Gemini API remains a separate supported API route. Open **AI configuration** for endpoint, executable, argument or API key environment-variable names. Changing provider clears old transport selectors; saving the same provider preserves them. See `bridge/README.md` for the current provider matrix. A missing Node binary, bridge failure, empty result or timeout preserves the native raw dictation. The subprocess uses stdin, bounded output, no shell and a 35-second outer deadline.

Tray actions let you cancel, review/copy the most recent result, open settings, or quit. Recording automatically finishes at 120 seconds by default (5 to 300 seconds can be set in `settings.json`). Startup registration is opt-in and uses the current user's Run key.

## Build and validation

Install the [.NET 8 SDK](https://dotnet.microsoft.com/download/dotnet/8.0), then from the repository root:

```powershell
.\windows\scripts\build.ps1
```

The result is a self-contained single-file managed executable with native Whisper libraries, the bridge, and sounds as required sidecars. Keep the ZIP contents together when installing. Whisper's custom native loader needs its `runtimes/` layout preserved. Native CPU and NoAVX fallback packages are pinned to 1.9.1. NAudio.Wasapi is pinned to the .NET 8-compatible 2.4.0 line. No CUDA or GPU setup is required.

The core executable tests run on macOS/Linux/Windows. A Windows-only smoke test is available:

```powershell
.\windows\artifacts\publish\Sona.exe --self-test .\windows-selftest.json --fixture .\windows\tests\Fixtures\jfk.wav
```

It downloads the verified model, transcribes the public JFK fixture, runs the bridge in passthrough mode, and exercises only its own test window with synthetic keys and a temporary clipboard sentinel. It never opens a microphone or authenticates an AI account. If an interactive desktop cannot be activated, its report explicitly marks GUI checks skipped. CI runs this command and uploads the report with the build artifacts.

A successful cross-compile is not Windows runtime verification. Before calling a release fully tested, inspect the Windows CI report and complete `docs/MANUAL-TESTS.md` on a Windows 11 computer with a microphone and real target apps.

## License

Sona's source and original assets use the repository `LICENSE`, included in the Windows package as `SONA-LICENSE.txt`. It permits use and private edits under its terms and restricts redistribution. The separate third-party licenses in `licenses/` remain unchanged.

## Dictation and personal phrases

Sona has one configurable dictation shortcut. The former second shortcut, selected-text instruction rewriting, screen questions and temporary chat are removed. Legacy `commandShortcut` and `assistant` fields remain harmless saved data and cannot register another shortcut, read the screen or block valid dictation settings from loading. There is no Assistant model picker or follow-up hold gesture.

Vocabulary and snippets have native editors in Settings and share `ai.json` with the provider configuration. Snippets expand literally before optional AI cleanup, including when cleanup is disabled or provider `none` is selected. The bridge owns longest-match, boundary and whitespace rules. Vocabulary guides cleanup and does not retrain Whisper. Dictation and snippet setup use the bridge's fixed economical preset; their saved model overrides are ignored. Gemini CLI and Custom are unavailable under the current no-local-session-history and preset policy.

Setup assistance runs only when you click Suggest after entering context and saving a supported provider. It does not inspect apps or your documents. Each proposal starts unchecked, is reviewed before addition to the editor, and is persisted only when you save. Manual snippet editing always remains available.

## Optional correction suggestions

`autoAddToDictionary` defaults to false. While false, no correction helper, subscriptions or extra correction UIA reads are created. When enabled, the first supported path is an initially empty, editable plain-text field and a single-line ASCII dictation of at most 4096 characters. Sona verifies the entire inserted span. For at most 15 seconds, select one whole existing alphabetic word and replace it using alphabetic keypresses, then pause for at least 500 ms. Backspace, punctuation, paste, navigation and later mouse clicks are outside this first capability and stop learning. A windowless helper witnesses selection metadata before forwarding input and only then considers a changed-text read. It does not read adjacent text or collect independent typing.

Outside typing, navigation, paste, focus changes, unwitnessed programmatic changes, unknown ranges, a new recording or disabling the option stop observation. The parent enforces the deadline by terminating the helper process, including a hung UIA provider. Unsupported fields and non-ASCII/multiline learning are skipped; ordinary dictation remains available. Only a possible word replacement is offered for review. Adding the replacement to vocabulary requires explicit confirmation. No document history or silent dictionary writes are made.

These new native Windows paths require the current Windows CI feature checks and real Windows keyboard/layout testing before being described as runtime-verified. A Mac cross-build alone is not that verification.
