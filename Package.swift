// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Murmur",
    platforms: [.macOS("26.0")],
    dependencies: [
        // Parakeet speech engine runtime (Apache-2.0), pinned to the version the
        // 2026-11-04 accuracy audit measured (tag 0.18.2, commit e396cf7).
        // traits: [] leaves out text-to-speech, speaker diarization and the
        // prebuilt NeMo text-normalization binary; Sona uses speech-to-text only.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.18.2", traits: []),
    ],
    targets: [
        // Converts AVFAudio's Objective-C exceptions into Swift errors.
        .target(name: "SonaObjC", path: "Sources/SonaObjC"),
        .executableTarget(
            name: "Murmur",
            dependencies: [
                "SonaObjC",
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "Sources/Murmur",
            // Retired second-hotkey, screen capture and computer-control code is not shipped.
            exclude: [
                "AssistantAXReadPolicy.swift",
                "AssistantAccessibilityPreparation.swift",
                "AssistantActions.swift",
                "AssistantActionsSelfTest.swift",
                "AssistantCaptureDeadline.swift",
                "AssistantCapturePolicy.swift",
                "AssistantClickDiagnostics.swift",
                "AssistantClickSelfTest.swift",
                "AssistantCursor.swift",
                "AssistantHandoffSelfTest.swift",
                "AssistantLaunchDispatch.swift",
                "AssistantModelMenu.swift",
                "AssistantPanel.swift",
                "AssistantScreenCapture.swift",
                "AssistantSemanticSearch.swift",
                "AssistantSurfaceSelfTest.swift",
                "AssistantWait.swift",
                "AssistantWindowPolicy.swift",
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
