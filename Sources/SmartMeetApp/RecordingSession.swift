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

/// Coordinates capture, transcription, minutes generation, and publication.
/// The single source of truth for the UI.
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
        case published(url: String, title: String, issues: [String], failures: [String], jiraSearchURL: String?)
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
    /// Meeting currently open in the review window.
    public var reviewedMeeting: Meeting?
    public var detectedCalendarMeeting: CalendarMeeting?
    /// Meeting currently detected, offered up for recording.
    public var suggestion: MeetingSuggestion? { detector.suggestion }
    /// Window to open, requested from a notification. Only the SwiftUI scene
    /// has access to `openWindow`; the session just sets the flag.
    public var windowToOpen: String?
    public var searchQuery: String = ""
    /// Meeting type applied to the next recording.
    public var selectedTemplateID: String
    /// Language of the minutes for the next recording.
    public var selectedOutputLanguage: SummaryLanguage
    /// Spoken (source) language expected for the next recording — distinct
    /// from the minutes' language above. The transcription engine doesn't
    /// handle a language change mid-meeting: it must be fixed before
    /// starting.
    public var selectedTranscriptionLocale: String
    /// Other party for the next recording, for "one-to-one" types
    /// (`MeetingTemplate.requiresParticipant`). Ignored for any other type.
    public var oneToOneParticipantName: String = ""
    /// E-mail of this other party — optional, only used to restrict the
    /// published Confluence page to the user and this one person.
    public var oneToOneParticipantEmail: String = ""
    /// Confluence `accountId` of this other party, set when picked from the
    /// "search Confluence users" results rather than typed by hand — a more
    /// reliable path to restrict the page than the e-mail search.
    public var oneToOneParticipantAccountID: String = ""
    /// Publication destination for the next recording, carried over from a
    /// configured `OneToOnePerson`. `nil` defers to the meeting type's own
    /// destination.
    public var oneToOneDestination: PublicationDestination?
    /// E-mail to add as a watcher on every Jira ticket created for the next
    /// recording, carried over from a configured `OneToOnePerson`.
    public var oneToOneJiraShareEmail: String = ""

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
    /// Title from an accepted suggestion, when the calendar doesn't provide one.
    private var pendingSuggestionTitle: String?
    /// Video-conferencing app whose microphone use is being monitored during
    /// recording, in order to suggest the meeting's end. `nil` if no known
    /// app was identified (recording started manually with no detected video call).
    private var monitoredConferencingApp: String?
    private var endOfMeetingObserver: Task<Void, Never>?
    /// Since when the tracked app has stopped picking up the microphone. Reset
    /// to `nil` as soon as it picks it up again: a transient interruption
    /// shouldn't count.
    private var conferencingAppAbsentSince: Date?
    /// Prevents re-notifying in a loop as long as the absence continues
    /// without the user having responded.
    private var meetingEndNotified = false
    /// Set when the user responds "keep recording": won't come back before
    /// this delay, even if the tracked app remains absent in the meantime.
    private var meetingEndSnoozedUntil: Date?

    /// Interval between two end-of-meeting checks.
    private static let endOfMeetingCheckInterval: Double = 10
    /// Duration of continuous microphone absence before suggesting the
    /// meeting's end — a network hiccup or a mic muted for a moment
    /// shouldn't be enough.
    private static let endOfMeetingGracePeriod: Double = 90
    /// Delay before suggesting again, once the user has chosen to continue.
    private static let endOfMeetingSnooze: Double = 300

    public init(settings: AppSettings = AppSettings()) {
        self.settings = settings
        self.detector = MeetingDetector()
        self.selectedTemplateID = settings.defaultTemplateID
        self.selectedOutputLanguage = settings.defaultOutputLanguage
        self.selectedTranscriptionLocale = settings.localeIdentifier
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
        notifier.onMeetingEndedGenerateSummary = { [weak self] in
            Task { await self?.stopAndGenerateSummaryFromNotification() }
        }
        notifier.onMeetingEndedKeepRecording = { [weak self] in
            self?.snoozeMeetingEndDetection()
        }
    }

    /// Switches every session-level selection and background behavior to the
    /// chosen profile in one operation. Those values are intentionally copied
    /// out of `AppSettings` while the user prepares a recording, so changing
    /// only `activeProfileID` would otherwise leave the meeting type and both
    /// languages pointing at the previous profile until the app is relaunched.
    public func selectProfile(_ id: String) {
        guard !isRecording,
              settings.profiles.contains(where: { $0.id == id })
        else { return }

        stopMeetingDetection()
        settings.activeProfileID = id
        selectedTemplateID = settings.defaultTemplateID
        selectedOutputLanguage = settings.defaultOutputLanguage
        selectedTranscriptionLocale = settings.localeIdentifier

        Task { await startMeetingDetection() }
    }

    /// Starts meeting surveillance. Called at app launch.
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

    /// Reacts to a suggestion appearing: notification, or direct start if
    /// the user explicitly requested it.
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
                            self.applyInferredTemplate(fromTitle: current.title)
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

    /// Monitors, during recording, whether the tracked video-conferencing app
    /// still picks up the microphone. A continuous absence beyond a grace
    /// period suggests (never forces) generating the minutes — see
    /// `endOfMeetingGracePeriod` for the reasoning on transient interruptions.
    private func observeMeetingEnd() {
        endOfMeetingObserver?.cancel()
        guard settings.detectMeetingEnd, let appName = monitoredConferencingApp else { return }

        endOfMeetingObserver = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.endOfMeetingCheckInterval))
                guard let self, self.isRecording else { return }

                let stillActive = ConferencingDetector.activeApps()
                    .contains { $0.name == appName }
                if stillActive {
                    self.conferencingAppAbsentSince = nil
                    self.meetingEndNotified = false
                    continue
                }

                if let snoozedUntil = self.meetingEndSnoozedUntil, Date.now < snoozedUntil {
                    continue
                }
                let absentSince = self.conferencingAppAbsentSince ?? Date.now
                self.conferencingAppAbsentSince = absentSince

                guard !self.meetingEndNotified,
                      Date.now.timeIntervalSince(absentSince) >= Self.endOfMeetingGracePeriod,
                      let meetingID = self.meetingID
                else { continue }

                self.meetingEndNotified = true
                self.notifier.announceMeetingEnded(meetingID: meetingID)
            }
        }
    }

    /// Response to the "Generate minutes" action from the end-of-meeting
    /// notification: stops the recording, then generates the minutes even if
    /// `autoSummarize` is off — the user just explicitly requested it by
    /// tapping the action, this is no longer a decision made on their behalf.
    private func stopAndGenerateSummaryFromNotification() async {
        guard isRecording else { return }
        let shouldForceSummary = !settings.autoSummarize
        await stop()
        if shouldForceSummary, let meeting = reviewedMeeting {
            await generateSummary(for: meeting)
        }
    }

    /// Response to the "Keep recording" action: only postpones the next
    /// suggestion, so as not to re-trigger a notification on every cycle
    /// while the video call remains off.
    private func snoozeMeetingEndDetection() {
        meetingEndSnoozedUntil = Date.now.addingTimeInterval(Self.endOfMeetingSnooze)
        meetingEndNotified = false
        conferencingAppAbsentSince = nil
    }

    /// Guesses the meeting type from a title (calendar or conferencing app) and
    /// applies it — but only if the user hasn't already picked a type by hand from
    /// the menu. The default template acts as a "still untouched" marker: as soon
    /// as it changes, whether by this inference or by the user, it's never
    /// automatically overridden again.
    private func applyInferredTemplate(fromTitle title: String) {
        guard selectedTemplateID == settings.defaultTemplateID else { return }
        guard let inferred = MeetingTemplate.infer(fromTitle: title, in: settings.allTemplates) else {
            return
        }
        selectedTemplateID = inferred.id
    }

    /// Starts recording the suggested meeting, reusing its title and
    /// attendees.
    public func acceptSuggestion() async {
        guard let suggestion = detector.suggestion else { return }
        notifier.withdraw(suggestion.id)
        detectedCalendarMeeting = suggestion.calendarMeeting
        pendingSuggestionTitle = suggestion.title
        monitoredConferencingApp = suggestion.appName
        detector.acceptCurrent()
        await start()
    }

    public func dismissSuggestion() {
        if let suggestion = detector.suggestion { notifier.withdraw(suggestion.id) }
        detector.dismissCurrent()
    }

    /// Type retained for a given meeting, falling back to the generic
    /// template if the custom template was deleted in the meantime.
    public func template(for meeting: Meeting) -> MeetingTemplate {
        settings.template(id: meeting.templateID)
    }

    public var selectedTemplate: MeetingTemplate {
        settings.template(id: selectedTemplateID)
    }

    /// Candidates suggested for "with whom" on a one-to-one: calendar
    /// attendees first (they carry a usable e-mail for later restricting the
    /// page), then known people from settings, as a fallback — without an
    /// e-mail, the page can only be restricted to the user alone.
    public var oneToOneCandidates: [(name: String, email: String?)] {
        var seen = Set<String>()
        var candidates: [(name: String, email: String?)] = []
        for attendee in detectedCalendarMeeting?.attendeeDetails ?? [] {
            guard seen.insert(attendee.name).inserted else { continue }
            candidates.append((attendee.name, attendee.email))
        }
        for name in settings.knownPeople {
            guard seen.insert(name).inserted else { continue }
            candidates.append((name, nil))
        }
        return candidates
    }

    /// Quick "who is this" lookup against Confluence itself, for the
    /// one-to-one counterpart picker — faster and more reliable than typing
    /// (and hoping the e-mail search finds) an e-mail address by hand.
    /// Best effort: an empty array on any failure (offline, misconfigured
    /// Atlassian settings…) rather than surfacing an error from what's meant
    /// to be a lightweight, as-you-type search.
    public func searchConfluenceUsers(matching query: String) async -> [ConfluenceUserMatch] {
        guard settings.canPublish else { return [] }
        let client = ConfluenceClient(configuration: settings.atlassian, token: settings.atlassianToken)
        return (try? await client.searchUsers(matching: query)) ?? []
    }

    /// Fills in the one-to-one fields from a Confluence search result: the
    /// `accountId` is kept alongside, so publication can restrict the page
    /// without going through the less reliable e-mail search.
    public func selectOneToOneParticipant(_ match: ConfluenceUserMatch) {
        oneToOneParticipantName = match.displayName
        oneToOneParticipantEmail = match.email ?? ""
        oneToOneParticipantAccountID = match.accountID
    }

    /// Fills in every one-to-one field from a person configured in Settings:
    /// name, restriction e-mail/accountId, publication destination and Jira
    /// share e-mail — the whole point of configuring them once being to pick
    /// a name instead of retyping all of this at every recording.
    public func selectOneToOnePerson(_ person: OneToOnePerson) {
        oneToOneParticipantName = person.name
        oneToOneParticipantEmail = person.email
        oneToOneParticipantAccountID = person.confluenceAccountID
        oneToOneDestination = person.destination == .profileDefault ? nil : person.destination
        oneToOneJiraShareEmail = person.jiraShareEmail
    }

    /// Readable destination, computed locally with no network call, to
    /// display before publishing.
    public func destinationSummary(for template: MeetingTemplate) -> String {
        guard let service = settings.publicationServiceKind(for: template) else {
            if let explicit = template.serviceKind {
                return L("%@ n'est plus activé pour ce profil", explicit.displayName)
            }
            return L("Aucun service de publication sélectionné")
        }
        return destinationSummary(service: service, destination: template.destination)
    }

    public func destinationSummary(
        service: ServiceKind,
        destination: PublicationDestination
    ) -> String {
        if case .page(let id) = destination, !id.isEmpty {
            return L("%@ › page %@", service.displayName, id)
        }
        if service == .notion {
            guard settings.canPublishToNotion else { return L("Notion › configuration incomplète") }
            let parent = settings.notion.parentPageTitle.isEmpty
                ? settings.notion.parentPageID
                : settings.notion.parentPageTitle
            return parent.isEmpty ? L("Notion › pages privées") : "Notion › \(parent)"
        }
        guard settings.canPublish else { return L("Confluence › configuration incomplète") }
        return settings.atlassian.parentPageID.isEmpty
            ? L("Confluence › espace personnel")
            : L("Confluence › page %@", settings.atlassian.parentPageID)
    }

    // MARK: - Derived state

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

    // MARK: - Recording

    public func toggle() async {
        isRecording ? await stop() : await start()
    }

    /// Queries the calendar to pre-fill the title and attendees.
    public func refreshCalendarContext() async {
        guard settings.useCalendar else {
            detectedCalendarMeeting = nil
            return
        }
        if !calendar.isAuthorized {
            _ = await calendar.requestAccess()
        }
        detectedCalendarMeeting = calendar.currentMeeting()
        if let title = detectedCalendarMeeting?.title {
            applyInferredTemplate(fromTitle: title)
        }
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
            state = .failed(L("Accès au micro refusé. Réglages › Confidentialité et sécurité › Microphone."))
            return
        }

        let id = UUID()
        meetingID = id
        startedAt = .now

        // If the start didn't go through a suggestion (manual button), still
        // try to spot an already-active video-conferencing app, so the
        // meeting's end can be suggested later.
        if monitoredConferencingApp == nil {
            monitoredConferencingApp = ConferencingDetector.activeApps().first?.name
        }
        conferencingAppAbsentSince = nil
        meetingEndNotified = false
        meetingEndSnoozedUntil = nil

        do {
            let directory = try store.prepareDirectory(for: id)

            settings.recordTranscriptionLocaleUsed(selectedTranscriptionLocale)
            let transcriber = MeetingTranscriber(
                locale: Locale(identifier: selectedTranscriptionLocale),
                vocabulary: settings.contextualVocabulary
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
            observeMeetingEnd()
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
            locale: selectedTranscriptionLocale,
            knownAttendees: detectedCalendarMeeting?.attendees ?? [],
            // Pre-filled from the same calendar source as a starting point,
            // but this one is meant to be corrected by the user before
            // generation — see `setConfirmedParticipants`.
            confirmedParticipants: detectedCalendarMeeting?.attendees ?? [],
            templateID: selectedTemplateID,
            outputLanguage: selectedOutputLanguage,
            oneToOneParticipant: selectedTemplate.requiresParticipant && !oneToOneParticipantName.isEmpty
                ? oneToOneParticipantName : nil,
            oneToOneParticipantEmail: selectedTemplate.requiresParticipant && !oneToOneParticipantEmail.isEmpty
                ? oneToOneParticipantEmail : nil,
            oneToOneParticipantAccountID: selectedTemplate.requiresParticipant && !oneToOneParticipantAccountID.isEmpty
                ? oneToOneParticipantAccountID : nil,
            oneToOneDestination: selectedTemplate.requiresParticipant ? oneToOneDestination : nil,
            oneToOneJiraShareEmail: selectedTemplate.requiresParticipant && !oneToOneJiraShareEmail.isEmpty
                ? oneToOneJiraShareEmail : nil,
            restrictedViewers: selectedTemplate.defaultRestrictedViewers
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
            state = .failed(L("Enregistrement non sauvegardé : %@", error.localizedDescription))
            await teardown()
            return
        }

        await teardown()
        state = .idle
        pendingSuggestionTitle = nil
        oneToOneParticipantName = ""
        oneToOneParticipantEmail = ""
        oneToOneParticipantAccountID = ""
        oneToOneDestination = nil
        oneToOneJiraShareEmail = ""
        // A new meeting can follow right away: reset the dismissed suggestions.
        detector.resetDismissals()
        notifier.reset()

        if settings.autoSummarize, !finalSegments.isEmpty {
            await generateSummary(for: meeting)
        }
    }

    // MARK: - Minutes

    public func generateSummary(for meeting: Meeting) async {
        let transcript = store.transcriptMarkdown(for: meeting.id)
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            summaryState = .failed(L("Transcript vide."))
            return
        }

        let provider = settings.makeProvider()
        guard await provider.isAvailable() else {
            summaryState = .failed(L("%@ est indisponible.", provider.displayName))
            return
        }

        summaryState = .running(L("Analyse du transcript…"))

        let generator = SummaryGenerator(provider: provider)
        let context = SummaryContext(
            date: meeting.startedAt,
            knownAttendees: meeting.knownAttendees,
            confirmedParticipants: meeting.confirmedParticipants,
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

            let template = settings.template(id: updated.templateID)
            if settings.autoPublish, settings.canAutoPublish(template: template) {
                await publishAutomatically(updated)
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

    /// Opens the review window on a given meeting, from a notification.
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
        let template = settings.template(id: meeting.templateID)
        guard settings.canAutoPublish(template: template) else { return }
        await publishAutomatically(meeting)
    }

    private func publishAutomatically(_ meeting: Meeting) async {
        let template = settings.template(id: meeting.templateID)
        switch settings.publicationServiceKind(for: template) {
        case .atlassian:
            await publish(
                meeting,
                createJiraIssues: settings.autoCreateJiraIssues
                    && settings.atlassian.isJiraReady
            )
        case .notion:
            await publishToNotion(
                meeting,
                createTasks: settings.autoCreateNotionTasks
            )
        case nil:
            break
        }
    }

    private static func describe(_ progress: SummaryProgress) -> String {
        switch progress {
        case .preparing: L("Préparation…")
        case .summarizingChunk(let index, let total): L("Analyse de la tranche %d/%d…", index, total)
        case .synthesizing: L("Synthèse finale…")
        case .repairing(let attempt): L("JSON non conforme, correction (%d)…", attempt)
        }
    }

    /// Saves the edits made in the review window.
    public func saveReviewedSummary(_ summary: MeetingSummary) {
        guard var meeting = reviewedMeeting else { return }
        meeting.summary = summary
        meeting.title = summary.title.isEmpty ? meeting.title : summary.title
        try? store.update(meeting, customTemplates: settings.customTemplates)
        reviewedMeeting = meeting
        meetings = store.loadAll()
    }

    /// Changes the meeting type of an already-recorded meeting — used before
    /// a regeneration, when the type originally chosen turns out unsuitable
    /// (e.g. a personal conversation recorded by mistake with a work-related
    /// type). Doesn't request minutes on its own: it's up to the caller to
    /// call `generateSummary` afterward if needed.
    public func setTemplate(_ templateID: String, for meeting: Meeting) {
        var updated = meeting
        updated.templateID = templateID
        try? store.update(updated, customTemplates: settings.customTemplates)
        if reviewedMeeting?.id == meeting.id { reviewedMeeting = updated }
        meetings = store.loadAll()
    }

    /// Confirms who was actually present before generating the minutes — the
    /// transcript itself only carries generic track/diarization labels
    /// ("Participants", "Locuteur 2"), never real names, which is the root
    /// cause of "who said what" misattribution. Meant to be called from the
    /// review window before the first `generateSummary`, though nothing
    /// prevents correcting it and regenerating afterward.
    public func setConfirmedParticipants(_ participants: [String], for meeting: Meeting) {
        var updated = meeting
        updated.confirmedParticipants = participants
        try? store.update(updated, customTemplates: settings.customTemplates)
        if reviewedMeeting?.id == meeting.id { reviewedMeeting = updated }
        meetings = store.loadAll()
    }

    /// Corrects the other party of a one-to-one after recording — useful if
    /// the calendar didn't suggest them or if the wrong name was selected.
    public func setOneToOneParticipant(
        name: String, email: String, accountID: String = "", for meeting: Meeting
    ) {
        var updated = meeting
        updated.oneToOneParticipant = name.isEmpty ? nil : name
        updated.oneToOneParticipantEmail = email.isEmpty ? nil : email
        updated.oneToOneParticipantAccountID = accountID.isEmpty ? nil : accountID
        try? store.update(updated, customTemplates: settings.customTemplates)
        if reviewedMeeting?.id == meeting.id { reviewedMeeting = updated }
        meetings = store.loadAll()
    }

    /// Applies a person configured in Settings to an already-recorded
    /// one-to-one — e.g. picking the right counterpart after the fact also
    /// restores their configured destination and Jira share e-mail, not just
    /// their name.
    public func setOneToOnePerson(_ person: OneToOnePerson, for meeting: Meeting) {
        var updated = meeting
        updated.oneToOneParticipant = person.name.isEmpty ? nil : person.name
        updated.oneToOneParticipantEmail = person.email.isEmpty ? nil : person.email
        updated.oneToOneParticipantAccountID = person.confluenceAccountID.isEmpty
            ? nil : person.confluenceAccountID
        updated.oneToOneDestination = person.destination == .profileDefault ? nil : person.destination
        updated.oneToOneJiraShareEmail = person.jiraShareEmail.isEmpty ? nil : person.jiraShareEmail
        try? store.update(updated, customTemplates: settings.customTemplates)
        if reviewedMeeting?.id == meeting.id { reviewedMeeting = updated }
        meetings = store.loadAll()
    }

    /// Adds a person found via the Confluence search picker to the list of
    /// people allowed to view this meeting's published page — on top of
    /// whatever restriction the meeting type itself already applies (e.g. a
    /// one-to-one's counterpart). A no-op if already added.
    public func addRestrictedViewer(_ match: ConfluenceUserMatch, for meeting: Meeting) {
        guard !meeting.restrictedViewers.contains(where: { $0.accountID == match.accountID }) else { return }
        var updated = meeting
        updated.restrictedViewers.append(
            RestrictedViewer(displayName: match.displayName, email: match.email, accountID: match.accountID)
        )
        try? store.update(updated, customTemplates: settings.customTemplates)
        if reviewedMeeting?.id == meeting.id { reviewedMeeting = updated }
        meetings = store.loadAll()
    }

    /// Removes someone from that same list.
    public func removeRestrictedViewer(_ viewer: RestrictedViewer, for meeting: Meeting) {
        var updated = meeting
        updated.restrictedViewers.removeAll { $0.accountID == viewer.accountID }
        try? store.update(updated, customTemplates: settings.customTemplates)
        if reviewedMeeting?.id == meeting.id { reviewedMeeting = updated }
        meetings = store.loadAll()
    }

    // MARK: - Publication

    public func publish(
        _ meeting: Meeting,
        createJiraIssues: Bool,
        destination: PublicationDestination? = nil,
        jiraProjectKey: String? = nil,
        jiraParentKey: String? = nil
    ) async {
        guard let summary = meeting.summary else {
            publishState = .failed(L("Aucun compte rendu à publier."))
            return
        }
        guard settings.canPublish else {
            publishState = .failed(L("Configuration Atlassian incomplète (site, e-mail, espace, jeton)."))
            return
        }

        publishState = .running(L("Publication…"))
        let service = PublishService(
            configuration: settings.atlassian, token: settings.atlassianToken
        )
        let transcript = store.transcriptMarkdown(for: meeting.id)
        let audioNote = L(
            "durée %@, transcription on-device — participants informés de l'enregistrement",
            meeting.formattedDuration
        )

        // Jira tickets are always in English, regardless of the minutes'
        // language: translation only happens if necessary, to avoid a
        // needless LLM call when the minutes are already in English.
        let translateForJira: (@Sendable (String) async throws -> String)?
        if createJiraIssues, meeting.outputLanguage != .english {
            let provider = settings.makeProvider()
            translateForJira = { text in try await Translator.toEnglish(text, using: provider) }
        } else {
            translateForJira = nil
        }

        do {
            let result = try await service.publish(
                summary: summary,
                transcript: transcript,
                audioNote: audioNote,
                createJiraIssues: createJiraIssues,
                template: settings.template(id: meeting.templateID),
                meetingDate: meeting.startedAt,
                language: meeting.outputLanguage,
                includeTranscript: settings.includesTranscript(for: .atlassian),
                destination: destination ?? meeting.oneToOneDestination,
                jiraProjectKey: jiraProjectKey,
                jiraParentKey: jiraParentKey,
                translateForJira: translateForJira,
                participantName: meeting.oneToOneParticipant ?? "",
                restrictToParticipantEmail: meeting.oneToOneParticipantEmail,
                restrictToParticipantAccountID: meeting.oneToOneParticipantAccountID,
                restrictedViewerAccountIDs: meeting.restrictedViewers.map(\.accountID),
                jiraShareEmail: meeting.oneToOneJiraShareEmail
            ) { step in
                Task { @MainActor [weak self] in
                    self?.publishState = .running(Self.describe(step))
                }
            }

            var updated = meeting
            updated.confluencePageURL = result.pageURL?.absoluteString
            updated.jiraIssueKeys = Array(result.issues.values).sorted()
            updated.jiraSearchURL = result.jiraSearchURL?.absoluteString
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
                failures: result.failures,
                jiraSearchURL: result.jiraSearchURL?.absoluteString
            )
            notifier.announcePublication(
                meetingID: updated.id,
                title: result.pageTitle,
                serviceName: "Confluence",
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
        case .resolvingDestination: L("Résolution de la destination…")
        case .creatingPage: L("Création de la page Confluence…")
        case .creatingIssue(let index, let total): L("Création du ticket %d/%d…", index, total)
        case .linkingIssues: L("Mise à jour de la page avec les clés Jira…")
        case .done: L("Terminé")
        }
    }

    /// Publishes the minutes as a Notion page, optionally followed by the
    /// transcript in a collapsed toggle according to the active profile.
    public func publishToNotion(
        _ meeting: Meeting,
        createTasks: Bool = false,
        destination: PublicationDestination? = nil
    ) async {
        guard let summary = meeting.summary else {
            notionPublishState = .failed(L("Aucun compte rendu à publier."))
            return
        }
        guard settings.canPublishToNotion else {
            notionPublishState = .failed(L("Configuration Notion incomplète (page parente, jeton)."))
            return
        }

        notionPublishState = .running
        let client = NotionClient(configuration: settings.notion, token: settings.notionToken)
        let template = settings.template(id: meeting.templateID)
        let title = template.pageTitle(
            summaryTitle: summary.title,
            date: meeting.startedAt,
            language: meeting.outputLanguage,
            participant: meeting.oneToOneParticipant ?? ""
        )
        let markdown = summary.markdown(template: template, language: meeting.outputLanguage)
        let transcript = settings.includesTranscript(for: .notion)
            ? store.transcriptMarkdown(for: meeting.id)
            : nil

        do {
            let effectiveDestination = destination ?? meeting.oneToOneDestination ?? template.destination
            let page = try await client.createPage(
                title: title,
                markdown: markdown,
                parentPageID: effectiveDestination.pageID,
                transcript: transcript,
                transcriptTitle: meeting.outputLanguage.pick(
                    fr: "Transcript intégral", en: "Full transcript"
                )
            )
            var updated = meeting
            updated.notionPageURL = page.url?.absoluteString
            var failures: [String] = []
            if createTasks, settings.notion.isTaskDataSourceConfigured,
               var updatedSummary = updated.summary {
                for index in updatedSummary.actionItems.indices
                    where updatedSummary.actionItems[index].isSelected {
                    let item = updatedSummary.actionItems[index]
                    do {
                        let task = try await client.createTask(
                            NotionTaskInput(
                                title: item.description,
                                owner: item.owner,
                                dueDate: item.dueDate,
                                type: item.issueType.displayName(in: meeting.outputLanguage),
                                meetingTitle: title,
                                meetingURL: page.url
                            ),
                            dataSourceID: settings.notion.taskDataSourceID
                        )
                        updatedSummary.actionItems[index].notionTaskURL = task.url?.absoluteString
                    } catch {
                        failures.append(item.description + " — " + error.localizedDescription)
                    }
                }
                updated.summary = updatedSummary
            }
            try? store.update(updated, customTemplates: settings.customTemplates)
            meetings = store.loadAll()
            reviewedMeeting = updated
            notionPublishState = .published(url: page.url?.absoluteString ?? "")
            if !failures.isEmpty {
                notionPublishState = .failed(failures.joined(separator: "\n"))
            }
            notifier.announcePublication(
                meetingID: updated.id,
                title: title,
                serviceName: ServiceKind.notion.displayName,
                url: page.url,
                issues: []
            )
        } catch {
            notionPublishState = .failed(error.localizedDescription)
            notifier.announceFailure(
                meetingID: meeting.id,
                title: meeting.title,
                message: error.localizedDescription
            )
        }
    }

    // MARK: - History

    public func delete(_ meeting: Meeting) {
        try? store.delete(meeting.id)
        meetings = store.loadAll()
        if reviewedMeeting?.id == meeting.id { reviewedMeeting = nil }
    }

    /// True if this meeting's raw audio is still on disk.
    public func transcript(for meeting: Meeting) -> String {
        store.transcriptMarkdown(for: meeting.id)
    }

    public func hasRawRecording(for meeting: Meeting) -> Bool {
        store.hasRawRecording(for: meeting.id)
    }

    /// Deletes a meeting's audio and transcript, keeping the minutes.
    /// Meant for a user who has reviewed their minutes, found them faithful,
    /// and no longer wants to keep the raw recording. Irreversible.
    @discardableResult
    public func deleteRawRecording(for meeting: Meeting) -> String {
        do {
            try store.deleteRawRecording(for: meeting.id)
        } catch {
            return L("Échec de la suppression : %@", error.localizedDescription)
        }
        if reviewedMeeting?.id == meeting.id { segments = [] }
        meetings = store.loadAll()
        return L("Audio et transcript supprimés. Le compte rendu est conservé.")
    }

    public func directory(for meeting: Meeting) -> URL {
        store.directory(for: meeting.id)
    }

    public func segments(for meeting: Meeting) -> [TranscriptSegment] {
        store.loadSegments(for: meeting.id)
    }

    /// Reapplies experimental microphone-track diarization to an
    /// already-recorded meeting — useful for meetings captured before the
    /// setting was enabled, or to retry after a failure. Rewrites
    /// `segments.json` and `transcript.md`; doesn't touch the already
    /// generated minutes or the audio.
    @discardableResult
    public func rediarize(_ meeting: Meeting) async -> String {
        let existing = store.loadSegments(for: meeting.id)
        guard !existing.isEmpty else {
            return L("Aucun transcript à réanalyser pour cette réunion.")
        }
        let audioURL = directory(for: meeting).appending(path: AudioTrack.microphone.fileName)
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            return L("Piste micro introuvable (%@).", AudioTrack.microphone.fileName)
        }
        let offset = meeting.trackStartOffsets[AudioTrack.microphone.rawValue] ?? 0

        guard let mapping = try? MicrophoneDiarizer.diarize(
            segments: existing, audioFileURL: audioURL, fileTimeOffset: offset
        ) else {
            return L("Aucune séparation nette trouvée — probablement une seule voix, ou pas assez de segments micro.")
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
            return L("Échec de l'enregistrement : %@", error.localizedDescription)
        }

        segments = updated
        meetings = store.loadAll()
        let speakerCount = Set(mapping.values).count
        return L("%d locuteur(s) distingué(s) sur la piste micro.", speakerCount)
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
                failures: [],
                jiraSearchURL: meeting.jiraSearchURL
            )
            : .none
        notionPublishState = meeting.isPublishedToNotion
            ? .published(url: meeting.notionPageURL ?? "")
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
        endOfMeetingObserver?.cancel()
        endOfMeetingObserver = nil
        monitoredConferencingApp = nil
        conferencingAppAbsentSince = nil
        meetingEndNotified = false
        meetingEndSnoozedUntil = nil
    }

    private static func defaultTitle(for date: Date) -> String {
        L("Réunion du %@", date.formatted(date: .abbreviated, time: .shortened))
    }

    /// Distinguishes up to two speakers on the microphone track, for
    /// in-person meetings where several people speak into the same mic.
    /// Fails silently (returns the segments unchanged): a failed
    /// diarization shouldn't cost a recording.
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
