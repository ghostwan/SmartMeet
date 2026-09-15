import Foundation
import Summarization

// `open` passes a -psn_… argument that must be ignored.
let arguments = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-psn_") }

func value(after flag: String) -> String? {
    guard let index = arguments.firstIndex(of: flag) else { return nil }
    return arguments[arguments.index(after: index)...].first
}

if let index = arguments.firstIndex(of: "--headless") {
    let remaining = arguments[arguments.index(after: index)...]
    let duration = remaining.first.flatMap(Double.init) ?? 20
    let reportDirectory = remaining.dropFirst().first
        .flatMap { $0.hasPrefix("--") ? nil : URL(filePath: $0) }

    Task {
        await HeadlessRecorder.run(
            duration: duration,
            reportDirectory: reportDirectory,
            summarize: arguments.contains("--summarize"),
            publish: arguments.contains("--publish")
        )
    }
    // Core Audio and Speech need an active run loop.
    RunLoop.main.run()
} else if arguments.contains("--summarize-file") {
    // Generates meeting minutes from an existing transcript, without recording anything.
    let path = value(after: "--summarize-file") ?? ""
    Task {
        await HeadlessSummarizer.run(
            transcriptPath: path,
            publish: arguments.contains("--publish"),
            templateID: value(after: "--template"),
            language: SummaryLanguage(rawValue: value(after: "--lang") ?? "fr") ?? .french
        )
    }
    RunLoop.main.run()
} else if arguments.contains("--check-notifications") {
    NotificationCheck.boot(reportPath: value(after: "--check-notifications"))
} else if arguments.contains("--set-sprint-page") {
    let input = value(after: "--set-sprint-page") ?? ""
    Task { @MainActor in
        let session = RecordingSession()
        print(await session.setSprintPage(from: input))
        exit(0)
    }
    RunLoop.main.run()
} else if arguments.contains("--rediarize") {
    let meetingIDString = value(after: "--rediarize") ?? ""
    Task { @MainActor in
        let session = RecordingSession()
        guard let id = UUID(uuidString: meetingIDString),
              let meeting = session.meetings.first(where: { $0.id == id })
        else {
            print("❌ Réunion introuvable : \(meetingIDString)")
            exit(1)
        }
        print(await session.rediarize(meeting))
        exit(0)
    }
    RunLoop.main.run()
} else {
    SmartMeetApp.main()
}
