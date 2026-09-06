# Cleanup bridge validation

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

These live commands consume the chosen CLI account's normal quota and should be run intentionally. The native application's original low-latency Claude standby remains independent of this bridge.

No-account published-package check (does not install the package):

```sh
node bridge/test/gemini-package-smoke.mjs /absolute/path/to/gemini-cli/bundle/gemini.js
```

The standard test suite runs offline fixtures. This optional check needs the already staged official 0.58.0 bundle and Node 24, creates an empty temporary profile, verifies actual startup controls, and expects missing-login failure. It does not use the caller's Google account.
