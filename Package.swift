// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SmartMeet",
    platforms: [.macOS(.v26)],
    targets: [
        // Capture audio double piste : micro + audio système (Core Audio process tap).
        .target(name: "AudioCapture", path: "Sources/AudioCapture"),

        // Transcription on-device et fusion des pistes en un transcript diarisé.
        .target(
            name: "Transcription",
            dependencies: ["AudioCapture"],
            path: "Sources/Transcription"
        ),

        // Persistance des réunions sur disque.
        .target(
            name: "MeetingStore",
            dependencies: ["Transcription", "Summarization"],
            path: "Sources/MeetingStore"
        ),

        // Génération du compte rendu : providers LLM interchangeables.
        .target(name: "Summarization", path: "Sources/Summarization"),

        // Publication Confluence et Jira.
        .target(
            name: "Atlassian",
            dependencies: ["Summarization"],
            path: "Sources/Atlassian"
        ),

        // Détection de la réunion en cours : calendrier et applications de visio.
        .target(
            name: "SmartMeetCalendar",
            dependencies: ["AudioCapture"],
            path: "Sources/Calendar"
        ),

        // Application menu-bar.
        .executableTarget(
            name: "SmartMeet",
            dependencies: [
                "AudioCapture", "Transcription", "MeetingStore",
                "Summarization", "Atlassian", "SmartMeetCalendar",
            ],
            path: "Sources/SmartMeetApp",
            exclude: ["Info.plist", "SmartMeet.entitlements"],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/SmartMeetApp/Info.plist",
                ])
            ]
        ),

        .testTarget(
            name: "TranscriptionTests",
            dependencies: ["Transcription", "AudioCapture"],
            path: "Tests/TranscriptionTests"
        ),
        .testTarget(
            name: "DetectionTests",
            dependencies: ["SmartMeetCalendar", "AudioCapture"],
            path: "Tests/DetectionTests"
        ),
        .testTarget(
            name: "SummarizationTests",
            dependencies: ["Summarization", "Atlassian"],
            path: "Tests/SummarizationTests"
        ),

        // Spikes de la phase 0, conservés comme bancs d'essai isolés.
        .executableTarget(
            name: "SpikeTap",
            path: "Spikes/SpikeTap",
            exclude: ["Info.plist", "SpikeTap.entitlements"],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Spikes/SpikeTap/Info.plist",
                ])
            ]
        ),
        .executableTarget(
            name: "SpikeSTT",
            path: "Spikes/SpikeSTT",
            exclude: ["Info.plist", "SpikeSTT.entitlements"],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Spikes/SpikeSTT/Info.plist",
                ])
            ]
        ),
    ]
)
