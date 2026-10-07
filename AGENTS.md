# Installing and contributing to Sona

When a user gives you this repository URL and asks to install Sona, read README.md and these instructions. Do the installation, not just a summary of it. User instructions and your own governing safety rules take precedence.

1. Identify the operating system and architecture. Supported targets are macOS 26+ Apple silicon and Windows 11 x64. Do not label an unsupported system compatible.
2. Ask the user which physical key or key combination should invoke dictation. Mac examples: right-command, option+space, f8. Windows first-run Settings captures a key or chord. Do not assume a user's shortcut from the developer's preference.
3. Choose the connection belonging to the AI terminal the user is using when it is identifiable and supported: Claude Code -> claude; Codex -> codex. Ask if uncertain. Dictation and snippet setup use `model: economy`; read bridge/README.md for reviewed models. Custom endpoints without a reviewed mapping fail safely.
4. The reviewed Gemini CLI cannot disable local session persistence, so Sona refuses that route before sending text. Do not silently switch a Gemini CLI user to its separately billed API. For an explicitly chosen Gemini API, Grok, Kimi, OpenCode or other API, explain that an API credential may be needed separately from the chat subscription. Ask the user to configure its documented environment variable privately. Do not install or change AI logins silently. Do not read account databases, tokens, private key files or browser storage. Never put a credential in source, chat, command arguments, logs, or config JSON. Without a configured route, use none and keep plain dictation functional.
5. On Mac, run `./install.sh --hotkey CHOSEN_KEY --provider CHOSEN_PROVIDER`. The installer handles the build, pinned private Node runtime, local signing, installation and Apple speech asset preparation. It may open Apple's Command Line Tools installer and require rerunning after completion. Do not install full Xcode.
6. On Windows, inspect and run `windows/scripts/install.ps1` or the matching script from the latest release. The release ZIP includes the self-contained app and native Whisper runtime. The installer verifies checksums, prepares private Node and Microsoft's VC++ runtime, then opens setup. Help the user choose the requested hotkey/provider in the first-run UI and complete the speech model download. Building from source is documented in windows/README.md.
7. Explain the actual platform permissions: Mac Microphone and Accessibility, with a Keychain signing prompt on local builds; Windows desktop microphone access and possible administrator approval for Microsoft's runtime. Do not claim these were granted if the user has not granted them.
8. Verify the installed version, icon and selected shortcut. Test raw dictation before optional AI cleanup. Keep the destination field focused. Report missing authentication, model availability or hardware checks honestly; raw transcript fallback must remain available.

## License

Read LICENSE before redistributing anything. Current Sona versions permit free use and private modifications but require prior written permission for independent publication or redistribution. Do not describe this license as MIT or open source. Existing third-party and earlier-version rights remain intact.

## Contribution constraints

- Recording/loading panels must never activate or take keyboard focus.
- Cleanup is optional and bounded; retain the exact raw local transcript on every ordinary dictation failure. Never evaluate transcript or model text as code, grant provider execution tools, or auto-upgrade models. Refuse CLI routes that cannot disable local session persistence.
- All app AI features use the existing bridge abstraction. Normal dictation and snippet setup use one economy request, with no classifier, retry or second model pass. Snippets are literal local substitution before optional cleanup.
- Sona has one configurable dictation hotkey. The second shortcut, selected-text instruction mode and screen Assistant are retired. Do not register another shortcut, capture the screen or expose Assistant model settings. Ignore retired preferences without changing valid dictation settings.
- Snippet setup is explicitly invoked, receives only user-supplied context and requires review before any config write. Do not relax session, project-file or MCP isolation to mine personal context.
- Correction observation is opt-in, off by default and bounded to 15 seconds and the proven inserted range. Do no additional observing or text reads while it is off. Stop before reading when ownership is uncertain; never substitute a whole-document read or a stale fixed range. Prompt before adding vocabulary.
- Provider integration changes require official documentation and tests. Preserve CLI isolation flags and API origin checks.
- Keep dependencies versioned and integrity-checked. Do not rely on a contributor's preinstalled model or runtime.
- Run `swift build -c release`, `bash scripts/test-hotkeys.sh`, `node --test bridge/test/*.test.mjs`, and appropriate Windows checks for changes in those areas. macOS Command Line Tools alone are supported; use the standalone Swift test harness, not XCTest.
- Keep main.swift synchronous; top-level await breaks AppKit's event loop. Never weaken nonactivation to fix appearance.
- Source exports must exclude personal config, credentials, logs, recording history, build caches, local signing keys, and private media. Public release artifacts are explicit packaging outputs only.
