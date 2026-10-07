# Security

Do not post credentials, private dictation or unredacted diagnostic bundles in public issues. For a suspected security flaw, use GitHub's private vulnerability reporting if it is enabled; otherwise contact the repository owner without including sensitive contents in a public report.

AI cleanup, selected-text rewrites and snippet suggestions are untrusted text processing. Providers receive no execution tools. The bridge accepts fixed operation types, never arbitrary prompts, shell strings, tool calls or provider session identifiers. It bounds time, input/output size and subprocess lifetime. Ordinary dictation failure returns the exact original transcript. Rewrite failure does not change the selection. No automatic model upgrade, second request or paid API selection occurs.

Command insertion validates the original field, selection and activity before one complete paste. This is a guarded operation, not a transactional guarantee supplied by every editor. Sona does not pre-delete, stream edits, retry an ambiguous paste or attempt an automatic undo. Unsupported or changed targets are refused.

Suggested snippets and corrected vocabulary are never saved without review. Correction observation must be disabled by default, inert while disabled, limited to the verified inserted span and stopped on an ambiguous edit or expired 15-second window. Tests must cover those negative cases, not only successful edits.

Installers use reviewed download origins, pinned versions and SHA-256 checks. The Windows Microsoft runtime is additionally checked for a valid Microsoft signature. A release checksum detects an unexpected download; it does not protect against a compromised repository maintainer. Inspect install scripts before running them.

The Mac app is built and signed locally with a local development identity. The Windows community build is not an EV-signed commercial installer. Operating-system download and publisher checks may require explicit user review. Neither installer disables system security, antivirus, privacy controls or execution policy globally.

Changes to hotkey handling, focus guards, clipboard restoration, provider isolation, installers and update paths need regression checks. Never commit credentials, certificates, private config, local AI logs or user data.
