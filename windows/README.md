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

Ordinary keys/chords use Windows `RegisterHotKey` with repeat suppression. Modifier-only mode uses a low-level callback that compares the selected modifier and retains only its pressed state and a boolean indicating chord use. Other key identities and typed text are never stored or logged. The callback passes normal modifier/chord behavior through.

The recording and processing panel is a native WPF window with nonactivating Win32 styles, a waveform, a Windows backdrop where available, the supplied Sona mark, and the original Sona sound cues. Windows' backdrop and accessibility settings control its appearance. It does not steal focus from the target field.

Automatic paste requires the same foreground window, process, focused child, and UI Automation element as at recording start. Password fields, noneditable controls, unavailable UI Automation targets, changed focus, held modifiers, or blocked input are refused. Sona never brings an old app back to the front. The transcript then remains available through **Copy last dictation** or **Review last dictation** in the tray menu. Selection replacement follows the target app's normal paste behavior.

The clipboard is eagerly snapshotted before use and restored after a short paste interval, only if no other app or user has changed it in the meantime. Rich clipboard formats that cannot be safely snapshotted cause automatic paste to be refused. Windows clipboard history/cloud hints are disabled for the temporary payload. Apps running as administrator can block input from a normal Sona process. Use manual copying for those targets. As with normal keyboard paste, Windows does not provide an atomic focus-and-paste API or a universal delivery acknowledgment.

## Privacy and AI configuration

Local settings and the verified model live in `%LOCALAPPDATA%\Sona`:

- `settings.json`: selected shortcut, device, language, startup and cleanup preferences.
- `ai.json`: shared bridge configuration, model choice, and vocabulary.
- `models\ggml-base.bin`: local speech model.

Recordings and the last transcript are held in memory. Sona does not write dictation history. Explicit manual copying changes the clipboard normally. Cleanup is enabled for new setups and can be turned off in settings. Auto selection only uses an installed supported CLI and falls back to the raw transcript when none is available. With cleanup on, the transcript is sent to the configured AI provider; account limits or API charges still apply. Existing CLI sign-in stays with that CLI. API credentials must be supplied via the provider's environment variable, not copied into Sona configuration.

Auto selection uses supported installed Claude/Codex CLIs. **Gemini CLI (existing login)** is an explicit selection using provider `gemini-cli` and the cached login of an already installed Gemini CLI; Auto does not select it. **Gemini API** keeps provider `gemini` and uses the configured API key environment variable. These are separate choices. Sona does not install Gemini CLI or run a sign-in flow. Gemini CLI requires the audited published version `0.58.0` and Node 24+; the installer includes a compatible Node runtime. For Gemini CLI, `economy` selects `gemini-3.1-flash-lite`; other models are currently refused. Gemini CLI can retain local session history in its own cache, under its normal retention settings. Other providers use their own bridge-defined lightweight default. You can also enter an explicit supported model ID. Other configured API providers use the shared bridge's supported API routes. Open **AI configuration** for endpoint, executable, argument, API key environment-variable name, vocabulary, or advanced options. Changing provider in settings clears old transport selectors so they cannot carry into another provider; saving the same provider preserves them. See `bridge/README.md` in the source repository for the current provider matrix. A missing Node binary, bridge failure, empty result, or timeout preserves the original transcript. The subprocess uses stdin, bounded output, no shell, and a 35-second outer deadline.

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
