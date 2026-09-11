import Foundation

// `open` passe un argument -psn_… qu'il faut ignorer.
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
    // Core Audio et Speech ont besoin d'une boucle d'exécution active.
    RunLoop.main.run()
} else if arguments.contains("--summarize-file") {
    // Génère un compte rendu à partir d'un transcript existant, sans rien enregistrer.
    let path = value(after: "--summarize-file") ?? ""
    Task {
        await HeadlessSummarizer.run(
            transcriptPath: path,
            publish: arguments.contains("--publish"),
            templateID: value(after: "--template")
        )
    }
    RunLoop.main.run()
} else if arguments.contains("--set-sprint-page") {
    let input = value(after: "--set-sprint-page") ?? ""
    Task { @MainActor in
        let session = RecordingSession()
        print(await session.setSprintPage(from: input))
        exit(0)
    }
    RunLoop.main.run()
} else {
    SmartMeetApp.main()
}
