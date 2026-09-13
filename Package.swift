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

        // Diarisation expérimentale de la piste micro : distingue plusieurs
        // locuteurs partageant un même micro (réunion en présentiel), à partir de
        // traits acoustiques classiques (hauteur, timbre), sans modèle de
        // reconnaissance vocale — Apple n'expose aucune API publique de diarisation.
        .target(
            name: "Diarization",
            dependencies: ["Transcription", "AudioCapture"],
            path: "Sources/Diarization"
        ),

        // Persistance des réunions sur disque.
        .target(
            name: "MeetingStore",
            dependencies: ["Transcription", "Summarization", "AudioCapture"],
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

        // Publication Notion (page enfant d'une page déjà partagée avec l'intégration).
        .target(name: "Notion", path: "Sources/Notion"),

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
                "Summarization", "Atlassian", "SmartMeetCalendar", "Diarization", "Notion",
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
            name: "DiarizationTests",
            dependencies: ["Diarization", "Transcription", "AudioCapture"],
            path: "Tests/DiarizationTests"
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
        .testTarget(
            name: "NotionTests",
            dependencies: ["Notion"],
            path: "Tests/NotionTests"
        ),
    ]
)
