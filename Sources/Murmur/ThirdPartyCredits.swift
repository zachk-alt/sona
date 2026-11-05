import Foundation

/// Credits shown in Sona's About panel. The full notices are in
/// docs/THIRD-PARTY-MAC.md. The Parakeet model is CC BY 4.0, which asks for
/// credit, a link to the license and a note of any changes; it is not covered
/// by Sona's own license.
enum ThirdPartyCredits {
    static let modelLicenseURL = "https://creativecommons.org/licenses/by/4.0/"

    static let text = """
    Speech recognition on this Mac uses Parakeet Ultra by moondream \
    (https://huggingface.co/moondream/parakeet-ultra), a post-training of NVIDIA's \
    parakeet-tdt-0.6b-v3. Sona downloads a converted copy: FluidInference's Core ML \
    conversion (https://huggingface.co/FluidInference/parakeet-ultra-coreml), with \
    an int8 encoder. Sona itself does not change the model. The model is licensed \
    under CC BY 4.0 (\(modelLicenseURL)), not under Sona's license.

    The model runs through FluidAudio by FluidInference \
    (https://github.com/FluidInference/FluidAudio), Apache License 2.0.

    Apple's on-device speech recognition is the backup engine.

    Sona's own license does not cover third-party code or models; their \
    notices and rights are unchanged.
    """
}
