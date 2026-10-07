// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Murmur",
    platforms: [.macOS("26.0")],
    targets: [
        // Converts AVFAudio's Objective-C exceptions into Swift errors.
        .target(name: "SonaObjC", path: "Sources/SonaObjC"),
        .executableTarget(
            name: "Murmur",
            dependencies: ["SonaObjC"],
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
