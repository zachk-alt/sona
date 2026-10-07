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
| Gemini API, Grok, Kimi, OpenAI, Anthropic, OpenCode | Their API, using your own API environment variable |
| None | Plain, local dictation with no AI request |

Automatic mode selects an installed Claude or Codex CLI. It never silently chooses a paid API. API accounts are separate from chat subscriptions. No app can turn one company's subscription into access to all companies' models. Sona does not extract credentials or install/login to AI clients on your behalf. Grok uses its API; no supported isolated Grok CLI adapter is included.

The `gemini-cli` setting is retained for old configurations, but Sona refuses to send text through it because the reviewed CLI cannot disable its local session history. The separate `gemini` API remains available only when you explicitly configure it. Custom endpoints without a reviewed economy mapping are also refused. Stored model overrides are ignored in favor of the reviewed economy choice. These settings keep ordinary local dictation working and do not silently switch your provider.

The reviewed model catalog, environment variable names, request isolation and configuration schema live in [bridge/README.md](bridge/README.md). Dictation and saved-phrase setup use the reviewed economy choice, not a live price optimizer. An unavailable model, timeout, invalid response or missing login falls back to the original local transcript during dictation. There is no automatic upgrade to a more expensive model.

## Updates

Sona does not auto-update or require installing a new Sona version to keep using the installed app. Update it when you choose. After initial model setup, plain speech recognition works locally. Optional AI cleanup still depends on your selected provider; if it becomes unavailable, Sona falls back to the local transcript. Operating-system compatibility and provider/model availability can change independently.

## Using Sona

- Tap your shortcut to start and tap again to finish. Mac also supports holding and releasing it.
- Change the shortcut from the Sona menu on Mac or Settings on Windows. A single letter reserves that key while Sona runs. Choose a chord or function key if you want to keep normal typing. Operating-system-reserved combinations cannot all be intercepted.
- Speak while the waveform is active. The orbit and loading wave run during processing. The panel remains through insertion and dismisses gently.
- Keep your original text field focused until insertion. If it changes, recover the result from the app's copy action rather than pasting into an unintended field.
- Select text before dictation to replace it. Sona does not submit or execute the resulting text.
- Disable cleanup at any time for fully local dictation. Saved phrases still expand locally. AI cleanup sends text, not microphone audio, to the selected provider.

The Mac recording and loading panel appears over regular desktops, other apps in full-screen Spaces, and Stage Manager groups. It uses native appearance-aware materials and edge refraction without taking key focus. Accessibility appearance settings are respected. Windows has its own nonactivating panel.

If the Mac menu icon is missing or obscured, open Sona from Applications again to restore its visibility and open the existing menu, including Copy pending text and Quit. macOS can still obscure an icon when the menu bar is full. The recording panel uses a visible position on the active display if its menu anchor is unavailable or offscreen.

Sona now has **one dictation shortcut**. The second shortcut, selected-text instruction mode, screen questions and Assistant model settings have been removed. Old second-shortcut settings are ignored. Option keeps its normal keyboard behavior unless you deliberately choose it as your sole dictation shortcut. To replace selected text, dictate the replacement words directly.

## Words and saved phrases

Open the words and saved phrases editor from Sona's Mac menu or Windows Settings. Add, edit or remove vocabulary and phrases without editing JSON. Changes stay in a draft until you save them.

- **Words:** preferred names and spellings supplied to optional AI cleanup.
- **Saved phrases:** a spoken trigger and its replacement text, such as “my scheduling link” and `https://example.com/book`. Matching ignores case, requires a whole phrase and gives the longest overlapping trigger priority. Expansion is literal and does not expand other triggers inside the replacement.
- **Suggest saved phrases:** an explicit setup action using your configured AI. Paste the links, signature or other details you want to use, then review each suggestion. Sona cannot look through your past chats, personal files or connected services. Manual editing remains available when suggestions are empty or unsuccessful. This command is unavailable with provider None and never runs during dictation, on launch or on a timer.

Phrase expansion happens locally before optional cleanup, with no additional AI request. With cleanup off or provider None, the expanded text is inserted directly. If an attempted cleanup fails, Sona returns the exact original recognition text, without partially applying phrase expansions.

**Suggest corrected spellings** is optional and off by default. In supported fields, it watches only Sona's verified insertion for up to **15 seconds** and asks before adding a corrected word. It stops on a focus change, a new recording, disabling the feature, or uncertainty about which text belongs to the insertion. Both platforms deliberately limit this to verified insertions into otherwise empty plain-text fields. Other fields continue to support dictation without this observation. See [PRIVACY.md](PRIVACY.md) for the exact scope and platform limits.

## Settings and privacy

Mac settings: `~/.config/murmur/config.json`. Windows: `%LOCALAPPDATA%\Sona`, with provider settings in `ai.json`. The historic Mac bundle identifier and settings location remain to preserve existing permissions and preferences.

```json
{
  "hotkey": "right-command",
  "setupComplete": true,
  "cleanupEnabled": true,
  "ai": { "provider": "codex", "model": "economy", "timeoutMs": 12000 },
  "vocabulary": ["Sona"],
  "snippets": [{ "trigger": "my scheduling link", "expansion": "https://example.com/book" }],
  "autoAddToDictionary": false
}
```

Optional API settings use `apiKeyEnv` for the name of an environment variable, never the credential itself. An app launched from Finder or Explorer may not inherit variables set only in a terminal. Launch it from the configured environment or configure your operating system's user environment, then restart it. Never commit your settings or keys.

The example above is the Mac config. Windows stores vocabulary and snippets together in `ai.json`, with the dictation hotkey and the spelling-suggestion switch in its app settings. Older configurations load without a migration step: phrases start empty, correction observation stays off, and retired second-shortcut/Assistant preferences cannot enable another hotkey. Editors validate entries and replace the config file atomically.

Mac's Sound menu includes the Sona blend and installed system/instrument sounds. The blend loads Bottle and Purr from that Mac at runtime. Windows ships original synthesized companion sounds. Apple's sound files are not redistributed. The supplied Sona app icon is included on both platforms.

Sona keeps recordings, transcripts, selected text and unsaved setup suggestions in memory rather than saving a history. Only settings you confirm, including vocabulary and saved phrases, are written to the config. Local status logs do not contain that text. AI providers have their own retention and account policies. Read [PRIVACY.md](PRIVACY.md) and [SECURITY.md](SECURITY.md).

## Build and check

```sh
swift build -c release
bash scripts/test-hotkeys.sh
bash scripts/test-assistant-panel-placement.sh
bash scripts/test-cues.sh
bash scripts/test-session-recovery.sh
bash scripts/test-exception-recovery.sh
bash scripts/test-audio-recovery.sh
node --test bridge/test/*.test.mjs
./bundle.sh --no-install
```

`test-session-recovery.sh` drives real dictation sessions with a stalling fake speech engine, with nothing on screen. `test-exception-recovery.sh` raises real Objective-C exceptions in child processes and checks the last-resort recovery. `test-audio-recovery.sh` uses your real microphone and holds it exclusively for about two and a half seconds in total, in two grabs, to reproduce a busy microphone; it skips without a microphone or microphone permission.

`bundle.sh` requires the local identity from `make-signing-cert.sh` and prepares the pinned Node runtime. The `--no-install` option leaves the signed app in a temporary build folder. Windows source build and test instructions are in [windows/README.md](windows/README.md).

```sh
.build/release/Murmur --panel 6
MURMUR_BACKDROP=1 .build/release/Murmur --panel 6
.build/release/Murmur --panel 8 --processing
.build/release/Murmur --recording-surface-selftest
.build/release/Murmur --prepare-speech
```

Preview modes use synthetic audio and do not open the microphone. `--doctor` reports the calling process's permissions; the running app's own status is authoritative. `--selftest` can exercise the Mac speech pipeline with a WAV file. CI checks both platform builds and shared cleanup behavior. Windows CI uses a public spoken fixture; microphone hardware and third-party application behavior still require the [manual checks](windows/docs/MANUAL-TESTS.md).

## License

Sona source and original assets use the [Sona Source-Available License](LICENSE). Use and private edits are allowed; publishing or redistributing copies or modified versions requires prior written permission. See [LICENSING.md](LICENSING.md) for the earlier MIT version and GitHub platform rights. Dependencies keep their own licenses. Their notices ship with the Windows package and bundled Node runtime. AI provider and operating-system trademarks belong to their respective owners; Sona is not affiliated with them.
