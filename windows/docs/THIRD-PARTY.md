# Windows dependencies and source evidence

Verified against primary project/package documentation on 2026-09-05.

| Component | Pin and role | Primary source |
| --- | --- | --- |
| .NET 8 / WPF | Self-contained desktop runtime and native windows | https://learn.microsoft.com/en-us/dotnet/desktop/wpf/ |
| NAudio.Wasapi / NAudio.Core | 2.4.0, capture and sample conversion; MIT | https://www.nuget.org/packages/NAudio.Wasapi/2.4.0 and https://github.com/naudio/NAudio |
| Whisper.net | 1.9.1, local inference bindings; MIT | https://www.nuget.org/packages/Whisper.net/1.9.1 and https://github.com/sandrohanea/whisper.net |
| Whisper.net.Runtime / NoAvx | 1.9.1, bundled native CPU inference; MIT | https://github.com/sandrohanea/whisper.net/blob/main/readme.md |
| Whisper multilingual base model | ggml-base.bin, 147951465 bytes, SHA256 `60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe` | https://huggingface.co/ggerganov/whisper.cpp/tree/5359861c739e955e79d9a303bcbc70fb988958b1 |
| Node.js | v24.20.0, private installer runtime, SHA256 checked; Node license included with install | https://nodejs.org/dist/v24.20.0/SHASUMS256.txt |
| Microsoft VC++ redistributable | Official signed x64 runtime installer, needed by Whisper's Windows libraries | https://learn.microsoft.com/en-us/cpp/windows/latest-supported-vc-redist |
| JFK test fixture | Public presidential speech excerpt distributed in official whisper.cpp samples; no commercial music or voice model | https://github.com/ggml-org/whisper.cpp/blob/master/samples/jfk.wav |

NAudio 3.x requires a newer .NET target, so the compatible 2.4.0 line is deliberate. Whisper's current Windows runtime documents Windows 11 or Server 2022 and VC++2022. The NoAVX package provides a fallback for CPUs without the normal AVX/AVX2/FMA/F16C instruction set. GPU-specific runtimes are not included.

The supplied application mark is reused from `Resources/SonaAppIcon.png`. ICO packaging resamples the same raster at standard Windows sizes without recoloring, cropping, redraw, or image generation. `assets/provenance.json` records its source hash. Sound cues are Sona's original portable assets from `Resources/Sounds`, not Apple's sound files.

Microsoft references for insertion and privacy:

- https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-registerhotkey
- https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-sendinput
- https://learn.microsoft.com/en-us/dotnet/core/deploying/single-file/overview
- https://support.microsoft.com/en-us/windows/privacy/turn-on-app-permissions-for-your-microphone-in-windows
