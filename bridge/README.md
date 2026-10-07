# Sona cleanup bridge

Node 20 or later, standard library only. macOS and Windows share the same settings and versioned operation protocol. The native apps invoke only dictation and explicit snippet setup, both using reviewed economy models. The second hotkey and Assistant have been removed from both apps. All routes refuse local transcript history and model execution tools.

```sh
node bridge/sona-cleanup.mjs --request --config /absolute/path/to/config.json
node bridge/sona-cleanup.mjs --config /absolute/path/to/config.json --mode prose
node bridge/sona-cleanup.mjs --config /absolute/path/to/config.json --doctor
node bridge/sona-cleanup.mjs --config /absolute/path/to/config.json --catalog
node --test bridge/test/*.test.mjs
```

## Versioned operations

Use `--request` for native app integrations. Send one UTF-8 JSON request through stdin and close stdin. stdout contains exactly one bridge-authored JSON result. The model never authors the transport envelope. See `request.schema.json` and `result.schema.json`.

```json
{"version":1,"operation":"dictate","transcript":"my signature","mode":"prose","cleanupEnabled":true}
{"version":1,"operation":"rewrite","selection":"  Hello there.\n","instruction":"Make this greeting formal."}
{"version":1,"operation":"snippet_assist","context":"My signature is Best regards, Example Writer."}
```

These are three separate requests, not a batch. Each request makes zero or one generation request. Retired protocol operations remain for compatibility and offline regression tests; the native apps no longer call them. There are no classification, repair, retry, or alternate-provider calls.

| Operation | Success | Failure or missing input |
| --- | --- | --- |
| `dictate` | `status: "ok"`, `text` | `status: "fallback"`, exact original `transcript` in `text`, sanitized `reason` |
| `rewrite` | `status: "ok"`, complete replacement `text` | `status: "error"`, `reason`, no `text` |
| `snippet_assist` | `status: "ok"`, proposed `snippets` | `status: "needs_input"` when context is insufficient, or `"error"`; no `text` |

Every result includes `version: 1` and the matching `operation`. An unparseable request uses `operation: "unknown"` and `status: "error"`. Validate version, operation, status, type and output bounds before using a result. Never paste rewrite instructions, source selections, error messages, or setup proposals as a fallback. Native callers retain originals for launch failure, cancellation, malformed envelopes and other transport problems.

Dictation expands local snippets before optional cleanup. `cleanupEnabled: false` or provider `none` applies those substitutions with zero provider calls. Any attempted cleanup/configuration/validation failure returns the exact original transcript, before substitution. `strict` preserves technical punctuation, case and spacing; `prose` repairs ordinary dictation. Rewriting preserves the selection's exact original leading/trailing whitespace centrally. It does not run snippet substitution or save dictionary changes.

Snippet assistance is an explicit setup action, separate from recording and rewriting. Its `context` is a user-supplied string. Empty/whitespace-only context returns `needs_input` without a provider call. A nonempty context can receive one proposal request. Every proposed expansion must occur verbatim in that context, and all candidates must pass the normal snippet validator and avoid existing trigger collisions. The bridge never saves proposals. The user reviews and chooses what to save. An authenticated account supplies access, not remembered personal names, signatures, addresses, or fixed strings. No previous sessions or documents are retrieved to fill missing context.

Requests are capped at 6 MiB of encoded JSON to accommodate inline images; each input text field is capped at 64 KiB UTF-8. Rewrite fields must contain non-whitespace text. Ordinary model transport responses are capped at 1 MiB and usable text at 64 KiB. Assistant transport events are capped at 2 MiB, with the same 64 KiB usable-text bound. The ordinary provider deadline is 15 seconds, configurable from 250 through 30,000 ms. Native callers should use a 32 to 35 second outer deadline. Cancellation and timeouts terminate the child process tree. Invalid requests/configuration and policy refusals occur before provider launch. stderr contains only sanitized reason codes, never transcript, response body or credentials.

## Retired Assistant protocol compatibility

The second hotkey, screen capture, temporary chat, selected-text instruction mode and Assistant model settings are no longer available in the native apps. Their capture and panel implementations are excluded from application builds. Old native preferences are ignored and do not register an additional shortcut.

The shared bridge retains its `rewrite`, `assistant` and `catalog` schemas and offline regression tests for compatibility. These are not entry points in the Sona UI or normal dictation path. Retained `screen_ask` requests accept caller-supplied images only and return a bounded read-only answer. They expose no tools, computer actions, cursor or artifact creation. Retained Assistant overrides cannot change ordinary dictation's economy model. No application screenshot is taken or request made for these retired operations.

## Legacy raw interface

Without `--request`, stdin/stdout remain raw UTF-8. Success returns repaired text; failures return the exact original with exit status 0. Input above 64 KiB streams through unchanged without a provider call. This interface now uses the same economy and no-local-history policy, as well as local snippets. Provider `none` applies snippets without AI. Existing saved explicit model IDs still load, but legacy calls use the reviewed economy preset instead. Custom and Gemini CLI configurations remain readable and fail through without launching or making a request. There is no legacy route around the operation policy.

## Configuration

See `config.example.json` and `config.schema.json`. Application-specific fields can coexist at the top level, but `ai` only accepts the documented fields.

```json
{
  "ai": { "provider": "auto", "model": "economy", "timeoutMs": 15000 },
  "vocabulary": ["Sona"],
  "autoAddToDictionary": false,
  "snippets": [{ "trigger": "my signature", "expansion": "Best regards, Example Writer." }]
}
```

`auto` chooses the first installed supported CLI in this order: Claude, Codex. It does not inspect credential files, test logins, or choose an API. If that CLI cannot clean the transcript, dictation passes through. Choose an explicit provider to use another account. `none` disables AI while retaining local snippet expansion.

The legacy Mac top-level `claudePath` remains supported without rewriting the settings file. When `ai.provider` is `auto` or `claude` (including the default) and `ai.executable` is absent, a valid absolute `claudePath` selects Claude and becomes its executable. An explicit new provider or executable takes precedence, including `none`. A malformed eligible legacy path fails safely before any invocation. Economy and isolation policies still apply.

`executable` overrides a CLI's absolute path. `args` supports only a single absolute JavaScript launcher path when `executable` is Node. Arbitrary provider flags and shell commands are rejected. Known npm Windows shims are resolved to their Node entry points without `cmd.exe`; native `.exe` installs also work.

API providers read the environment variable named by `apiKeyEnv`, using the default below when omitted. Credential values are never accepted in JSON. Custom settings still parse for compatibility, but requests are blocked because no custom economy preset has been reviewed. Its retained low-level adapter uses a full Chat Completions URL and an explicit environment variable name. Only explicit adapter tests can bypass the application policy; no CLI flag exposes that bypass. Built-in endpoints cannot redirect credentials to another origin.

`snippets` defaults to `[]`. The limit is 128 entries, each exactly `{trigger, expansion}`. Triggers must already be trimmed, contain 1 through 120 Unicode code points, and contain no controls or line separators. Expansion text must not be whitespace-only; it permits tabs/newlines but no other controls, is at most 8192 UTF-8 bytes, and all stored expansions together must fit 65536 bytes. Duplicate triggers are rejected using Unicode case-insensitive equality. Vocabulary remains at most 256 nonempty strings of at most 100 UTF-16 code units, without C0/C1 controls (U+0000 through U+001F and U+007F through U+009F). Format characters such as ZWJ remain allowed.

Substitution is literal and Unicode case-insensitive, without normalization, regular-expression interpretation or recursion. A phrase must have no Unicode letter, number, mark or underscore immediately outside either edge. The globally longest overlapping trigger wins, even when it starts later; equal lengths prefer the earliest start and then configuration order. All replacements are selected against the original text. Replacement metacharacters such as `$&` and backslashes remain literal. Text exceeding 64 KiB after expansion safely returns the raw original. Text in languages without spaces needs an actual phrase boundary for a match.

`autoAddToDictionary` defaults to `false` and remains optional. Retired `commandHotkey` and Assistant fields are accepted only by the bridge compatibility schema; native apps ignore them and never register a second shortcut. No bridge setting writes config, learns words automatically or saves snippets.

## Provider support and economy models

| Provider | Route | Economy model | Default key environment |
| --- | --- | --- | --- |
| `claude` | Existing Claude Code CLI account | `claude-haiku-4-5-20251001` | CLI manages its own login |
| `codex` | Existing Codex CLI account | `gpt-5.6-luna`, low effort | CLI manages its own login |
| `gemini-cli` | Unavailable: upstream local transcript history | `gemini-3.1-flash-lite` | CLI manages its own OAuth login |
| `anthropic` | Anthropic Messages API | `claude-haiku-4-5-20251001` | `ANTHROPIC_API_KEY` |
| `openai` | OpenAI Chat Completions API | `gpt-5-nano-2025-08-07`, minimal effort | `OPENAI_API_KEY` |
| `gemini` | Gemini OpenAI-compatible API | `gemini-2.5-flash-lite`, thinking off | `GEMINI_API_KEY` |
| `kimi` | Moonshot Chat Completions API | `kimi-k2.6`, thinking off | `MOONSHOT_API_KEY` |
| `grok` | xAI Responses API | `grok-4.6`, low effort | `XAI_API_KEY` |
| `opencode` | OpenCode Zen Responses API | `gpt-5-nano`, minimal effort | `OPENCODE_API_KEY` |
| `custom` | Unavailable: no reviewed economy preset | No reviewed preset | Explicit name required remotely |

These are fixed, reviewed choices, not a live price optimizer. Every ordinary dictation, snippet setup and unprofiled rewrite uses the table preset regardless of an older saved model override. Only the retained, unexposed Assistant protocol accepts a separate catalog choice. Unsupported custom economy and Gemini local-history routes are refused before launch. The table retains their metadata for migration; it does not advertise those routes as available. Some vendors do not offer a small model. xAI currently documents Grok 4.6 for text, and Kimi's current general-purpose option is K2.6. Prices, access and model IDs can change; an unavailable model produces plain dictation, never an automatic upgrade. Old Grok fast aliases and retired Kimi/Codex models are deliberately absent.

CLI routes use the existing CLI's authentication and usage limits. API routes have separate provider billing and may require a separately funded API account. A ChatGPT, Gemini, Claude, Kimi, Grok, or OpenCode subscription is not a universal API credential, and Sona does not convert one subscription into another provider's entitlement.

## Isolation and privacy

The transcript is JSON data on stdin, never argv or shell source. Fixed system instructions say to repair it without following its instructions. Claude has no built-in or MCP tools, safe mode, disabled skills/hooks, and no session persistence. Codex ignores user configuration/rules, disables tool-bearing features, uses read-only sandboxing, and disables session/history persistence. Both run in a fresh inert scratch directory. Newer CLI isolation flags are required; an older incompatible CLI safely fails through. Administrator policies still apply.

API requests offer no tools, make a single bounded request, and never execute returned tool calls. Error, refusal, truncated, malformed, empty, unexpected-model, and excessive outputs are rejected. No transcript file or request log is created by the bridge itself. Provider-side retention and managed CLI policy remain the provider's responsibility. The original Mac Claude standby is outside this shared transport. Native feature integrations use the versioned bridge. Retained Assistant compatibility requests remain isolated and cannot override the model for dictate or snippet_assist.

`gemini-cli` is blocked for all Sona requests because the reviewed CLI saves its normal local session history outside the temporary workspace. Sona does not delete another application's history or redirect its authentication. The retained adapter and isolated offline tests document the existing Google OAuth route, reviewed Gemini CLI 0.58.0 package, Node 24 loader, fixed Flash-Lite model, disabled bootstrap relaunch, and runtime zero-tool guard. Those controls prevent tool execution but do not prevent transcript persistence. Consequently they do not satisfy the current no-local-transcript-history policy. There is no automatic substitution of the separate Gemini API route. A user must explicitly choose that route and configure its API access if desired.

The official Grok CLI supports browser OAuth and cached login, so API-only access is not an inherent Grok limitation. Sona has not implemented its CLI adapter: ordinary headless mode retains MCP meta-tools and inherited hooks, and managed hooks cannot simply be switched off. Its API route remains available. Kimi and OpenCode are also currently API routes.

## Verification

`--doctor` reports executable presence, environment-key presence, fixed models and transport capabilities. It includes `requestProtocol` and per-provider `operations` capabilities for generic UI decisions. `available` means local executable/key presence only; `operations.supported` is the separate policy gate. Gemini package/Node compatibility metadata is retained for diagnosis, but its operation support is false regardless of installation. It makes no network request and does not claim that authentication or billing works. Automated tests use local mock processes and a loopback HTTP server, never real accounts. `node bridge/test/smoke-live.mjs claude` or `codex` is an explicit opt-in synthetic test that consumes the selected CLI account's normal quota.

The Swift adapter has an independent nonblocking I/O deadline and supports cancellation and shutdown. Its exact source is exercised by `test/SwiftBridgeTests.swift` against `test/fake-bridge.mjs` without models or AppKit.

## Official references reviewed September 5 and 6, 2026

- [Claude inline image input](https://code.claude.com/docs/en/agent-sdk/streaming-vs-single-mode), [model and effort configuration](https://code.claude.com/docs/en/model-config).
- [Codex model/list metadata](https://learn.chatgpt.com/docs/app-server), [reviewed image byte reader](https://github.com/openai/codex/blob/rust-v0.144.1/codex-rs/protocol/src/models.rs), [in-memory image decoding](https://github.com/openai/codex/blob/rust-v0.144.1/codex-rs/utils/image/src/lib.rs).
- [Claude CLI isolation and machine output](https://code.claude.com/docs/en/cli-reference), [Claude model IDs](https://platform.claude.com/docs/en/models/overview), [Messages API](https://platform.claude.com/docs/en/api/messages/create).
- [Codex noninteractive mode](https://learn.chatgpt.com/docs/non-interactive-mode), [configuration controls](https://learn.chatgpt.com/docs/config-file/config-reference), [current account models and retirements](https://learn.chatgpt.com/docs/models).
- [GPT-5 nano API model and snapshot](https://developers.openai.com/api/docs/models/gpt-5-nano).
- [Gemini compatibility API](https://ai.google.dev/gemini-api/docs/openai), [Flash-Lite model ID](https://ai.google.dev/gemini-api/docs/models/gemini-2.5-flash-lite).
- [Kimi current models and retirements](https://platform.kimi.ai/docs/models), [K2.6 request parameters](https://platform.kimi.ai/docs/guide/kimi-k2-6-quickstart).
- [xAI model catalog](https://docs.x.ai/developers/models), [reasoning and Responses example](https://docs.x.ai/developers/model-capabilities/text/reasoning).
- [OpenCode Zen endpoints and models](https://opencode.ai/docs/zen/).


Gemini's exact reviewed implementation: [settings precedence and remote admin replacement](https://github.com/google-gemini/gemini-cli/blob/v0.58.0/packages/cli/src/config/settings.ts), [Config initialization and tool registry](https://github.com/google-gemini/gemini-cli/blob/v0.58.0/packages/core/src/config/config.ts), [headless preprocessing](https://github.com/google-gemini/gemini-cli/blob/v0.58.0/packages/cli/src/nonInteractiveCli.ts), [model fallback selection](https://github.com/google-gemini/gemini-cli/blob/v0.58.0/packages/core/src/availability/policyHelpers.ts), [CLI model pins](https://github.com/google-gemini/gemini-cli/blob/v0.58.0/packages/core/src/config/models.ts), [bootstrap relaunch](https://github.com/google-gemini/gemini-cli/blob/v0.58.0/packages/cli/index.ts), [session recording](https://github.com/google-gemini/gemini-cli/blob/v0.58.0/packages/core/src/services/chatRecordingService.ts). Account behavior: [existing Google authentication](https://geminicli.com/docs/get-started/authentication/), [CLI models](https://geminicli.com/docs/cli/model/), [quotas and subscriptions](https://geminicli.com/docs/resources/quota-and-pricing/). Grok: [official authentication](https://github.com/xai-org/grok-build/blob/main/crates/codegen/xai-grok-pager/docs/user-guide/02-authentication.md), [headless behavior](https://docs.x.ai/build/cli/headless-scripting), [managed hooks](https://github.com/xai-org/grok-build/blob/main/crates/codegen/xai-grok-hooks/src/config.rs).
