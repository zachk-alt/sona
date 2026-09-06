# Sona

Your voice, in your text field. Tap your chosen key, speak, then tap again to finish.

Sona is free, source-available dictation by Actual Intelligence Labs. Speech recognition runs on your computer. Optional AI cleanup uses an existing supported CLI account or an explicitly configured API provider. There is no Sona subscription. Your AI provider's account limits and API charges still apply.

**Mac:** macOS 26+, Apple silicon. **Windows:** Windows 11, x64.

## Install with your AI terminal

Give your coding assistant this repository URL:

```text
https://github.com/zachk-alt/sona
```

Ask it to read `AGENTS.md` and install Sona. It will ask which key or key combination you want, set an economy model for your selected provider, and prepare the platform dependencies. An assistant still needs to run the installer; simply pasting a URL into an ordinary shell does not execute it.

## Install yourself

### Mac

Apple Command Line Tools are sufficient. Full Xcode, Homebrew and preinstalled Whisper packages are not needed.

```sh
git clone https://github.com/zachk-alt/sona.git
cd sona
./install.sh
```

For an assistant or scripted installation, specify your choices:

```sh
./install.sh --hotkey right-command --provider claude
# Other examples: --hotkey option+space --provider codex
# Completely local: --hotkey f8 --provider none
```

The installer builds and installs `/Applications/Sona.app`, prepares a checksum-verified private Node runtime, and downloads Apple's speech assets if missing. It creates a local signing identity so updates preserve your Accessibility grant. Keychain may ask to let `codesign` use that identity. Grant **Microphone** and **Accessibility** when macOS asks. Sona does not request Input Monitoring. A missing Command Line Tools installation opens Apple's installer; finish it and rerun Sona's installer.

### Windows

Download `install-windows.ps1` from the [latest release](https://github.com/zachk-alt/sona/releases/latest), inspect it, then run it in PowerShell as your normal user:

```powershell
powershell -ExecutionPolicy Bypass -File .\install-windows.ps1
```

It downloads the matching release, checks its SHA-256, installs a private Node runtime, and prepares Microsoft's VC++ runtime when needed. The Microsoft runtime may request administrator approval. Sona itself installs for your user. The first-run window asks for your shortcut, microphone, language and AI provider, then downloads the verified local Whisper model (about 148 MB). Windows must allow desktop apps to use the microphone. See [Windows setup and validation](windows/README.md).

## Choose your AI connection

| Choice | Connection |
| --- | --- |
| Claude | Your installed, signed-in Claude Code CLI; Haiku economy default |
| ChatGPT / Codex | Your installed, signed-in Codex CLI; Luna economy default |
| Gemini CLI | Your installed, signed-in Gemini CLI, selected with `gemini-cli` |
| Gemini API, Grok, Kimi, OpenAI, Anthropic, OpenCode | Their API, using your own API environment variable |
| Custom | An OpenAI-compatible endpoint and explicit model ID, including a local server |
| None | Plain, local dictation with no AI request |

Automatic mode selects an installed Claude or Codex CLI. It never silently chooses a paid API. API accounts are separate from chat subscriptions. No app can turn one company's subscription into access to all companies' models. Sona does not extract credentials or install/login to AI clients on your behalf. Gemini CLI is a separate explicit choice, `gemini-cli`; the existing `gemini` choice continues to use the API. Grok has an official CLI, but this release uses its API while a separate CLI adapter is being verified.

The reviewed model catalog, environment variable names, request isolation and configuration schema live in [bridge/README.md](bridge/README.md). Economy is a fixed small or low-effort choice where available, not a live price optimizer. An unavailable model, timeout, invalid response or missing login falls back to the original local transcript. There is no automatic upgrade to a more expensive model.

## Updates

Sona does not auto-update or require installing a new Sona version to keep using the installed app. Update it when you choose. After initial model setup, plain speech recognition works locally. Optional AI cleanup still depends on your selected provider; if it becomes unavailable, Sona falls back to the local transcript. Operating-system compatibility and provider/model availability can change independently.

## Using Sona

- Tap your shortcut to start and tap again to finish. Mac also supports holding and releasing it.
- Change the shortcut from the Sona menu on Mac or Settings on Windows. A single letter reserves that key while Sona runs. Choose a chord or function key if you want to keep normal typing. Operating-system-reserved combinations cannot all be intercepted.
- Speak while the waveform is active. The orbit and loading wave run during processing. The panel remains through insertion and dismisses gently.
- Keep your original text field focused until insertion. If it changes, recover the result from the app's copy action rather than pasting into an unintended field.
- Select text before dictation to replace it. Sona does not submit or execute the resulting text.
- Disable cleanup at any time for fully local dictation. AI cleanup sends the transcript, not microphone audio, to the selected provider.

The Mac panel uses native appearance-aware materials and edge refraction without taking key focus. Accessibility appearance settings are respected. Windows has its own nonactivating panel.

## Settings and privacy

Mac settings: `~/.config/murmur/config.json`. Windows: `%LOCALAPPDATA%\Sona`, with provider settings in `ai.json`. The historic Mac bundle identifier and settings location remain to preserve existing permissions and preferences.

```json
{
  "hotkey": "right-command",
  "setupComplete": true,
  "cleanupEnabled": true,
  "ai": { "provider": "codex", "model": "economy", "timeoutMs": 12000 },
  "vocabulary": ["Sona"]
}
```

Optional API settings use `apiKeyEnv` for the name of an environment variable, never the credential itself. An app launched from Finder or Explorer may not inherit variables set only in a terminal. Launch it from the configured environment or configure your operating system's user environment, then restart it. Never commit your settings or keys.

Mac's Sound menu includes the Sona blend and installed system/instrument sounds. The blend loads Bottle and Purr from that Mac at runtime. Windows ships original synthesized companion sounds. Apple's sound files are not redistributed. The supplied Sona app icon is included on both platforms.

Sona keeps recordings and transcripts in memory rather than saving a history. Local status logs do not contain transcript text. AI providers have their own retention and account policies. Gemini CLI can also retain its own local session history; Sona does not copy or publish that history. Read [PRIVACY.md](PRIVACY.md) and [SECURITY.md](SECURITY.md).

## Build and check

```sh
swift build -c release
bash scripts/test-hotkeys.sh
node --test bridge/test/*.test.mjs
./bundle.sh --no-install
```

`bundle.sh` requires the local identity from `make-signing-cert.sh` and prepares the pinned Node runtime. The `--no-install` option leaves the signed app in a temporary build folder. Windows source build and test instructions are in [windows/README.md](windows/README.md).

```sh
.build/release/Murmur --panel 6
MURMUR_BACKDROP=1 .build/release/Murmur --panel 6
.build/release/Murmur --panel 8 --processing
.build/release/Murmur --prepare-speech
```

Preview modes use synthetic audio and do not open the microphone. `--doctor` reports the calling process's permissions; the running app's own status is authoritative. `--selftest` can exercise the Mac speech pipeline with a WAV file. CI checks both platform builds and shared cleanup behavior. Windows CI uses a public spoken fixture; microphone hardware and third-party application behavior still require the [manual checks](windows/docs/MANUAL-TESTS.md).

## License

Sona source and original assets use the [Sona Source-Available License](LICENSE). Use and private edits are allowed; publishing or redistributing copies or modified versions requires prior written permission. See [LICENSING.md](LICENSING.md) for the earlier MIT version and GitHub platform rights. Dependencies keep their own licenses. Their notices ship with the Windows package and bundled Node runtime. AI provider and operating-system trademarks belong to their respective owners; Sona is not affiliated with them.
