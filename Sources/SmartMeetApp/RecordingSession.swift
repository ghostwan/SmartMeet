import AudioCapture
import Atlassian
import Diarization
import Foundation
import MeetingStore
import Notion
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
        case published(url: String, title: String, issues: [String], failures: [String])
        case failed(String)
    }

    public enum NotionPublishState: Equatable {
        case none
        case running
        case published(url: String)
        case failed(String)
    }

    public private(set) var state: State = .idle
    public private(set) var segments: [TranscriptSegment] = []
    public private(set) var volatileText: [AudioTrack: String] = [:]
    public private(set) var meetings: [Meeting] = []

    public private(set) var summaryState: SummaryState = .none
    public private(set) var publishState: PublishState = .none
    public private(set) var notionPublishState: NotionPublishState = .none
    /// Réunion actuellement ouverte dans la fenêtre de relecture.
    public var reviewedMeeting: Meeting?
    public var detectedCalendarMeeting: CalendarMeeting?
    /// Réunion détectée en cours, proposée à l'enregistrement.
    public var suggestion: MeetingSuggestion? { detector.suggestion }
    /// Fenêtre à ouvrir, demandée depuis une notification. La scène SwiftUI est seule
    /// à disposer de `openWindow` ; la session se contente de poser le drapeau.
    public var windowToOpen: String?
    public var searchQuery: String = ""
    /// Type de réunion appliqué au prochain enregistrement.
    public var selectedTemplateID: String
    /// Langue du compte rendu du prochain enregistrement.
    public var selectedOutputLanguage: SummaryLanguage

    public let settings: AppSettings
    private let store: MeetingStore
    private let calendar = CalendarService()
    private let detector: MeetingDetector
    private let notifier = MeetingNotifier()

    private var recorder: DualTrackRecorder?
    private var transcriber: MeetingTranscriber?
    private var meetingID: UUID?
    private var startedAt: Date?
    private var pipelineTasks: [Task<Void, Never>] = []
    private var suggestionObserver: Task<Void, Never>?
    /// Titre issu d'une suggestion acceptée, quand le calendrier ne le fournit pas.
    private var pendingSuggestionTitle: String?

    public init(settings: AppSettings = AppSettings()) {
        self.settings = settings
        self.detector = MeetingDetector()
        self.selectedTemplateID = settings.defaultTemplateID
        self.selectedOutputLanguage = settings.defaultOutputLanguage
        self.store = MeetingStore()
        meetings = store.loadAll()

        notifier.onRecord = { [weak self] in Task { await self?.acceptSuggestion() } }
        notifier.onDismiss = { [weak self] in self?.dismissSuggestion() }
        notifier.onReview = { [weak self] id in self?.openReview(id: id) }
        notifier.onPublish = { [weak self] id in
            Task { await self?.publishFromNotification(id) }
        }
        notifier.onRetrySummary = { [weak self] id in
            Task { await self?.retrySummary(id) }
        }
    }

    /// Démarre la surveillance des réunions. Appelé au lancement de l'application.
    public func startMeetingDetection() async {
        guard settings.detectMeetings else { return }
        if !calendar.isAuthorized { _ = await calendar.requestAccess() }
        await notifier.prepare()
        detector.start()
        observeSuggestions()
    }

    public func stopMeetingDetection() {
        detector.stop()
        suggestionObserver?.cancel()
        suggestionObserver = nil
    }

    /// Réagit à l'apparition d'une suggestion : notification, ou démarrage direct si
    /// l'utilisateur l'a explicitement demandé.
    private func observeSuggestions() {
        suggestionObserver?.cancel()
        suggestionObserver = Task { [weak self] in
            var lastSeen: String?
            while !Task.isCancelled {
                if let self {
                    let current = self.detector.suggestion
                    if current?.id != lastSeen {
                        lastSeen = current?.id
                        if let current, !self.isRecording {
                            if self.settings.autoStartOnDetection {
                                await self.acceptSuggestion()
                            } else {
                                self.notifier.propose(current)
                            }
                        }
                    }
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    /// Démarre l'enregistrement de la réunion proposée, en reprenant son titre et
    /// ses participants.
    public func acceptSuggestion() async {
        guard let suggestion = detector.suggestion else { return }
        notifier.withdraw(suggestion.id)
        detectedCalendarMeeting = suggestion.calendarMeeting
        pendingSuggestionTitle = suggestion.title
        detector.acceptCurrent()
        await start()
    }

    public func dismissSuggestion() {
        if let suggestion = detector.suggestion { notifier.withdraw(suggestion.id) }
        detector.dismissCurrent()
    }

    /// Type retenu pour une réunion donnée, avec repli sur le modèle générique si le
    /// modèle personnalisé a été supprimé entre-temps.
    public func template(for meeting: Meeting) -> MeetingTemplate {
        settings.template(id: meeting.templateID)
    }

    public var selectedTemplate: MeetingTemplate {
        settings.template(id: selectedTemplateID)
    }

    /// Destination lisible, calculée localement sans appel réseau, pour l'afficher
    /// avant de publier.
    public func destinationSummary(for template: MeetingTemplate) -> String {
        let space = template.parent.isSprintPage
            ? (settings.sprintPage?.spaceKey ?? settings.atlassian.spaceKey)
            : (template.spaceKeyOverride.isEmpty ? settings.atlassian.spaceKey : template.spaceKeyOverride)

        guard !space.isEmpty else { return "Destination non configurée" }

        switch template.parent {
        case .sprintPage:
            if let sprint = settings.sprintPage {
                return "\(space) › \(sprint.title)"
            }
            return "\(space) › accueil — aucune page de sprint définie"
        case .page(let id) where !id.isEmpty:
            return "\(space) › page \(id)"
        case .page, .spaceHome:
            return settings.atlassian.parentPageID.isEmpty
                ? "\(space) › accueil de l'espace"
                : "\(space) › page \(settings.atlassian.parentPageID)"
        }
    }

    /// Fixe la page de sprint à partir d'un identifiant ou d'une URL Confluence.
    /// L'espace est déduit de la page, pas saisi à la main.
    public func setSprintPage(from input: String) async -> String {
        guard let pageID = SprintPage.extractPageID(from: input) else {
            return "❌ Identifiant ou URL de page non reconnu."
        }
        guard settings.canPublish else {
            return "❌ Configure d'abord le site, l'e-mail et le jeton Atlassian."
        }

        let client = ConfluenceClient(
            configuration: settings.atlassian, token: settings.atlassianToken
        )
        do {
            let page = try await client.page(id: pageID)
            let spaceKey = try await client.spaceKey(forPage: pageID)
            settings.sprintPage = SprintPage(id: pageID, title: page.title, spaceKey: spaceKey)
            return "✅ \(spaceKey) › \(page.title)"
        } catch {
            return "❌ \(error.localizedDescription)"
        }
    }

    public func clearSprintPage() {
        settings.sprintPage = nil
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
        guard !searchQuery.isEmpty else { return meetings }
        return meetings.filter {
            $0.matches(searchQuery, transcript: store.transcriptMarkdown(for: $0.id))
        }
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
                locale: settings.locale, vocabulary: settings.contextualVocabulary
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
        var finalSegments = await transcriber?.finish() ?? segments

        if settings.diarizeMicrophoneTrack, let result {
            finalSegments = Self.applyDiarization(
                to: finalSegments, recordingDirectory: result.directory,
                trackStartOffsets: result.trackStartOffsets
            )
        }
        segments = finalSegments
        volatileText = [:]

        guard let id = meetingID, let startedAt else {
            await teardown()
            state = .idle
            return
        }

        var meeting = Meeting(
            id: id,
            title: detectedCalendarMeeting?.title
                ?? pendingSuggestionTitle
                ?? Self.defaultTitle(for: startedAt),
            startedAt: startedAt,
            duration: result?.duration ?? 0,
            locale: settings.localeIdentifier,
            knownAttendees: detectedCalendarMeeting?.attendees ?? [],
            templateID: selectedTemplateID,
            outputLanguage: selectedOutputLanguage
        )
        meeting.trackStartOffsets = Dictionary(
            uniqueKeysWithValues: (result?.trackStartOffsets ?? [:])
                .map { ($0.key.rawValue, $0.value) }
        )

        do {
            try store.save(meeting, segments: finalSegments, customTemplates: settings.customTemplates)
            meetings = store.loadAll()
            reviewedMeeting = meeting
        } catch {
            state = .failed("Enregistrement non sauvegardé : \(error.localizedDescription)")
            await teardown()
            return
        }

        await teardown()
        state = .idle
        pendingSuggestionTitle = nil
        // Une nouvelle réunion peut suivre immédiatement : on réarme les propositions.
        detector.resetDismissals()
        notifier.reset()

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
            vocabulary: settings.contextualVocabulary,
            userName: settings.userName
        )

        do {
            let usageBox = UsageBox()
            let summary = try await generator.generate(
                transcript: transcript,
                context: context,
                template: settings.template(id: meeting.templateID),
                language: meeting.outputLanguage
            ) { progress in
                Task { @MainActor [weak self] in
                    self?.summaryState = .running(Self.describe(progress))
                }
            } onUsage: { usage in
                usageBox.add(usage)
            }
            var updated = meeting
            updated.summary = summary
            updated.tokenUsage = usageBox.total
            if !summary.title.isEmpty { updated.title = summary.title }
            try? store.update(updated, customTemplates: settings.customTemplates)
            meetings = store.loadAll()
            reviewedMeeting = updated
            summaryState = .ready

            if settings.autoPublish, settings.canPublish {
                await publish(updated, createJiraIssues: settings.autoCreateJiraIssues)
            } else {
                notifier.announceSummaryReady(
                    meetingID: updated.id,
                    title: updated.title,
                    actionItemCount: summary.actionItems.count
                )
            }
        } catch {
            summaryState = .failed(error.localizedDescription)
            notifier.announceFailure(
                meetingID: meeting.id,
                title: meeting.title,
                message: error.localizedDescription
            )
        }
    }

    /// Ouvre la fenêtre de relecture sur une réunion donnée, depuis une notification.
    private func openReview(id: UUID) {
        guard let meeting = meetings.first(where: { $0.id == id }) else { return }
        openReview(meeting)
        windowToOpen = "review"
    }

    private func retrySummary(_ id: UUID) async {
        guard let meeting = meetings.first(where: { $0.id == id }) else { return }
        openReview(meeting)
        windowToOpen = "review"
        await generateSummary(for: meeting)
    }

    private func publishFromNotification(_ id: UUID) async {
        guard let meeting = meetings.first(where: { $0.id == id }) else { return }
        openReview(meeting)
        await publish(meeting, createJiraIssues: settings.atlassian.isJiraReady)
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
        try? store.update(meeting, customTemplates: settings.customTemplates)
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
        let audioNote = "durée \(meeting.formattedDuration), transcription on-device — "
            + "participants informés de l'enregistrement"

        do {
            let result = try await service.publish(
                summary: summary,
                transcript: transcript,
                audioNote: audioNote,
                createJiraIssues: createJiraIssues,
                template: settings.template(id: meeting.templateID),
                meetingDate: meeting.startedAt,
                language: meeting.outputLanguage
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
            try? store.update(updated, customTemplates: settings.customTemplates)
            meetings = store.loadAll()
            reviewedMeeting = updated

            updated.title = result.pageTitle
            try? store.update(updated, customTemplates: settings.customTemplates)
            meetings = store.loadAll()
            reviewedMeeting = updated

            publishState = .published(
                url: result.pageURL?.absoluteString ?? "",
                title: result.pageTitle,
                issues: updated.jiraIssueKeys,
                failures: result.failures
            )
            notifier.announcePublication(
                meetingID: updated.id,
                title: result.pageTitle,
                url: result.pageURL,
                issues: updated.jiraIssueKeys
            )
        } catch {
            publishState = .failed(error.localizedDescription)
            notifier.announceFailure(
                meetingID: meeting.id,
                title: meeting.title,
                message: error.localizedDescription
            )
        }
    }

    private static func describe(_ step: PublishStep) -> String {
        switch step {
        case .resolvingDestination: "Résolution de la destination…"
        case .creatingPage: "Création de la page Confluence…"
        case .creatingIssue(let index, let total): "Création du ticket \(index)/\(total)…"
        case .linkingIssues: "Mise à jour de la page avec les clés Jira…"
        case .done: "Terminé"
        }
    }

    /// Publie le compte rendu (sections seules, pas le transcript) comme page
    /// Notion, enfant de la page configurée dans les réglages.
    public func publishToNotion(_ meeting: Meeting) async {
        guard let summary = meeting.summary else {
            notionPublishState = .failed("Aucun compte rendu à publier.")
            return
        }
        guard settings.canPublishToNotion else {
            notionPublishState = .failed("Configuration Notion incomplète (page parente, jeton).")
            return
        }

        notionPublishState = .running
        let client = NotionClient(configuration: settings.notion, token: settings.notionToken)
        let template = settings.template(id: meeting.templateID)
        let title = template.pageTitle(
            summaryTitle: summary.title, date: meeting.startedAt, language: meeting.outputLanguage
        )
        let markdown = summary.markdown(template: template, language: meeting.outputLanguage)

        do {
            let page = try await client.createPage(title: title, markdown: markdown)
            var updated = meeting
            updated.notionPageURL = page.url?.absoluteString
            try? store.update(updated, customTemplates: settings.customTemplates)
            meetings = store.loadAll()
            reviewedMeeting = updated
            notionPublishState = .published(url: page.url?.absoluteString ?? "")
        } catch {
            notionPublishState = .failed(error.localizedDescription)
        }
    }

    // MARK: - Historique

    public func delete(_ meeting: Meeting) {
        try? store.delete(meeting.id)
        meetings = store.loadAll()
        if reviewedMeeting?.id == meeting.id { reviewedMeeting = nil }
    }

    /// Vrai si l'audio brut de cette réunion est encore sur disque.
    public func hasRawRecording(for meeting: Meeting) -> Bool {
        store.hasRawRecording(for: meeting.id)
    }

    /// Supprime l'audio et le transcript d'une réunion, en gardant le compte rendu.
    /// Pensé pour l'utilisateur qui a relu son compte rendu, l'a jugé fidèle, et ne
    /// veut plus garder l'enregistrement brut. Irréversible.
    @discardableResult
    public func deleteRawRecording(for meeting: Meeting) -> String {
        do {
            try store.deleteRawRecording(for: meeting.id)
        } catch {
            return "Échec de la suppression : \(error.localizedDescription)"
        }
        if reviewedMeeting?.id == meeting.id { segments = [] }
        meetings = store.loadAll()
        return "Audio et transcript supprimés. Le compte rendu est conservé."
    }

    public func directory(for meeting: Meeting) -> URL {
        store.directory(for: meeting.id)
    }

    public func segments(for meeting: Meeting) -> [TranscriptSegment] {
        store.loadSegments(for: meeting.id)
    }

    /// Réapplique la diarisation expérimentale de la piste micro sur une réunion
    /// déjà enregistrée — utile pour les réunions capturées avant l'activation du
    /// réglage, ou pour retenter après un échec. Réécrit `segments.json` et
    /// `transcript.md` ; ne touche pas au compte rendu déjà généré ni à l'audio.
    @discardableResult
    public func rediarize(_ meeting: Meeting) async -> String {
        let existing = store.loadSegments(for: meeting.id)
        guard !existing.isEmpty else {
            return "Aucun transcript à réanalyser pour cette réunion."
        }
        let audioURL = directory(for: meeting).appending(path: AudioTrack.microphone.fileName)
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            return "Piste micro introuvable (\(AudioTrack.microphone.fileName))."
        }
        let offset = meeting.trackStartOffsets[AudioTrack.microphone.rawValue] ?? 0

        guard let mapping = try? MicrophoneDiarizer.diarize(
            segments: existing, audioFileURL: audioURL, fileTimeOffset: offset
        ) else {
            return "Aucune séparation nette trouvée — probablement une seule voix, "
                + "ou pas assez de segments micro."
        }

        let updated = existing.map { segment -> TranscriptSegment in
            guard let label = mapping[segment.id] else { return segment }
            var copy = segment
            copy.speakerOverride = label
            return copy
        }

        do {
            try store.updateSegments(
                updated, for: meeting.id, title: meeting.title, date: meeting.startedAt
            )
        } catch {
            return "Échec de l'enregistrement : \(error.localizedDescription)"
        }

        segments = updated
        meetings = store.loadAll()
        let speakerCount = Set(mapping.values).count
        return "\(speakerCount) locuteur\(speakerCount > 1 ? "s" : "") distingué\(speakerCount > 1 ? "s" : "") sur la piste micro."
    }

    public func exportMarkdown(for meeting: Meeting) -> String {
        let summary = meeting.summary?.markdown(
            template: template(for: meeting), language: meeting.outputLanguage
        ) ?? ""
        let transcript = store.transcriptMarkdown(for: meeting.id)
        return summary.isEmpty ? transcript : summary + "\n\n---\n\n" + transcript
    }

    public func openReview(_ meeting: Meeting) {
        reviewedMeeting = meeting
        summaryState = meeting.hasSummary ? .ready : .none
        publishState = meeting.isPublished
            ? .published(
                url: meeting.confluencePageURL ?? "",
                title: meeting.title,
                issues: meeting.jiraIssueKeys,
                failures: []
            )
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

    /// Distingue jusqu'à deux locuteurs sur la piste micro, pour les réunions en
    /// présentiel où plusieurs personnes parlent dans le même micro. Échoue en
    /// silence (retourne les segments inchangés) : une diarisation ratée ne doit pas
    /// faire perdre un enregistrement.
    private static func applyDiarization(
        to segments: [TranscriptSegment],
        recordingDirectory: URL,
        trackStartOffsets: [AudioTrack: TimeInterval]
    ) -> [TranscriptSegment] {
        let audioURL = recordingDirectory.appending(path: AudioTrack.microphone.fileName)
        let offset = trackStartOffsets[.microphone] ?? 0
        guard let mapping = try? MicrophoneDiarizer.diarize(
            segments: segments, audioFileURL: audioURL, fileTimeOffset: offset
        ) else {
            return segments
        }
        return segments.map { segment in
            guard let label = mapping[segment.id] else { return segment }
            var updated = segment
            updated.speakerOverride = label
            return updated
        }
    }
}
