import AudioCapture
import MeetingStore
import SmartMeetCalendar
import Atlassian
import Summarization
import SwiftUI
import Transcription

struct MenuBarContent: View {
    @Bindable var session: RecordingSession
    @Environment(\.openWindow) private var openWindow
    @State private var availableLocales: [(id: String, label: String)] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            if case .failed(let message) = session.state {
                errorBanner(message)
            }

            if session.isRecording {
                consentReminder
            }

            if !session.isRecording {
                templatePicker
            }

            if let suggestion = session.suggestion, !session.isRecording {
                suggestionBanner(suggestion)
            } else if let meeting = session.detectedCalendarMeeting, !session.isRecording {
                calendarHint(meeting)
            }

            // Shown only while recording: once stopped, `segments` stays populated
            // (cleared on the next start, not on stop) and a fixed 240pt panel
            // would otherwise hide the meeting list below, since the menu bar
            // window doesn't scroll.
            if session.isRecording {
                TranscriptView(segments: session.segments, volatile: session.volatileText)
                    .frame(height: 240)
                Divider()
            }

            summaryBanner
            MeetingListView(session: session, openWindow: openWindow)
        }
        .padding(.bottom, 8)
        .task {
            await session.refreshCalendarContext()
            await session.startMeetingDetection()
        }
        .task {
            availableLocales = await SupportedTranscriptionLocales.all()
            if !availableLocales.contains(where: { $0.id == session.selectedTranscriptionLocale }) {
                if let resolved = await SupportedTranscriptionLocales.resolvedIdentifier(
                    for: Locale(identifier: session.selectedTranscriptionLocale)
                ) {
                    session.selectedTranscriptionLocale = resolved
                }
            }
        }
    }

    /// Spoken languages already used, in order of recency — bumped to the top
    /// of the picker rather than lost in the full list.
    private var recentLocales: [(id: String, label: String)] {
        session.settings.recentTranscriptionLocales.compactMap { id in
            availableLocales.first { $0.id == id }
        }
    }

    private var otherLocales: [(id: String, label: String)] {
        let recentIDs = Set(session.settings.recentTranscriptionLocales)
        return availableLocales.filter { !recentIDs.contains($0.id) }
    }

    /// Without explicitly activating the app, a window opened from the
    /// popover stays on the current Space without pulling focus to it: if
    /// the user is in another app's full-screen Space, the window silently
    /// opens on the regular desktop, with no Space switch or bring-to-front —
    /// which then looks like a click that did nothing.
    private func openSettings() {
        openWindow(id: "settings")
        NSApp.activate(ignoringOtherApps: true)
    }

    private var header: some View {        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("SmartMeet").font(.headline)
                Text(statusText).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()

            Button {
                Task { await session.toggle() }
            } label: {
                Label(
                    session.isRecording ? "Arrêter" : "Enregistrer",
                    systemImage: session.isRecording ? "stop.fill" : "record.circle"
                )
                .frame(minWidth: 88)
            }
            .buttonStyle(.borderedProminent)
            .tint(session.isRecording ? .red : .accentColor)
            .disabled(session.isBusy)

            Button { openSettings() } label: { Image(systemName: "gearshape") }
                .buttonStyle(.borderless)
                .help("Réglages")

            Button { NSApplication.shared.terminate(nil) } label: { Image(systemName: "power") }
                .buttonStyle(.borderless)
                .help("Quitter")
        }
        .padding(12)
    }

    /// The type is chosen before recording: it's what determines the
    /// sections requested from the model, so it must be locked in from the start.
    private var templatePicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Picker("Type", selection: $session.selectedTemplateID) {
                    ForEach(session.settings.allTemplates) { template in
                        Label(template.name, systemImage: template.symbol).tag(template.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: 150)

                VStack(alignment: .leading, spacing: 1) {
                    Text(session.selectedTemplate.sections.map(\.displayName).joined(separator: " · "))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                    // The destination depends on the chosen type: better to see it
                    // now than at publish time.
                    Text(session.destinationSummary(for: session.selectedTemplate))
                        .font(.caption2)
                        .foregroundStyle(
                            session.selectedTemplate.parent.isSprintPage
                                && session.settings.sprintPage == nil
                                ? Color.orange
                                : Color.secondary.opacity(0.6)
                        )
                        .lineLimit(1)
                }
                Spacer()
            }

            if session.selectedTemplate.requiresParticipant {
                oneToOneParticipantField
            }

            // The "source" language (the one spoken during the meeting, transcribed
            // as-is) and the "destination" language (the one for the generated
            // minutes) are two separate settings: the transcription engine doesn't
            // handle a language change mid-meeting, so it must be fixed before
            // starting — independently of the language the minutes will be
            // written in.
            HStack(spacing: 6) {
                Text("🗣️").font(.caption)
                Picker("Langue parlée", selection: $session.selectedTranscriptionLocale) {
                    if !recentLocales.isEmpty {
                        Section("Récent") {
                            ForEach(recentLocales, id: \.id) { locale in
                                Text(locale.label).tag(locale.id)
                            }
                        }
                        Section("Toutes les langues") {
                            ForEach(otherLocales, id: \.id) { locale in
                                Text(locale.label).tag(locale.id)
                            }
                        }
                    } else {
                        ForEach(availableLocales, id: \.id) { locale in
                            Text(locale.label).tag(locale.id)
                        }
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 150)

                Image(systemName: "arrow.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                Text("📝").font(.caption)
                Picker("Compte rendu", selection: $session.selectedOutputLanguage) {
                    ForEach(SummaryLanguage.allCases) { language in
                        Text("\(language.flag) \(language.displayName)").tag(language)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 110)
                Spacer()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    /// "Who with" for a one-to-one: calendar candidates also fill in the
    /// e-mail at once, needed to restrict the published page to that one
    /// person. Free-text entry is still possible if the other party has no
    /// calendar event (impromptu coffee chat, Slack huddle…).
    private var oneToOneParticipantField: some View {
        HStack(spacing: 6) {
            Text("👤").font(.caption)
            if !session.oneToOneCandidates.isEmpty {
                Picker("Avec qui", selection: $session.oneToOneParticipantName) {
                    Text("Choisir…").tag("")
                    ForEach(session.oneToOneCandidates, id: \.name) { candidate in
                        Text(candidate.name).tag(candidate.name)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 130)
                .onChange(of: session.oneToOneParticipantName) {
                    session.oneToOneParticipantEmail = session.oneToOneCandidates
                        .first { $0.name == session.oneToOneParticipantName }?.email ?? ""
                }
            }
            TextField("Avec qui ?", text: $session.oneToOneParticipantName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 130)
            TextField("E-mail (restreint la page)", text: $session.oneToOneParticipantEmail)
                .textFieldStyle(.roundedBorder)
                .help("La page publiée ne sera visible que de toi et de cette personne, si son compte Confluence est trouvé.")
            Spacer()
        }
    }

    private var statusText: String {
        switch session.state {
        case .idle: session.settings.providerKind.displayName
        case .preparing: L("Préparation des modèles…")
        case .recording(let since):
            L("Enregistrement · %@", Self.elapsed(since: since))
        case .finishing: L("Finalisation…")
        case .failed: L("Erreur")
        }
    }

    private static func elapsed(since date: Date) -> String {
        let total = Int(Date.now.timeIntervalSince(date))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    /// Recording suggestion, shown when a meeting is detected.
    private func suggestionBanner(_ suggestion: MeetingSuggestion) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "record.circle")
                .font(.title3)
                .foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 1) {
                Text(L("Enregistrer « %@ » ?", suggestion.title))
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text(suggestion.reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button("Plus tard") { session.dismissSuggestion() }
                .buttonStyle(.borderless)
                .font(.caption)
            Button("Enregistrer") {
                Task { await session.acceptSuggestion() }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.red.opacity(0.10))
    }

    /// Reminder visible from the very start of a recording: recording third
    /// parties requires their consent. This is a legal obligation, not a
    /// nicety — hence shown persistently throughout the recording rather
    /// than just once at startup.
    private var consentReminder: some View {
        HStack(spacing: 8) {
            Image(systemName: "person.2.wave.2").foregroundStyle(.blue)
            Text("Assure-toi que les participants savent que la réunion est enregistrée.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.blue.opacity(0.08))
    }

    private func calendarHint(_ meeting: CalendarMeeting) -> some View {        HStack(spacing: 8) {
            Image(systemName: meeting.hasVideoLink ? "video" : "calendar")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(meeting.title).font(.callout).lineLimit(1)
                if !meeting.attendees.isEmpty {
                    Text(meeting.attendees.prefix(4).joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.4))
    }

    @ViewBuilder
    private var summaryBanner: some View {
        switch session.summaryState {
        case .running(let message):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(message).font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
                .lineLimit(2)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
        default:
            EmptyView()
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(message).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("OK") { session.dismissError() }.buttonStyle(.borderless)
        }
        .padding(12)
        .background(.orange.opacity(0.12))
    }
}

struct TranscriptView: View {
    let segments: [TranscriptSegment]
    let volatile: [AudioTrack: String]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(segments) { segment in
                        row(
                            speaker: segment.speaker,
                            timecode: segment.timecode,
                            text: segment.text,
                            track: segment.track,
                            isVolatile: false
                        )
                        .id(segment.id)
                    }
                    ForEach(AudioTrack.allCases, id: \.self) { track in
                        if let text = volatile[track], !text.isEmpty {
                            row(
                                speaker: track.speakerLabel,
                                timecode: "…",
                                text: text,
                                track: track,
                                isVolatile: true
                            )
                        }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: segments.count) {
                if let last = segments.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            .overlay {
                if segments.isEmpty, volatile.values.allSatisfy(\.isEmpty) {
                    ContentUnavailableView(
                        "En écoute",
                        systemImage: "waveform",
                        description: Text("Le transcript s'affichera au fil de la réunion.")
                    )
                }
            }
        }
    }

    private func row(
        speaker: String,
        timecode: String,
        text: String,
        track: AudioTrack,
        isVolatile: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Circle()
                    .fill(track == .microphone ? Color.accentColor : Color.purple)
                    .frame(width: 7, height: 7)
                Text(speaker).font(.caption.weight(.semibold))
                Text(timecode).font(.caption).foregroundStyle(.tertiary)
            }
            Text(text)
                .font(.callout)
                .foregroundStyle(isVolatile ? .secondary : .primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct MeetingListView: View {
    @Bindable var session: RecordingSession
    let openWindow: OpenWindowAction

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Réunions")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if session.meetings.count > 3 {
                    TextField("Rechercher", text: $session.searchQuery)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 150)
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)

            if session.filteredMeetings.isEmpty {
                Text(session.meetings.isEmpty ? "Aucune réunion." : "Aucun résultat.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 4)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(session.filteredMeetings.prefix(10)) { meeting in
                            MeetingRow(meeting: meeting, session: session, openWindow: openWindow)
                        }
                    }
                }
                // `maxHeight` alone lets the ScrollView report an ideal height
                // of 0 inside the `MenuBarExtra` popover (which sizes the window
                // to the content's intrinsic size): the list would then disappear
                // entirely, even with meetings present. An explicit height,
                // capped at the actual number of rows, gives SwiftUI a floor it
                // can actually measure.
                .frame(height: min(CGFloat(session.filteredMeetings.prefix(10).count) * 44, 170))
            }
        }
    }
}

private struct MeetingRow: View {
    let meeting: Meeting
    @Bindable var session: RecordingSession
    let openWindow: OpenWindowAction
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(meeting.title).font(.callout).lineLimit(1)
                HStack(spacing: 6) {
                    Text(meeting.formattedDuration)
                    if meeting.hasSummary {
                        Image(systemName: "sparkles").foregroundStyle(.purple)
                    }
                    if meeting.isPublished {
                        Image(systemName: "checkmark.icloud").foregroundStyle(.green)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()

            if isHovered {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(
                        session.exportMarkdown(for: meeting), forType: .string
                    )
                } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless)
                    .help("Copier en markdown")

                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([session.directory(for: meeting)])
                } label: { Image(systemName: "folder") }
                    .buttonStyle(.borderless)
                    .help("Révéler dans le Finder")

                Button { session.delete(meeting) } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .help("Supprimer")
            }
        }
        .contentShape(.rect)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(isHovered ? Color.primary.opacity(0.06) : .clear)
        .onHover { isHovered = $0 }
        .onTapGesture {
            session.openReview(meeting)
            openWindow(id: "review")
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
