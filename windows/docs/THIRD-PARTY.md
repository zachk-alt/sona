# Windows dependencies and source evidence

Verified against primary project/package documentation on 2026-09-05; speech engine rows added 2026-11-04.

| Component | Pin and role | Primary source |
| --- | --- | --- |
| .NET 8 / WPF | Self-contained desktop runtime and native windows | https://learn.microsoft.com/en-us/dotnet/desktop/wpf/ |
| NAudio.Wasapi / NAudio.Core | 2.4.0, capture and sample conversion; MIT | https://www.nuget.org/packages/NAudio.Wasapi/2.4.0 and https://github.com/naudio/NAudio |
| Whisper.net | 1.9.1, local inference bindings; MIT | https://www.nuget.org/packages/Whisper.net/1.9.1 and https://github.com/sandrohanea/whisper.net |
| Whisper.net.Runtime / NoAvx | 1.9.1, bundled native CPU inference; MIT | https://github.com/sandrohanea/whisper.net/blob/main/readme.md |
| Whisper multilingual base model | ggml-base.bin, 147951465 bytes, SHA256 `60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe` | https://huggingface.co/ggerganov/whisper.cpp/tree/5359861c739e955e79d9a303bcbc70fb988958b1 |
| Whisper English-only base model | ggml-base.en.bin, 147964211 bytes, SHA256 `a03779c86df3323075f5e796cb2ce5029f00ec8869eee3fdfb897afe36c6d002` (Git LFS metadata, read 2026-11-04) | https://huggingface.co/ggerganov/whisper.cpp/blob/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-base.en.bin |
| sherpa-onnx | 1.13.8, `org.k2fsa.sherpa.onnx` managed bindings from NuGet, and the native `sherpa-onnx-c-api.dll` (SHA256 `86c7807d12982aa31c5cae57c686f30df9e5d5db4309b314d1efd5c873a8333c`) from the official no-TTS Windows build `sherpa-onnx-v1.13.8-win-x64-shared-MT-Release-no-tts-lib.tar.bz2` (7536080 bytes, SHA256 `a1253e665c4f236119c443c8932a8acfca32a546c78c05962d483c9a0eae21b7`), which `build.ps1` downloads and checks; runs Parakeet for English; Apache-2.0 (`licenses/sherpa-onnx.txt`) | https://www.nuget.org/packages/org.k2fsa.sherpa.onnx/1.13.8 and https://github.com/k2-fsa/sherpa-onnx/releases/tag/v1.13.8 |
| ONNX Runtime | 1.28.2 (`onnxruntime.dll` version resource, SHA256 `7f66f939a881baf4f46a2216496798edf4a1429878b646d12674aa62f27d8a25`), shipped in the same no-TTS sherpa-onnx archive (byte-identical to the copy in the NuGet runtime package); MIT, Microsoft (`licenses/onnxruntime.txt`, `licenses/onnxruntime-third-party-notices.txt`) | https://github.com/microsoft/onnxruntime/blob/v1.28.2/LICENSE |
| NVIDIA Parakeet TDT 0.6B v2 (English engine) | Model by NVIDIA, licensed CC BY 4.0 (https://creativecommons.org/licenses/by/4.0/). Sona downloads a converted copy, not NVIDIA's original files: the ONNX export with int8 weights made for sherpa-onnx and published by Hugging Face user csukuangfj (changes: converted from NeMo to ONNX, int8 weights), at commit `1ab9323565ddb038682214b292f588070a538ce2`. `encoder.int8.onnx` 652184296 bytes, SHA256 `a32b12d17bbbc309d0686fbbcc2987b5e9b8333a7da83fa6b089f0a2acd651ab`; `decoder.int8.onnx` 7257753 bytes, SHA256 `b6bb64963457237b900e496ee9994b59294526439fbcc1fecf705b31a15c6b4e`; `joiner.int8.onnx` 1739080 bytes, SHA256 `7946164367946e7f9f29a122407c3252b680dbae9a51343eb2488d057c3c43d2` (Git LFS metadata, read 2026-11-04); `tokens.txt` 9384 bytes, SHA256 `ec182b70dd42113aff6c5372c75cac58c952443eb22322f57bbd7f53977d497d` (hashed from the pinned resolve URL; Git blob id matches). NVIDIA does not endorse Sona (`licenses/Parakeet-model.txt`). | https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2 and https://huggingface.co/csukuangfj/sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8/tree/1ab9323565ddb038682214b292f588070a538ce2 |
| Node.js | v24.20.0, private installer runtime, SHA256 checked; Node license included with install | https://nodejs.org/dist/v24.20.0/SHASUMS256.txt |
| Microsoft VC++ redistributable | Official signed x64 runtime installer, needed by Whisper's Windows libraries | https://learn.microsoft.com/en-us/cpp/windows/latest-supported-vc-redist |
| JFK test fixture | Public presidential speech excerpt distributed in official whisper.cpp samples; no commercial music or voice model | https://github.com/ggml-org/whisper.cpp/blob/master/samples/jfk.wav |

NAudio 3.x requires a newer .NET target, so the compatible 2.4.0 line is deliberate. sherpa-onnx's two native libraries are placed beside `Sona.exe`, not inside the single-file bundle, and Sona loads its own `onnxruntime.dll` by full path before sherpa-onnx, so an older system copy of ONNX Runtime is not picked up. The prebuilt `sherpa-onnx-c-api.dll` in the NuGet runtime package `org.k2fsa.sherpa.onnx.runtime.win-x64` also contains sherpa-onnx's text-to-speech code with espeak-ng (GPL-3.0-or-later) linked in through piper-phonemize, so Sona does not ship it: the project excludes that package's native files. The shipped `sherpa-onnx-c-api.dll` is the official no-TTS build of the same version, which contains no espeak-ng or piper code. `build.ps1` checks the archive and both DLLs against the pinned SHA-256 values above, and the build fails if the published `sherpa-onnx-c-api.dll` contains `espeak_ng_`. Whisper's current Windows runtime documents Windows 11 or Server 2022 and VC++2022. The NoAVX package provides a fallback for CPUs without the normal AVX/AVX2/FMA/F16C instruction set. GPU-specific runtimes are not included.

The supplied application mark is reused from `Resources/SonaAppIcon.png`. ICO packaging resamples the same raster at standard Windows sizes without recoloring, cropping, redraw, or image generation. `assets/provenance.json` records its source hash. Sound cues are Sona's original portable assets from `Resources/Sounds`, not Apple's sound files.

Microsoft references for insertion and privacy:

- https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-registerhotkey
- https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-sendinput
- https://learn.microsoft.com/en-us/dotnet/core/deploying/single-file/overview
- https://support.microsoft.com/en-us/windows/privacy/turn-on-app-permissions-for-your-microphone-in-windows

Sona's application source and original assets are governed by the repository `LICENSE`, shipped as `SONA-LICENSE.txt`. This is separate from the third-party licenses above; those notices and rights are unchanged.
