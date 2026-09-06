# Security

Do not post credentials, private dictation or unredacted diagnostic bundles in public issues. For a suspected security flaw, use GitHub's private vulnerability reporting if it is enabled; otherwise contact the repository owner without including sensitive contents in a public report.

AI cleanup is untrusted text processing. Providers receive no execution tools. The bridge never runs transcript content, arbitrary shell strings or returned tool calls. It bounds time, input/output size and subprocess lifetime. Failure returns the original transcript; no automatic model upgrade or paid API selection occurs.

Installers use reviewed download origins, pinned versions and SHA-256 checks. The Windows Microsoft runtime is additionally checked for a valid Microsoft signature. A release checksum detects an unexpected download; it does not protect against a compromised repository maintainer. Inspect install scripts before running them.

The Mac app is built and signed locally with a local development identity. The Windows community build is not an EV-signed commercial installer. Operating-system download and publisher checks may require explicit user review. Neither installer disables system security, antivirus, privacy controls or execution policy globally.

Changes to hotkey handling, focus guards, clipboard restoration, provider isolation, installers and update paths need regression checks. Never commit credentials, certificates, private config, local AI logs or user data.
