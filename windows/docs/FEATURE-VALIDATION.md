# Current feature scope

Sona is now dictation only. The second shortcut, Assistant settings, screen capture and conversation runtime have been removed from the Windows executable. See `ASSISTANT-VALIDATION.md` for the retirement boundary and `MANUAL-TESTS.md` for the updated native gate. Core tests include legacy configuration loading without another active shortcut.

The remainder of this file is historical implementation evidence, not a claim that those retired features still exist or that the current Windows build has been tested on hardware.

# Earlier Windows five-feature implementation validation

The feature source is implemented in `windows/` and was cross-built on macOS ARM64 with the existing Microsoft .NET 8.0.424 SDK and cached packages. No new dependency was introduced, provider account called, microphone opened, installed application changed, or release published.

Local results:

- 83 portable Core checks passed. These include shortcut policy, typed protocol failures, native-raw fallback, exact rewrite outer whitespace including FEFF, null/control validation, context-derived setup proposals, single dispatch, dictionary/snippet validation, inert/off and fake-clock learning deadlines, unknown-setting preservation, malformed-config refusal, transaction staging failure, downloader integrity and bounded subprocess failures.
- The self-contained Windows x64 publish completed with no warnings or errors.
- The local `Sona.exe` PE machine is AMD64.
- All packaged bridge modules, schemas and prompts match their source bytes. Original start/stop WAVs and `SONA-LICENSE.txt` also match exactly.
- The local publish inventory contains 37 files. A per-file size/hash manifest is generated in the ignored artifact directory.

Local evidence is in `windows/obj/feature-build-qa.json` and `windows/artifacts/feature-publish-manifest.json`. Build output is in `windows/artifacts/feature-publish/`. These generated files are not source release content.

Equivalent standard commands for the build host are:

```powershell
dotnet run --project windows/tests/Sona.Core.Tests/Sona.Core.Tests.csproj -c Release
dotnet publish windows/src/Sona.Windows/Sona.Windows.csproj -c Release -r win-x64 --self-contained true -p:EnableWindowsTargeting=true
```

On this Mac, the cached SDK's MSBuild entry point was used directly with its own `DOTNET_ROOT`, `DOTNET_HOST_PATH` and PATH. An offline NuGet config and existing package cache were used. This avoided an initial compiler-host resolution stall.

## Required native gate

The owned WPF tests first ran on Windows CI on 2026-10-06. They cover both registered shortcuts, nonactivating panels, disabled learning creating no worker, a witnessed word correction, outside/unwitnessed changes producing no extra content read, focus cancellation and actual 15-second helper termination. The installed test also exercises public-fixture Whisper and provider-none typed bridge behavior.

`windows/scripts/assert-runtime-qa.ps1` rejects `partial`, skipped GUI checks and missing new feature assertions. A successful cross-build does not satisfy this gate.

The exact-selection replacement and verified-empty selection probes belong to the retired selected-text command mode, whose only caller is not compiled into the app. On their first Windows run the exact-selection capture did not match, so they are now recorded as `retired_command_*` diagnostics and are not part of the gate.

Learning's initial capability is deliberately narrow: an initially empty supported plain-text field, a single-line ASCII insertion of at most 4096 characters, a whole existing alphabetic word selected and replaced with alphabetic keypresses, 500 ms settling and a hard 15-second deadline. There are no adjacent-text reads. Unsupported fields, unknown range movement, paste, navigation, outside typing, unwitnessed changes and non-ASCII/multiline learning are skipped or stopped. UIA event coalescing and live range affinity require the actual Windows tests.

Physical Right Alt/AltGr layout behavior, Windows 11 app compatibility, microphone hardware and elevated targets still require the separate manual checks. Right Alt command is restricted to standard US layouts and refuses menu activation; users can select another key or chord. Existing dictation/left Alt behavior is preserved.

The 83-check result above describes an earlier baseline. It does not verify the current dictation-only build.
