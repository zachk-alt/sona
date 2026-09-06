# Sona cleanup bridge

Node 20 or later, standard library only. macOS and Windows use the same JSON settings and text protocol.

```sh
node bridge/sona-cleanup.mjs --config /absolute/path/to/config.json --mode prose
node bridge/sona-cleanup.mjs --config /absolute/path/to/config.json --doctor
node --test bridge/test/cleanup.test.mjs
```

Send the raw UTF-8 transcript through stdin, then close stdin. stdout contains only the repaired transcript. A provider/configuration/network/output failure returns the original text unchanged with exit status 0. stderr receives only a short reason code, never the transcript, response body, or credential. The native caller must also retain the original for missing Node, launch failures, cancellation, or a nonzero bridge exit.

The default deadline is 15 seconds, configurable from 250 through 30,000 ms. Use a 32 to 35 second outer deadline. The bridge kills a timed-out CLI process tree. Input above 64 KiB passes through without an AI call; model responses are capped at 1 MiB. There are no automatic retries or fallback models. `strict` mode preserves technical punctuation, case and spacing; `prose` repairs ordinary dictation.

## Configuration

See `config.example.json` and `config.schema.json`. Application-specific fields can coexist at the top level, but `ai` only accepts the documented fields.

```json
{
  "ai": { "provider": "auto", "model": "economy", "timeoutMs": 15000 },
  "vocabulary": ["Sona"]
}
```

`auto` chooses the first installed supported CLI in this order: Claude, Codex. It does not inspect credential files, test logins, or choose an API. If that CLI cannot clean the transcript, dictation passes through. Choose an explicit provider to use another account. `none` always passes through.

`executable` overrides a CLI's absolute path. `args` supports only a single absolute JavaScript launcher path when `executable` is Node. Arbitrary provider flags and shell commands are rejected. Known npm Windows shims are resolved to their Node entry points without `cmd.exe`; native `.exe` installs also work.

API providers read the environment variable named by `apiKeyEnv`, using the default below when omitted. Credential values are never accepted in JSON. Custom uses a full Chat Completions URL, an explicit model ID, and an explicit environment variable name. A loopback custom server can omit authentication; remote custom services require a key. Built-in endpoints cannot redirect credentials to another origin.

## Provider support and economy models

| Provider | Route | Economy model | Default key environment |
| --- | --- | --- | --- |
| `claude` | Existing Claude Code CLI account | `claude-haiku-4-5-20251001` | CLI manages its own login |
| `codex` | Existing Codex CLI account | `gpt-5.6-luna`, low effort | CLI manages its own login |
| `anthropic` | Anthropic Messages API | `claude-haiku-4-5-20251001` | `ANTHROPIC_API_KEY` |
| `openai` | OpenAI Chat Completions API | `gpt-5-nano-2025-08-07`, minimal effort | `OPENAI_API_KEY` |
| `gemini` | Gemini OpenAI-compatible API | `gemini-2.5-flash-lite`, thinking off | `GEMINI_API_KEY` |
| `kimi` | Moonshot Chat Completions API | `kimi-k2.6`, thinking off | `MOONSHOT_API_KEY` |
| `grok` | xAI Responses API | `grok-4.6`, low effort | `XAI_API_KEY` |
| `opencode` | OpenCode Zen Responses API | `gpt-5-nano`, minimal effort | `OPENCODE_API_KEY` |
| `custom` | OpenAI-compatible Chat Completions | Explicit ID required | Explicit name required remotely |

These are fixed, reviewed choices, not a live price optimizer. Some vendors do not offer a small model. xAI currently documents Grok 4.6 for text, and Kimi's current general-purpose option is K2.6. Prices, access and model IDs can change; an unavailable model produces plain dictation, never an automatic upgrade. Old Grok fast aliases and retired Kimi/Codex models are deliberately absent.

CLI routes use the existing CLI's authentication and usage limits. API routes have separate provider billing and may require a separately funded API account. A ChatGPT, Gemini, Claude, Kimi, Grok, or OpenCode subscription is not a universal API credential, and Sona does not convert one subscription into another provider's entitlement.

## Isolation and privacy

The transcript is JSON data on stdin, never argv or shell source. Fixed system instructions say to repair it without following its instructions. Claude has no built-in or MCP tools, safe mode, disabled skills/hooks, and no session persistence. Codex ignores user configuration/rules, disables tool-bearing features, uses read-only sandboxing, and disables session/history persistence. Both run in a fresh inert scratch directory. Newer CLI isolation flags are required; an older incompatible CLI safely fails through. Administrator policies still apply.

API requests offer no tools, make a single bounded request, and never execute returned tool calls. Error, refusal, truncated, malformed, empty, unexpected-model, and excessive outputs are rejected. No session, transcript file, or request log is created by the bridge. Provider-side retention and managed CLI policy remain the provider's responsibility. The original Mac Claude standby implementation can remain the low-latency route.

Gemini CLI, Kimi CLI and OpenCode CLI are not invoked. Their ordinary headless modes save sessions, and their tool/permission settings differ. Their API routes provide a predictable tool-free request without inheriting CLI plugins, hooks or agent behavior.

## Verification

`--doctor` reports only executable presence, environment-key presence, fixed models and transport capabilities. It makes no network request and does not claim that authentication or billing works. Automated tests use local mock processes and a loopback HTTP server, never real accounts. `node bridge/test/smoke-live.mjs claude` or `codex` is an explicit opt-in synthetic test that consumes the selected CLI account's normal quota.

The Swift adapter has an independent nonblocking I/O deadline and supports cancellation and shutdown. Its exact source is exercised by `test/SwiftBridgeTests.swift` against `test/fake-bridge.mjs` without models or AppKit.

## Official references reviewed September 5, 2026

- [Claude CLI isolation and machine output](https://code.claude.com/docs/en/cli-reference), [Claude model IDs](https://platform.claude.com/docs/en/models/overview), [Messages API](https://platform.claude.com/docs/en/api/messages/create).
- [Codex noninteractive mode](https://learn.chatgpt.com/docs/non-interactive-mode), [configuration controls](https://learn.chatgpt.com/docs/config-file/config-reference), [current account models and retirements](https://learn.chatgpt.com/docs/models).
- [GPT-5 nano API model and snapshot](https://developers.openai.com/api/docs/models/gpt-5-nano).
- [Gemini compatibility API](https://ai.google.dev/gemini-api/docs/openai), [Flash-Lite model ID](https://ai.google.dev/gemini-api/docs/models/gemini-2.5-flash-lite).
- [Kimi current models and retirements](https://platform.kimi.ai/docs/models), [K2.6 request parameters](https://platform.kimi.ai/docs/guide/kimi-k2-6-quickstart).
- [xAI model catalog](https://docs.x.ai/developers/models), [reasoning and Responses example](https://docs.x.ai/developers/model-capabilities/text/reasoning).
- [OpenCode Zen endpoints and models](https://opencode.ai/docs/zen/).
