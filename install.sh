#!/bin/bash
# Build locally, preserve settings, and install Sona without a package manager.
set -euo pipefail
cd "$(dirname "$0")"
SONA_HOTKEY=''
SONA_PROVIDER=''
SONA_MODEL=economy
SONA_OPEN=1
while [ $# -gt 0 ]; do
  case "$1" in
    --hotkey|--provider|--model)
      if [ $# -lt 2 ]; then echo "Missing value for $1" >&2; exit 1; fi
      case "$1" in
        --hotkey) SONA_HOTKEY=$2;;
        --provider) SONA_PROVIDER=$2;;
        --model) SONA_MODEL=$2;;
      esac
      shift 2;;
    --no-open) SONA_OPEN=0; shift;;
    --help) echo 'Usage: ./install.sh [--hotkey right-command] [--provider auto|none|claude|codex|gemini-cli|gemini|kimi|grok|openai|anthropic|opencode|custom] [--model economy|ID] [--no-open]'; exit 0;;
    *) echo "Unknown option: $1" >&2; exit 1;;
  esac
done
if [ "$(uname -s)" != Darwin ] || [ "$(uname -m)" != arm64 ] || [ "$(sw_vers -productVersion | cut -d. -f1)" -lt 26 ]; then
  echo 'Sona for Mac requires macOS 26 or later and Apple silicon. Windows users: windows/scripts/install.ps1.' >&2
  exit 1
fi
if [ ! -w /Applications ]; then
  echo 'This account cannot install into /Applications. Ask an administrator to run the local installer.' >&2
  exit 1
fi
if ! xcode-select -p >/dev/null 2>&1; then
  echo 'Apple Command Line Tools are needed to build Sona. Complete the system installation dialog, then run this installer again.'
  xcode-select --install
  exit 1
fi
if [ -z "$SONA_HOTKEY" ]; then
  if [ ! -t 0 ]; then echo 'Ask the user which shortcut they want, then pass --hotkey. Examples: right-command, option+space, f8.' >&2; exit 1; fi
  read -r -p 'Your Sona shortcut [right-command]: ' SONA_HOTKEY
  SONA_HOTKEY=${SONA_HOTKEY:-right-command}
fi
if [ -z "$SONA_PROVIDER" ] && [ -t 0 ]; then
  read -r -p 'AI provider [auto: existing Claude or Codex CLI; none: plain dictation]: ' SONA_PROVIDER
fi
SONA_PROVIDER=${SONA_PROVIDER:-auto}
case "$SONA_PROVIDER" in auto|none|claude|codex|gemini-cli|gemini|kimi|grok|openai|anthropic|opencode|custom) ;; *) echo 'Unknown AI provider.' >&2; exit 1;; esac
swift build -c release
.build/release/Murmur --validate-hotkey "$SONA_HOTKEY"
echo 'Sona uses Microphone and Accessibility access. macOS will request these on first launch. No Input Monitoring grant is requested.'
echo 'A local signing identity keeps your Accessibility grant through updates. Keychain may ask to allow codesign.'
bash make-signing-cert.sh
bash bundle.sh
/Applications/Sona.app/Contents/MacOS/Murmur --configure --hotkey "$SONA_HOTKEY" --provider "$SONA_PROVIDER" --model "$SONA_MODEL"
echo 'Preparing Apple on-device speech assets. The first setup may download a model.'
if ! /Applications/Sona.app/Contents/MacOS/Murmur --prepare-speech; then
  echo 'Sona is installed. Speech assets are not ready yet; reconnect and retry --prepare-speech before dictating.' >&2
  exit 1
fi
if [ "$SONA_OPEN" = 1 ]; then open /Applications/Sona.app; fi
