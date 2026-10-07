# Shared bridge validation

## Read-only Option assistant revision

Verified September 7, 2026 with Node 24.14.0: **170 tests passed, zero failed or skipped**, in 8.52 seconds. The focused assistant suite passed **57/57**. The localhost HTTP fixture required a sandbox exception to bind 127.0.0.1; it used only synthetic data. No provider, account, GUI, or native execution call was made for this revision.

Both Claude and Codex fixtures verify the read-only prompt, one generation per ask, temporary follow-up history, screenshot bytes, saved model/effort and isolation flags. Removed creation intents and app inventories invoke neither catalog nor generation. Unsolicited and user-requested action/Blender responses, including fenced and answer-shaped responses with extra action, scene or artifact fields, fail completely without retries. A mocked “Open Chrome” request receives a how-to guidance answer. This verifies the contract and routing, not actual model wording or live screen quality.

Assistant imports no local executor and returns only answer/text. The catalog advertises only screen_ask and selected rewrite capabilities. All existing transport/error-classification code, ordinary dictation, snippet setup, and selected-rewrite code is unchanged. Regression checks cover structured Claude errors, tool denial priority, malformed assistant content, rewrite whitespace and no replacement on failure. The five retained standalone Blender tests exercise retired helper code only, not an assistant capability.

## Historical Option assistant staging

The following evidence predates the read-only revision; action and Blender capabilities described here are retired.

Verified locally with Node 24.14.0: **131 tests passed, zero failed or skipped**, in 4.13 seconds. This includes the 108 existing bridge cases, 18 new assistant cases and 5 fixed-Blender validator/executor cases. No paid model generation was performed by this validation run. Existing loopback HTTP tests used only synthetic fixtures.

The new checks cover saved model/effort choice, safe economy defaults, actual catalog shapes, text-only capability refusal, zero generation for invalid settings, identical base64 image delivery, inherited FD image reads through an isolated Codex fixture, control/tool/error rejection, success-shaped explicit-error and malformed-success rejection, strict selected rewrite whitespace, result-then-hang timeout, temporary history bounds, exact-one action validation, confirmation on Enter, and unsolicited Blender refusal. The final release guard also requires an explicit successful Claude result flag and exactly one turn, rejects explicit errors even beside a success subtype, and requires well-formed empty error/denial lists. Regressions prove assistant-profile rewrite returns no replacement and does not mutate the source selection on these failures. Ordinary dictation fallback and snippet/setup tests remain unchanged and pass.

Actual installed Claude 2.1.257 metadata initialization returned its supported model/effort rows with no user prompt. Actual installed Codex 0.144.1 model/list returned model IDs, modalities and efforts with no thread or turn. Codex metadata initialization needed normal host access outside the development shell sandbox. The source audit used the official rust-v0.144.1 reader: protocol/src/models.rs reads bytes with std::fs::read, then utils/image/src/lib.rs decodes a memory Cursor. A local Mac inherited FD3 byte read and the bridge image fixture passed. **These are transport/metadata tests, not a live vision-quality claim. Windows named-pipe and native action behavior were not run on this Mac.** Native owners track those separate checks.

The release owner separately ran one live synthetic PNG request through Claude Sonnet 5 at high effort. It correctly identified the blue sphere and gold torus in 3.65 seconds, without actions. The fixed Blender executor also passed a local Blender 5.1.2 scene/build/preview smoke. These checks used synthetic content and do not establish native screen capture or app-action behavior. The release owner also ran one live installed Codex request with `gpt-5.6-luna` at high effort. Its synthetic image arrived through `/dev/fd/3`, together with two supplied user/assistant history messages. In 6.15 seconds it correctly answered: “The metallic gold torus is hollow in its center.” No screenshot file or provider session history was used. Native capture and app-action checks remain separate from these live transport checks.

## Previous feature implementation

Verified September 6, 2026 in the isolated feature staging tree with Node 24.14.0: **108 Node tests passed, zero failed or skipped**, in 4.13 seconds. The existing loopback test server required permission to bind localhost outside the development sandbox; no external provider/account request was made.

The versioned dispatcher and legacy raw entry point share the reviewed economy and no-local-transcript-history policy. Tests verify exact zero/one invocation counts, fixed models despite saved overrides, disabled AI with local snippets, literal Unicode phrase boundaries, globally longest overlaps, nonrecursive replacement and literal metacharacters. Dictation errors preserve the exact original before expansion. Rewrite errors contain no replacement text, complete success preserves original outer whitespace, and setup accepts only validated expansions present verbatim in explicit context. Empty setup context launches nothing. Invalid requests/configuration, cancellation, missing CLI/login, timeout, malformed/tool/error results, output bounds, duplicate triggers, snippet limits and typed JSON envelopes are covered.

Legacy `claudePath` compatibility is also covered: only eligible auto/Claude settings without an explicit executable are translated, malformed eligible paths invoke nothing, explicit routes/paths win, configuration remains unmodified, and fixed economy/one-invocation behavior is preserved.

Both application interfaces reject Gemini CLI and custom providers before process launch or network access. Gemini's retained adapter and loopback custom API tests explicitly call the low-level transport with application policy disabled inside a test helper. This is regression coverage of dormant adapter code, not an available application route. No command-line flag disables the application policy. Provider flags, API request formats and model pins were not changed for these features; their previously reviewed official references remain in README.md.

The native Swift/Windows integration has separate owners and checks. The historical evidence below is retained from the baseline; live providers and the published Gemini package were not rerun for this feature change.

## Baseline evidence from September 5

Verified September 5, 2026 on macOS with Node 24.14.0 and Swift. The bridge uses Node standard-library APIs, with Node 24 required for the reviewed Gemini loader. Windows CI has exercised its private Node bridge passthrough and application engine; vendor CLI accounts have not been tested on Windows.

- **74 Node tests passed.** Real mock subprocesses cover both CLI envelopes, safe arguments, stdin-only transcript delivery, missing/failed launch, nonzero exit, explicit error responses, malformed/empty/expanded/fenced output, output overflow, early stdin closure, silent/hung processes, result-then-failure, result-then-hang, cancellation, and process-group termination. A loopback HTTP server verifies the actual fetch/body/auth/output pipeline, 401, redirect refusal, malformed/oversized/error/truncated responses, timeout and missing-key behavior. No external API is called by this suite.
- **23 Gemini checks** are included in that total. They cover fixed singleton model policies, JSON at-sign escaping, preservation of system restrictions, tool/hook/MCP/extension/auth refusal before initialization, zero-registry checks, output/model errors, timeout, hang-after-result, version incompatibility and doctor reporting. Fixtures model the CLI interface and make no account call.
- **Actual published Gemini 0.58.0 package smoke passed without an account.** With an empty test HOME, the exact bundled Config passed the real runtime guard before authentication and then stopped for missing login in 0.814 seconds. A separate real Config construction check passed effective restrictions, rejected API authentication and produced an actual zero-tool registry. The published package uses bundled chunks, which are hash-checked by the loader. The verified bootstrap flag prevents relaunch, inherited sandbox settings fail through, and telemetry environment overrides are removed. This is startup and isolation evidence, not a live Google-account cleanup success claim. Gemini's upstream local session retention remains documented.
- Request-builder and response-parser checks cover Chat Completions, Anthropic Messages, and Responses formats, including tool/refusal rejection and requested-model matching. The final model-validation refinement also passed its focused regression check for missing model IDs and misleading expensive-model prefixes. Dated snapshots of the requested model are permitted; another family is rejected.
- **11 exact-source Swift lifecycle cases passed.** The real adapter and protocol compile together. Synthetic Node fixtures verify success, early closed stdin, empty/nonzero/excessive output, stalls, output before a stall, a child that never reads, missing Node, task cancellation, and shutdown. All failure results preserve the original. Timeout cases complete within two seconds with a one-second test deadline.
- **Two opt-in live CLI smoke tests passed.** Both use existing CLI account authentication and a fixed synthetic sentence. Claude with `claude-haiku-4-5-20251001` completed in 1.809 seconds. Codex with `gpt-5.6-luna` completed in 4.209 seconds. Both repaired punctuation/filler without a tool event. These timings are single smoke observations, not performance guarantees.

The initial sandboxed CLI smoke attempts could not initialize their normal runtime; they returned original text as designed. Repeating the authorized fixed-input tests with normal host access passed. The local HTTP suite similarly needed permission to bind its loopback test socket. These are development-sandbox restrictions, not new application system permissions.

No live Anthropic/OpenAI/Gemini/Kimi/xAI/OpenCode API request was made, so the API adapters have documented protocol and mock coverage, not a claim of live account entitlement. No credential files were searched, read, copied or included. The selected CLI programs handled their own existing login.

Reproduce Node checks from the repository root:

```sh
node --test bridge/test/*.test.mjs
```

Reproduce Swift checks from the repository root:

```sh
mkdir -p bridge/.test-build
swiftc -module-cache-path bridge/.test-build/module-cache Sources/Murmur/Cleanup/CleanupService.swift Sources/Murmur/Cleanup/BridgeCleanupService.swift bridge/test/SwiftBridgeTests.swift -o bridge/.test-build/swift-bridge-tests
bridge/.test-build/swift-bridge-tests /absolute/path/to/node /absolute/path/to/bridge/test/fake-bridge.mjs
```

Explicit live smoke, outside the offline suite:

```sh
node bridge/test/smoke-live.mjs claude
node bridge/test/smoke-live.mjs codex
```

These live commands consume the chosen CLI account's normal quota and should be run intentionally. The original low-latency Claude standby is independent of this bridge. Feature integrations must use the shared operation dispatcher to enforce the current policy.

No-account published-package check (does not install the package):

```sh
node bridge/test/gemini-package-smoke.mjs /absolute/path/to/gemini-cli/bundle/gemini.js
```

The standard test suite runs offline fixtures. This optional check needs the already staged official 0.58.0 bundle and Node 24, creates an empty temporary profile, verifies actual startup controls, and expects missing-login failure. It does not use the caller's Google account.
