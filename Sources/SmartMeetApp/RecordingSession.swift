import AudioCapture
import Atlassian
import Foundation
import MeetingStore
import Observation
import SmartMeetCalendar
import Summarization
import Transcription

/// Coordonne capture, transcription, génération du compte rendu et publication.
/// Source de vérité unique de l'interface.
@MainActor
@Observable
public final class RecordingSession {
    public enum State: Equatable {
        case idle
        case preparing
        case recording(since: Date)
        case finishing
        case failed(String)
    }

    public enum SummaryState: Equatable {
        case none
        case running(String)
        case ready
        case failed(String)
    }

    public enum PublishState: Equatable {
        case none
        case running(String)
        case published(url: String, issues: [String], failures: [String])
        case failed(String)
    }

    public private(set) var state: State = .idle
    public private(set) var segments: [TranscriptSegment] = []
    public private(set) var volatileText: [AudioTrack: String] = [:]
    public private(set) var meetings: [Meeting] = []

    public private(set) var summaryState: SummaryState = .none
    public private(set) var publishState: PublishState = .none
    /// Réunion actuellement ouverte dans la fenêtre de relecture.
    public var reviewedMeeting: Meeting?
    public var detectedCalendarMeeting: CalendarMeeting?
    public var searchQuery: String = ""
    /// Type de réunion appliqué au prochain enregistrement.
    public var selectedTemplateID: String

    public let settings: AppSettings
    private let store: MeetingStore
    private let calendar = CalendarService()

    private var recorder: DualTrackRecorder?
    private var transcriber: MeetingTranscriber?
    private var meetingID: UUID?
    private var startedAt: Date?
    private var pipelineTasks: [Task<Void, Never>] = []

    public init(settings: AppSettings = AppSettings()) {
        self.settings = settings
        self.selectedTemplateID = settings.defaultTemplateID
        self.store = MeetingStore(customTemplates: settings.customTemplates)
        meetings = store.loadAll()
    }

    /// Type retenu pour une réunion donnée, avec repli sur le modèle générique si le
    /// modèle personnalisé a été supprimé entre-temps.
    public func template(for meeting: Meeting) -> MeetingTemplate {
        settings.template(id: meeting.templateID)
    }

    public var selectedTemplate: MeetingTemplate {
        settings.template(id: selectedTemplateID)
    }

    // MARK: - État dérivé

    public var isRecording: Bool {
        if case .recording = state { return true }
        return false
    }

    public var isBusy: Bool {
        switch state {
        case .preparing, .finishing: true
        default: false
        }
    }

    public var filteredMeetings: [Meeting] {
        meetings.filter { $0.matches(searchQuery) }
    }

    // MARK: - Enregistrement

    public func toggle() async {
        isRecording ? await stop() : await start()
    }

    /// Interroge le calendrier pour préremplir titre et participants.
    public func refreshCalendarContext() async {
        guard settings.useCalendar else {
            detectedCalendarMeeting = nil
            return
        }
        if !calendar.isAuthorized {
            _ = await calendar.requestAccess()
        }
        detectedCalendarMeeting = calendar.currentMeeting()
    }

    public func start() async {
        guard case .idle = state else { return }
        state = .preparing
        segments = []
        volatileText = [:]
        summaryState = .none
        publishState = .none

        await refreshCalendarContext()

        guard await MicrophoneCapture.requestAccess() else {
            state = .failed("Accès au micro refusé. Réglages › Confidentialité et sécurité › Microphone.")
            return
        }

        let id = UUID()
        meetingID = id
        startedAt = .now

        do {
            let directory = try store.prepareDirectory(for: id)

            let transcriber = MeetingTranscriber(
                locale: settings.locale, vocabulary: settings.vocabulary
            )
            let updates = try await transcriber.start()
            self.transcriber = transcriber

            let recorder = DualTrackRecorder()
            let buffers = try await recorder.start(directory: directory)
            self.recorder = recorder

            pipelineTasks = [
                Task {
                    for await buffer in buffers { await transcriber.append(buffer) }
                },
                Task { @MainActor [weak self] in
                    for await update in updates {
                        self?.segments = update.segments
                        self?.volatileText = update.volatile
                    }
                },
            ]

            state = .recording(since: startedAt ?? .now)
        } catch {
            await teardown()
            state = .failed(error.localizedDescription)
        }
    }

    public func stop() async {
        guard isRecording else { return }
        state = .finishing

        let result = await recorder?.stop()
        let finalSegments = await transcriber?.finish() ?? segments
        segments = finalSegments
        volatileText = [:]

        guard let id = meetingID, let startedAt else {
            await teardown()
            state = .idle
            return
        }

        var meeting = Meeting(
            id: id,
            title: detectedCalendarMeeting?.title ?? Self.defaultTitle(for: startedAt),
            startedAt: startedAt,
            duration: result?.duration ?? 0,
            locale: settings.localeIdentifier,
            knownAttendees: detectedCalendarMeeting?.attendees ?? [],
            templateID: selectedTemplateID
        )
        meeting.trackStartOffsets = Dictionary(
            uniqueKeysWithValues: (result?.trackStartOffsets ?? [:])
                .map { ($0.key.rawValue, $0.value) }
        )

        do {
            try store.save(meeting, segments: finalSegments)
            meetings = store.loadAll()
            reviewedMeeting = meeting
        } catch {
            state = .failed("Enregistrement non sauvegardé : \(error.localizedDescription)")
            await teardown()
            return
        }

        await teardown()
        state = .idle

        if settings.autoSummarize, !finalSegments.isEmpty {
            await generateSummary(for: meeting)
        }
    }

    // MARK: - Compte rendu

    public func generateSummary(for meeting: Meeting) async {
        let transcript = store.transcriptMarkdown(for: meeting.id)
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            summaryState = .failed("Transcript vide.")
            return
        }

        let provider = settings.makeProvider()
        guard await provider.isAvailable() else {
            summaryState = .failed("\(provider.displayName) est indisponible.")
            return
        }

        summaryState = .running("Analyse du transcript…")

        let generator = SummaryGenerator(provider: provider)
        let context = SummaryContext(
            date: meeting.startedAt,
            knownAttendees: meeting.knownAttendees,
            vocabulary: settings.vocabulary,
            userName: settings.userName
        )

        do {
            let summary = try await generator.generate(
                transcript: transcript,
                context: context,
                template: settings.template(id: meeting.templateID)
            ) { progress in
                Task { @MainActor [weak self] in
                    self?.summaryState = .running(Self.describe(progress))
                }
            }
            var updated = meeting
            updated.summary = summary
            if !summary.title.isEmpty { updated.title = summary.title }
            try? store.update(updated)
            meetings = store.loadAll()
            reviewedMeeting = updated
            summaryState = .ready
        } catch {
            summaryState = .failed(error.localizedDescription)
        }
    }

    private static func describe(_ progress: SummaryProgress) -> String {
        switch progress {
        case .preparing: "Préparation…"
        case .summarizingChunk(let index, let total): "Analyse de la tranche \(index)/\(total)…"
        case .synthesizing: "Synthèse finale…"
        case .repairing(let attempt): "JSON non conforme, correction (\(attempt))…"
        }
    }

    /// Enregistre les corrections apportées dans la fenêtre de relecture.
    public func saveReviewedSummary(_ summary: MeetingSummary) {
        guard var meeting = reviewedMeeting else { return }
        meeting.summary = summary
        meeting.title = summary.title.isEmpty ? meeting.title : summary.title
        try? store.update(meeting)
        reviewedMeeting = meeting
        meetings = store.loadAll()
    }

    // MARK: - Publication

    public func publish(_ meeting: Meeting, createJiraIssues: Bool) async {
        guard let summary = meeting.summary else {
            publishState = .failed("Aucun compte rendu à publier.")
            return
        }
        guard settings.canPublish else {
            publishState = .failed("Configuration Atlassian incomplète (site, e-mail, espace, jeton).")
            return
        }

        publishState = .running("Publication…")
        let service = PublishService(
            configuration: settings.atlassian, token: settings.atlassianToken
        )
        let transcript = store.transcriptMarkdown(for: meeting.id)
        let audioNote = "durée \(meeting.formattedDuration), transcription on-device"

        do {
            let result = try await service.publish(
                summary: summary,
                transcript: transcript,
                audioNote: audioNote,
                createJiraIssues: createJiraIssues,
                template: settings.template(id: meeting.templateID)
            ) { step in
                Task { @MainActor [weak self] in
                    self?.publishState = .running(Self.describe(step))
                }
            }

            var updated = meeting
            updated.confluencePageURL = result.pageURL?.absoluteString
            updated.jiraIssueKeys = Array(result.issues.values).sorted()
            if var summary = updated.summary {
                for (identifier, key) in result.issues {
                    if let index = summary.actionItems.firstIndex(where: {
                        $0.id.uuidString == identifier
                    }) {
                        summary.actionItems[index].jiraKey = key
                    }
                }
                updated.summary = summary
            }
            try? store.update(updated)
            meetings = store.loadAll()
            reviewedMeeting = updated

            publishState = .published(
                url: result.pageURL?.absoluteString ?? "",
                issues: updated.jiraIssueKeys,
                failures: result.failures
            )
        } catch {
            publishState = .failed(error.localizedDescription)
        }
    }

    private static func describe(_ step: PublishStep) -> String {
        switch step {
        case .creatingPage: "Création de la page Confluence…"
        case .creatingIssue(let index, let total): "Création du ticket \(index)/\(total)…"
        case .linkingIssues: "Mise à jour de la page avec les clés Jira…"
        case .done: "Terminé"
        }
    }

    // MARK: - Historique

    public func delete(_ meeting: Meeting) {
        try? store.delete(meeting.id)
        meetings = store.loadAll()
        if reviewedMeeting?.id == meeting.id { reviewedMeeting = nil }
    }

    public func directory(for meeting: Meeting) -> URL {
        store.directory(for: meeting.id)
    }

    public func segments(for meeting: Meeting) -> [TranscriptSegment] {
        store.loadSegments(for: meeting.id)
    }

    public func exportMarkdown(for meeting: Meeting) -> String {
        let summary = meeting.summary?.markdown(template: template(for: meeting)) ?? ""
        let transcript = store.transcriptMarkdown(for: meeting.id)
        return summary.isEmpty ? transcript : summary + "\n\n---\n\n" + transcript
    }

    public func openReview(_ meeting: Meeting) {
        reviewedMeeting = meeting
        summaryState = meeting.hasSummary ? .ready : .none
        publishState = meeting.isPublished
            ? .published(url: meeting.confluencePageURL ?? "", issues: meeting.jiraIssueKeys, failures: [])
            : .none
    }

    public func dismissError() {
        if case .failed = state { state = .idle }
    }

    private func teardown() async {
        pipelineTasks.forEach { $0.cancel() }
        pipelineTasks.removeAll()
        recorder = nil
        transcriber = nil
        meetingID = nil
        startedAt = nil
    }

    private static func defaultTitle(for date: Date) -> String {
        "Réunion du \(date.formatted(date: .abbreviated, time: .shortened))"
    }
}
