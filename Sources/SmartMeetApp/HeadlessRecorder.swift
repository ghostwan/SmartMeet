import Atlassian
import AudioCapture
import Foundation
import MeetingStore
import Summarization
import Transcription

/// UI-less mode: records for N seconds, transcribes, saves, and prints a
/// report. Used for end-to-end testing and field diagnostics.
///
///     SmartMeet --headless <secondes> [dossier de rapport]
@MainActor
enum HeadlessRecorder {
    static func run(
        duration: TimeInterval,
        reportDirectory: URL?,
        summarize: Bool = false,
        publish: Bool = false
    ) async {
        var report: [String] = [
            "SmartMeet headless — \(Date().formatted())",
            "durée demandée : \(Int(duration)) s",
        ]

        func emit(_ line: String) {
            print(line)
            report.append(line)
            if let reportDirectory {
                try? FileManager.default.createDirectory(
                    at: reportDirectory, withIntermediateDirectories: true
                )
                try? report.joined(separator: "\n").write(
                    to: reportDirectory.appending(path: "headless-report.txt"),
                    atomically: true,
                    encoding: .utf8
                )
            }
        }

        guard await MicrophoneCapture.requestAccess() else {
            emit("❌ accès micro refusé")
            exit(1)
        }
        emit("✅ accès micro accordé")

        let store = MeetingStore()
        let id = UUID()
        let startedAt = Date()

        do {
            let directory = try store.prepareDirectory(for: id)
            emit("dossier : \(directory.path)")

            let transcriber = MeetingTranscriber(
                locale: Locale(identifier: "fr-FR"),
                vocabulary: ["Confluence", "Jira", "SmartMeet"]
            )
            emit("préparation des modèles…")
            let updates = try await transcriber.start()
            emit("✅ modèles prêts")

            let recorder = DualTrackRecorder()
            let buffers = try await recorder.start(directory: directory)
            emit("annulation d'écho : \(await recorder.echoCancellationEnabled ? "active" : "indisponible")")
            emit("▶︎ enregistrement — parle dans le micro ET fais jouer du son système")

            let pump = Task {
                for await buffer in buffers { await transcriber.append(buffer) }
            }
            let observer = Task {
                for await update in updates {
                    _ = update.segments.count
                }
            }

            try await Task.sleep(for: .seconds(duration))

            let result = await recorder.stop()
            let segments = await transcriber.finish()
            pump.cancel()
            observer.cancel()

            var meeting = Meeting(
                id: id,
                title: "Test headless",
                startedAt: startedAt,
                duration: result.duration,
                locale: "fr-FR"
            )
            meeting.trackStartOffsets = Dictionary(
                uniqueKeysWithValues: result.trackStartOffsets.map { ($0.key.rawValue, $0.value) }
            )
            try store.save(meeting, segments: segments)

            emit("")
            emit("— Résultat —")
            emit("durée réelle : \(String(format: "%.2f", result.duration)) s")
            for track in AudioTrack.allCases {
                let frames = result.frameCounts[track] ?? 0
                let offset = result.trackStartOffsets[track]
                let url = directory.appending(path: track.fileName)
                let size = ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int) ?? 0
                let status = frames > 0 ? "✅" : "❌"
                emit(
                    "\(status) \(track.rawValue) : \(frames) frames, \(size / 1024) Ko, "
                        + "démarrage à +\(String(format: "%.0f", (offset ?? 0) * 1000)) ms"
                )
            }

            let drift = abs(
                (result.trackStartOffsets[.microphone] ?? 0)
                    - (result.trackStartOffsets[.system] ?? 0)
            )
            emit("écart de démarrage entre pistes : \(String(format: "%.0f", drift * 1000)) ms (compensé)")

            emit("")
            emit(segments.isEmpty ? "⚠️ aucun segment transcrit" : "✅ \(segments.count) segments")
            for segment in segments.prefix(30) {
                emit("  [\(segment.timecode)] \(segment.speaker) : \(segment.text)")
            }

            if summarize, !segments.isEmpty {
                emit("")
                await summarizeAndPublish(
                    meeting: meeting,
                    transcript: segments.markdown(title: meeting.title, date: meeting.startedAt),
                    store: store,
                    publish: publish,
                    emit: emit
                )
            }
        } catch {
            emit("❌ \(error.localizedDescription)")
            exit(1)
        }

        exit(0)
    }

    private static func summarizeAndPublish(
        meeting: Meeting,
        transcript: String,
        store: MeetingStore,
        publish: Bool,
        emit: (String) -> Void
    ) async {
        let settings = AppSettings()
        let provider = settings.makeProvider()
        emit("provider : \(provider.displayName)")
        guard await provider.isAvailable() else {
            emit("⚠️ provider indisponible, compte rendu ignoré")
            return
        }

        do {
            let template = settings.template(id: meeting.templateID)
            let usageBox = UsageBox()
            let summary = try await SummaryGenerator(provider: provider).generate(
                transcript: transcript,
                context: SummaryContext(
                    date: meeting.startedAt,
                    knownAttendees: meeting.knownAttendees,
                    vocabulary: settings.contextualVocabulary,
                    userName: settings.userName
                ),
                template: template,
                language: meeting.outputLanguage
            ) { _ in
            } onUsage: { usage in
                usageBox.add(usage)
            }
            var updated = meeting
            updated.summary = summary
            updated.tokenUsage = usageBox.total
            updated.title = summary.title.isEmpty ? meeting.title : summary.title
            try? store.update(updated)

            emit("✅ compte rendu : « \(summary.title) »")
            emit("   \(summary.decisions.count) décisions, \(summary.actionItems.count) action items")
            if let totalUsage = usageBox.total { emit("   tokens : \(totalUsage.formatted)") }

            guard publish, settings.canPublish else { return }
            let translateForJira: (@Sendable (String) async throws -> String)?
            if settings.atlassian.isJiraReady, meeting.outputLanguage != .english {
                translateForJira = { text in try await Translator.toEnglish(text, using: provider) }
            } else {
                translateForJira = nil
            }
            let result = try await PublishService(
                configuration: settings.atlassian, token: settings.atlassianToken
            ).publish(
                summary: summary,
                transcript: transcript,
                audioNote: "durée \(meeting.formattedDuration)",
                createJiraIssues: settings.atlassian.isJiraReady,
                template: template,
                language: meeting.outputLanguage,
                translateForJira: translateForJira
            )
            emit("✅ publié : \(result.pageURL?.absoluteString ?? result.pageID)")
            if let searchURL = result.jiraSearchURL {
                emit("   tickets Jira : \(searchURL.absoluteString)")
            }
        } catch {
            emit("⚠️ compte rendu impossible — \(error.localizedDescription)")
        }
    }
}
