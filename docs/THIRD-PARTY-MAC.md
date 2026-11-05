# Mac speech engine: third-party code and model

Verified against the primary project pages on 2026-11-04.

| Component | Pin and role | Primary source |
| --- | --- | --- |
| FluidAudio | 0.18.2 (commit `e396cf780c4abf8e395087467c0585d3b0d17f68`), Swift package that runs Parakeet on Core ML; Apache License 2.0. Built with traits off, so its text-to-speech, speaker diarization and prebuilt NeMo text-normalization parts are not compiled or linked | https://github.com/FluidInference/FluidAudio/tree/v0.18.2 and https://www.apache.org/licenses/LICENSE-2.0 |
| fastcluster | C++ clustering code FluidAudio always compiles in (its FastClusterWrapper target); BSD 2-clause, copyright Daniel Müllner and Google Inc. | https://github.com/FluidInference/FluidAudio/blob/v0.18.2/ThirdPartyLicenses/fastcluster-LICENSE.md |
| Parakeet Ultra (Core ML) | FluidInference/parakeet-ultra-coreml at commit `95eaa59a39d4394f047a4dc5cce480388a60d1b6`, 20 files, 632,314,500 bytes, each file's size and SHA-256 fixed in `Sources/Murmur/ParakeetModelStore.swift`; CC BY 4.0 | https://huggingface.co/FluidInference/parakeet-ultra-coreml/tree/95eaa59a39d4394f047a4dc5cce480388a60d1b6 |
| Parakeet Ultra (original) | moondream/parakeet-ultra, a post-training of NVIDIA's parakeet-tdt-0.6b-v3; CC BY 4.0 | https://huggingface.co/moondream/parakeet-ultra and https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3 |
| Apple Speech framework | SpeechAnalyzer and SpeechTranscriber, macOS 26; the backup engine. Part of macOS, not redistributed | https://developer.apple.com/documentation/speech |

## Model credit (CC BY 4.0)

Speech recognition on the Mac uses Parakeet Ultra by moondream, a post-training of NVIDIA's parakeet-tdt-0.6b-v3. Sona uses a converted copy: FluidInference's Core ML conversion, with an int8 encoder (conversion recipe: https://github.com/FluidInference/mobius). Sona does not modify that copy. The model is licensed under Creative Commons Attribution 4.0 International: https://creativecommons.org/licenses/by/4.0/

The model is not part of Sona and is not covered by Sona's license. It is not shipped in the app or this repository. On first launch on a Mac set to English (other languages use Apple's engine and never download it), Sona downloads it once from Hugging Face, from the pinned commit above, checks every file's size and SHA-256, and keeps it in `~/Library/Application Support/Sona/Models/parakeet-ultra/<commit>/`. The About Sona panel in the menu bar shows the same credit.

The app bundle carries FluidAudio's license as `FLUIDAUDIO-LICENSE.txt`, fastcluster's as `FASTCLUSTER-LICENSE.txt` and this file as `THIRD-PARTY-MAC.md`.

Sona's application source and original assets are governed by the repository `LICENSE`. This is separate from the third-party licenses above; those notices and rights are unchanged.
