import Atlassian
import MeetingStore
import Notion
import Summarization
import SwiftUI

/// Review window: the generated minutes stay editable before publication.
/// Nothing goes to Confluence without passing under the user's eyes.
struct ReviewWindow: View {
    @Bindable var session: RecordingSession
    @State private var draft = MeetingSummary()
    @State private var createJiraIssues = false
    @State private var createNotionTasks = true
    @State private var loadedMeetingID: UUID?
    @State private var diarizationStatus: String?
    @State private var isDiarizing = false
    @State private var rawDeletionStatus: String?
    @State private var showDeleteRawConfirmation = false
    @State private var showDeleteAllConfirmation = false
    @State private var showParticipantsPopover = false
    @State private var showTranscript = false
    @State private var templateSelection: String = ""
    @State private var languageSelection: SummaryLanguage = .french
    @State private var oneToOneNameInput: String = ""
    @State private var oneToOneEmailInput: String = ""
    @State private var oneToOneAccountIDInput: String = ""
    @State private var showJiraDestinationSheet = false
    @State private var jiraProjectKeyInput = ""
    @State private var jiraParentKeyInput = ""
    @State private var pendingPublishMeeting: Meeting?
    @State private var publicationService: ServiceKind?
    @State private var publicationDestination: PublicationDestination = .profileDefault
    @State private var publicationPageInput = ""

    var body: some View {
        Group {
            if let meeting = session.reviewedMeeting {
                content(for: meeting)
            } else {
                ContentUnavailableView(
                    "Aucune réunion sélectionnée",
                    systemImage: "doc.text",
                    description: Text("Choisis une réunion dans le menu SmartMeet.")
                )
            }
        }
        .frame(minWidth: 640, minHeight: 560)
    }

    private func content(for meeting: Meeting) -> some View {
        VStack(spacing: 0) {
            header(for: meeting)
            Divider()

            switch session.summaryState {
            case .running(let message):
                progress(message)
            case .failed(let message):
                failure(message, meeting: meeting)
            case .none where !meeting.hasSummary:
                empty(meeting)
            default:
                editor(meeting)
            }
        }
        .onChange(of: session.reviewedMeeting?.id, initial: true) {
            load(meeting)
            templateSelection = meeting.templateID
            languageSelection = meeting.outputLanguage
            oneToOneNameInput = meeting.oneToOneParticipant ?? ""
            oneToOneEmailInput = meeting.oneToOneParticipantEmail ?? ""
            let template = session.template(for: meeting)
            publicationService = session.settings.publicationServiceKind(for: template)
            publicationDestination = meeting.oneToOneDestination ?? template.destination
            publicationPageInput = publicationDestination.pageID ?? ""
            oneToOneAccountIDInput = meeting.oneToOneParticipantAccountID ?? ""
        }
        .onChange(of: session.summaryState) { load(session.reviewedMeeting ?? meeting) }
        .sheet(isPresented: $showJiraDestinationSheet) {
            jiraDestinationSheet
        }
    }

    /// Always asks where to create the tickets, rather than relying solely
    /// on the project configured in settings: a set of minutes can concern
    /// a project different from the default one.
    private var jiraDestinationSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Où créer les tickets Jira ?")
                .font(.title3.weight(.semibold))

            VStack(alignment: .leading, spacing: 4) {
                Text("Projet Jira").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                TextField("Ex. PROJ", text: $jiraProjectKeyInput)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Epic parent (optionnel)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                TextField("Ex. PROJ-123", text: $jiraParentKeyInput)
                    .textFieldStyle(.roundedBorder)
            }

            Text("Les tickets seront créés en anglais, quelle que soit la langue du compte rendu.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Annuler") {
                    showJiraDestinationSheet = false
                    pendingPublishMeeting = nil
                }
                Button("Créer les tickets") {
                    showJiraDestinationSheet = false
                    if let meeting = pendingPublishMeeting {
                        Task {
                            await session.publish(
                                meeting,
                                createJiraIssues: true,
                                destination: publicationDestination,
                                jiraProjectKey: jiraProjectKeyInput,
                                jiraParentKey: jiraParentKeyInput
                            )
                        }
                    }
                    pendingPublishMeeting = nil
                }
                .buttonStyle(.borderedProminent)
                .disabled(jiraProjectKeyInput.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 380)
    }

    private func load(_ meeting: Meeting?) {
        guard let meeting, let summary = meeting.summary else { return }
        // Don't overwrite ongoing edits if the meeting hasn't changed.
        guard loadedMeetingID != meeting.id || draft.title.isEmpty else { return }
        draft = summary
        loadedMeetingID = meeting.id
    }

    private func header(for meeting: Meeting) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            // The title and metadata (type, date, duration, language) are the
            // meeting's contextual info: they take up the whole available
            // width, with the actions relegated to their own row below.
            VStack(alignment: .leading, spacing: 2) {
                Text(meeting.title).font(.title3.weight(.semibold)).lineLimit(1)
                HStack(spacing: 6) {
                    Label(
                        session.template(for: meeting).localizedName,
                        systemImage: session.template(for: meeting).symbol
                    )
                    Text("·")
                    Text(meeting.startedAt.formatted(date: .long, time: .shortened))
                    Text("·")
                    Text(meeting.formattedDuration)
                    Text("·")
                    Text("\(meeting.outputLanguage.flag) \(meeting.outputLanguage.displayName)")
                    Spacer()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack {
                if session.hasRawRecording(for: meeting) {
                    Button {
                        showTranscript = true
                    } label: {
                        Label("Transcription", systemImage: "text.quote")
                    }
                    .help("Affiche le transcript brut de la réunion")
                }
                Spacer()
                if session.settings.diarizeMicrophoneTrack {
                    Button {
                        Task {
                            isDiarizing = true
                            diarizationStatus = await session.rediarize(meeting)
                            isDiarizing = false
                        }
                    } label: {
                        if isDiarizing {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Réanalyser les locuteurs", systemImage: "person.wave.2")
                        }
                    }
                    .disabled(isDiarizing)
                    .help("Diarisation expérimentale de la piste micro (hauteur, timbre) — voir Réglages.")
                }
                if meeting.hasSummary {
                    Button {
                        showParticipantsPopover = true
                    } label: {
                        Label("Participants", systemImage: "person.2")
                    }
                    .help("Corrige qui était présent avant de régénérer — le transcript ne connaît que la piste audio, jamais les vrais noms, d'où les attributions parfois erronées.")
                    .popover(isPresented: $showParticipantsPopover) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Qui était présent ?")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            EditableList(
                                title: "Participants",
                                items: confirmedParticipantsBinding(for: meeting)
                            )
                        }
                        .padding()
                        .frame(width: 260)
                    }

                    Picker("Type", selection: $templateSelection) {
                        ForEach(session.settings.allTemplates) { template in
                            Label(template.localizedName, systemImage: template.symbol).tag(template.id)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 170)
                    .help("Type appliqué à la prochaine régénération")

                    Picker("Langue", selection: $languageSelection) {
                        ForEach(session.settings.availableOutputLanguages) { language in
                            Text("\(language.flag) \(language.displayName)").tag(language)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 130)
                    .help("Langue appliquée à la prochaine régénération")

                    Button("Régénérer") {
                        Task {
                            let target: Meeting
                            if templateSelection != meeting.templateID
                                || languageSelection != meeting.outputLanguage
                            {
                                target = session.applyRegenerationSettings(
                                    templateID: templateSelection,
                                    language: languageSelection,
                                    for: meeting
                                )
                            } else {
                                target = session.reviewedMeeting ?? meeting
                            }
                            loadedMeetingID = nil
                            await session.generateSummary(for: target)
                        }
                    }
                }
                if meeting.hasSummary, session.hasRawRecording(for: meeting) {
                    Button(role: .destructive) {
                        showDeleteRawConfirmation = true
                    } label: {
                        Label("Supprimer l'audio et le transcript", systemImage: "trash")
                    }
                    .help("Garde le compte rendu, supprime l'audio et le transcript. Irréversible.")
                    .confirmationDialog(
                        "Supprimer l'audio et le transcript ?",
                        isPresented: $showDeleteRawConfirmation,
                        titleVisibility: .visible
                    ) {
                        Button("Supprimer", role: .destructive) {
                            rawDeletionStatus = session.deleteRawRecording(for: meeting)
                        }
                        Button("Annuler", role: .cancel) {}
                    } message: {
                        Text(L(
                            "Le compte rendu est conservé. L'audio (%@) et le transcript seront définitivement supprimés — plus de réanalyse ni de nouvelle génération possible ensuite.",
                            meeting.formattedDuration
                        ))
                    }
                }
                if meeting.isPublished || meeting.isPublishedToNotion {
                    Button(role: .destructive) {
                        showDeleteAllConfirmation = true
                    } label: {
                        Label("Supprimer le local", systemImage: "trash.fill")
                    }
                    .help("La réunion est déjà publiée : supprime l'audio, le transcript et le compte rendu de cette machine. La page publiée n'est pas affectée. Irréversible.")
                    .confirmationDialog(
                        "Supprimer toutes les données locales ?",
                        isPresented: $showDeleteAllConfirmation,
                        titleVisibility: .visible
                    ) {
                        Button("Supprimer", role: .destructive) {
                            session.delete(meeting)
                        }
                        Button("Annuler", role: .cancel) {}
                    } message: {
                        Text(L(
                            "L'audio, le transcript et le compte rendu seront définitivement supprimés de cette machine. La page déjà publiée sur %@ reste en ligne et n'est pas affectée.",
                            publishedServicesSummary(meeting)
                        ))
                    }
                }
            }
            if session.settings.template(id: templateSelection).requiresParticipant {
                oneToOneParticipantEditor(meeting)
            }
            restrictedViewersEditor(meeting)
            if let diarizationStatus {
                Text(diarizationStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let rawDeletionStatus {
                Text(rawDeletionStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .sheet(isPresented: $showTranscript) {
            TranscriptSheet(meeting: meeting, transcript: session.transcript(for: meeting))
        }
    }

    /// Corrects the other party of a one-to-one after recording — useful if
    /// the calendar didn't suggest them or if the wrong name was picked up.
    private func oneToOneParticipantEditor(_ meeting: Meeting) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if !session.settings.oneToOnePeople.isEmpty {
                HStack(spacing: 6) {
                    Text("👤").font(.caption)
                    Picker("Avec qui", selection: Binding(
                        get: {
                            session.settings.oneToOnePeople
                                .first { $0.name == oneToOneNameInput }?.id ?? ""
                        },
                        set: { newID in
                            guard let person = session.settings.oneToOnePeople.first(
                                where: { $0.id == newID }
                            ) else { return }
                            session.setOneToOnePerson(person, for: meeting)
                            oneToOneNameInput = person.name
                            oneToOneEmailInput = person.email
                            oneToOneAccountIDInput = person.confluenceAccountID
                        }
                    )) {
                        Text("Choisir…").tag("")
                        ForEach(session.settings.oneToOnePeople) { person in
                            Text(person.name).tag(person.id)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 160)
                    Spacer()
                }
            }
            oneToOneManualParticipantEditor(meeting)
        }
    }

    private func oneToOneManualParticipantEditor(_ meeting: Meeting) -> some View {
        HStack(spacing: 8) {
            Text("👤").font(.caption)
            TextField(
                "Avec qui ?",
                text: Binding(
                    get: { oneToOneNameInput },
                    set: {
                        oneToOneNameInput = $0
                        // A manual edit invalidates any accountId resolved
                        // from a previous search result.
                        oneToOneAccountIDInput = ""
                    }
                )
            )
            .textFieldStyle(.roundedBorder)
            .frame(width: 150)
            ConfluenceUserSearchButton(
                search: { await session.searchConfluenceUsers(matching: $0) },
                onSelect: { match in
                    oneToOneNameInput = match.displayName
                    oneToOneEmailInput = match.email ?? ""
                    oneToOneAccountIDInput = match.accountID
                }
            )
            TextField("E-mail (restreint la page)", text: $oneToOneEmailInput)
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)
            Button("Définir") {
                session.setOneToOneParticipant(
                    name: oneToOneNameInput,
                    email: oneToOneEmailInput,
                    accountID: oneToOneAccountIDInput,
                    for: meeting
                )
            }
            .disabled(
                oneToOneNameInput == (meeting.oneToOneParticipant ?? "")
                    && oneToOneEmailInput == (meeting.oneToOneParticipantEmail ?? "")
                    && oneToOneAccountIDInput == (meeting.oneToOneParticipantAccountID ?? "")
            )
            Spacer()
        }
        .help("La page publiée ne sera visible que de toi et de cette personne, si son compte Confluence est trouvé. Utilise la loupe pour chercher directement le compte Confluence par nom.")
    }

    /// Restricts the published page to specific people, for any meeting
    /// type — on top of whatever the type itself already applies (e.g. a
    /// one-to-one's fixed counterpart above). Pre-filled from the meeting
    /// type's own default list, still editable per meeting.
    private func restrictedViewersEditor(_ meeting: Meeting) -> some View {
        RestrictedViewersEditor(
            viewers: meeting.restrictedViewers,
            search: { await session.searchConfluenceUsers(matching: $0) },
            onAdd: { session.addRestrictedViewer($0, for: meeting) },
            onRemove: { session.removeRestrictedViewer($0, for: meeting) }
        )
    }

    /// Human-readable list of where a meeting was already published, for the
    /// full local-deletion confirmation ("Confluence", "Notion", or both).
    /// Comma-joined rather than a localized "and", like every other list in
    /// this file (issue keys, attendees…) — no extra translation key needed.
    private func publishedServicesSummary(_ meeting: Meeting) -> String {
        var services: [String] = []
        if meeting.isPublished { services.append("Confluence") }
        if meeting.isPublishedToNotion { services.append("Notion") }
        return services.joined(separator: ", ")
    }

    private func progress(_ message: String) -> some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(message).font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func failure(_ message: String, meeting: Meeting) -> some View {
        ContentUnavailableView {
            Label("Génération impossible", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("Réessayer") { Task { await session.generateSummary(for: meeting) } }
        }
    }

    private func empty(_ meeting: Meeting) -> some View {
        VStack(spacing: 20) {
            Spacer()
            VStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 36))
                    .foregroundStyle(.secondary)
                Text("Pas encore de compte rendu").font(.title3.weight(.semibold))
                Text(L("Génère le compte rendu avec %@.", session.settings.providerKind.displayName))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            // The transcript itself never carries real names — only audio
            // track labels ("Moi"/"Participants") or, with diarization,
            // generic "Locuteur N" clusters — which is the root cause of
            // decisions and action items getting attributed to the wrong
            // person. Confirming who's actually here, right before
            // generation, gives the model a closed roster to attribute
            // statements against instead of guessing.
            VStack(alignment: .leading, spacing: 6) {
                Text("Qui était présent ?")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("Le transcript ne connaît que la piste audio, jamais les vrais noms. Confirme ici qui était là pour que le compte rendu attribue correctement décisions et actions.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                EditableList(title: "Participants", items: confirmedParticipantsBinding(for: meeting))
            }
            .frame(maxWidth: 360)

            Button("Générer le compte rendu") {
                Task { await session.generateSummary(for: meeting) }
            }
            .buttonStyle(.borderedProminent)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    /// Writes straight through to the persisted meeting on every edit —
    /// there's no draft/save step before generation, unlike the summary
    /// editor's own `draft` buffer, which only exists once a summary is
    /// there to edit.
    private func confirmedParticipantsBinding(for meeting: Meeting) -> Binding<[String]> {
        Binding(
            get: { meeting.confirmedParticipants },
            set: { session.setConfirmedParticipants($0, for: meeting) }
        )
    }

    private func editor(_ meeting: Meeting) -> some View {
        let template = session.template(for: meeting)
        return VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    field("Titre", text: $draft.title)
                    Label(
                        L("Publié sous : %@", template.pageTitle(
                            summaryTitle: draft.title,
                            date: meeting.startedAt,
                            language: meeting.outputLanguage
                        )),
                        systemImage: "text.badge.checkmark"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    EditableList(title: "Participants", items: $draft.attendees)

                    // Editing order follows the rendered order: what's seen here
                    // is what gets published, sections included.
                    ForEach(template.sections) { section in
                        sectionEditor(section, language: meeting.outputLanguage)
                    }
                }
                .padding()
            }
            Divider()
            footer(meeting, template: template)
        }
    }

    @ViewBuilder
    private func sectionEditor(_ section: SummarySection, language: SummaryLanguage) -> some View {
        switch section {
        case .sprintWeather:
            sprintWeatherSection(language: language)
        case .fourL:
            fourLSection(language: language)
        case .tldr:
            multiline(section.displayName(in: language), text: $draft.tldr, height: 70)
        case .blockers:
            blockersSection(language: language)
        case .participantReports:
            participantReportsSection(language: language)
        case .moods:
            moodsSection(language: language)
        case .topics:
            topicsSection
        case .decisions:
            EditableList(title: section.displayName(in: language), items: $draft.decisions)
        case .actionItems:
            actionItemsSection
        case .openQuestions:
            EditableList(title: section.displayName(in: language), items: $draft.openQuestions)
        case .nextSteps:
            EditableList(title: section.displayName(in: language), items: $draft.nextSteps)
        }
    }

    private func blockersSection(language: SummaryLanguage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle(SummarySection.blockers.displayName(in: language))
            if draft.blockers.isEmpty {
                Text("Rien ne bloque.").font(.callout).foregroundStyle(.tertiary)
            }
            ForEach($draft.blockers) { $blocker in
                HStack(spacing: 8) {
                    Picker("", selection: $blocker.severity) {
                        Label("Bloquant", systemImage: "exclamationmark.octagon.fill")
                            .tag(MeetingSummary.Blocker.Severity.blocking)
                        Label("Risque", systemImage: "exclamationmark.triangle.fill")
                            .tag(MeetingSummary.Blocker.Severity.risk)
                    }
                    .labelsHidden()
                    .frame(width: 120)

                    TextField(
                        "Personne",
                        text: Binding(
                            get: { blocker.person ?? "" },
                            set: { blocker.person = $0.isEmpty ? nil : $0 }
                        )
                    )
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 110)

                    TextField("Obstacle", text: $blocker.description, axis: .vertical)
                        .textFieldStyle(.roundedBorder)

                    Button {
                        draft.blockers.removeAll { $0.id == blocker.id }
                    } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                }
            }
            Button("Ajouter un point bloquant") {
                draft.blockers.append(.init(description: ""))
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
    }

    private func participantReportsSection(language: SummaryLanguage) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle(SummarySection.participantReports.displayName(in: language))
            ForEach($draft.participantReports) { $report in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        TextField("Personne", text: $report.person)
                            .textFieldStyle(.roundedBorder)
                            .font(.callout.weight(.semibold))
                        Button {
                            draft.participantReports.removeAll { $0.id == report.id }
                        } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                    EditableList(title: "Fait", items: $report.done)
                    EditableList(title: "À venir", items: $report.next)
                    EditableList(title: "Bloqué par", items: $report.blockers)
                }
                .padding(8)
                .background(.quaternary.opacity(0.3), in: .rect(cornerRadius: 6))
            }
            Button("Ajouter une personne") {
                draft.participantReports.append(.init(person: ""))
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
    }

    /// Nominative section intended for managers: it must remain readable
    /// and correctable before being passed on.
    private func sprintWeatherSection(language: SummaryLanguage) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle(SummarySection.sprintWeather.displayName(in: language))
            ForEach($draft.sprintWeather) { $entry in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        TextField("Personne", text: $entry.person)
                            .textFieldStyle(.roundedBorder)
                            .font(.callout.weight(.semibold))
                        Button {
                            draft.sprintWeather.removeAll { $0.id == entry.id }
                        } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }

                    // Several icons per person: a mixed-bag sprint is rarely
                    // told with a single image.
                    HStack(spacing: 4) {
                        ForEach(WeatherIcon.allCases) { icon in
                            let isOn = entry.icons.contains(icon)
                            Button {
                                if isOn {
                                    entry.icons.removeAll { $0 == icon }
                                } else {
                                    entry.icons.append(icon)
                                }
                            } label: {
                                Text(icon.emoji)
                                    .font(.title3)
                                    .opacity(isOn ? 1 : 0.3)
                            }
                            .buttonStyle(.borderless)
                            .help(icon.label(in: language))
                        }
                    }

                    TextField("Pourquoi ces images", text: $entry.explanation, axis: .vertical)
                        .textFieldStyle(.roundedBorder)

                    EditableList(title: "Ce qu'il ou elle dit du sprint", items: $entry.sprintFeedback)
                }
                .padding(8)
                .background(.quaternary.opacity(0.3), in: .rect(cornerRadius: 6))
            }
            Button("Ajouter une personne") {
                draft.sprintWeather.append(.init(person: ""))
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
    }

    private func fourLSection(language: SummaryLanguage) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle(SummarySection.fourL.displayName(in: language))
            let binding = Binding(
                get: { draft.fourL ?? MeetingSummary.FourL() },
                set: { draft.fourL = $0 }
            )
            fourLAxis(label: binding.wrappedValue.axes(in: language)[0].label, topics: binding.liked)
            fourLAxis(label: binding.wrappedValue.axes(in: language)[1].label, topics: binding.learned)
            fourLAxis(label: binding.wrappedValue.axes(in: language)[2].label, topics: binding.lacked)
            fourLAxis(label: binding.wrappedValue.axes(in: language)[3].label, topics: binding.longedFor)
        }
    }

    private func fourLAxis(label: String, topics: Binding<[MeetingSummary.Topic]>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.callout.weight(.semibold))
            ForEach(topics) { $topic in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        TextField("Sujet", text: $topic.heading)
                            .textFieldStyle(.roundedBorder)
                        Button {
                            topics.wrappedValue.removeAll { $0.id == topic.id }
                        } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                    EditableList(title: "", items: $topic.bullets)
                }
            }
            Button("Ajouter un sujet") {
                topics.wrappedValue.append(.init(heading: "", bullets: []))
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
        .padding(8)
        .background(.quaternary.opacity(0.25), in: .rect(cornerRadius: 6))
    }

    private func moodsSection(language: SummaryLanguage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle(SummarySection.moods.displayName(in: language))
            ForEach($draft.moods) { $mood in
                HStack(spacing: 8) {
                    Picker("", selection: $mood.mood) {
                        Label("Positif", systemImage: "face.smiling")
                            .tag(MeetingSummary.ParticipantMood.Tone.positive)
                        Label("Neutre", systemImage: "minus.circle")
                            .tag(MeetingSummary.ParticipantMood.Tone.neutral)
                        Label("Négatif", systemImage: "face.dashed")
                            .tag(MeetingSummary.ParticipantMood.Tone.negative)
                    }
                    .labelsHidden()
                    .frame(width: 110)

                    TextField("Personne", text: $mood.person)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 110)

                    TextField("Commentaire", text: $mood.comment, axis: .vertical)
                        .textFieldStyle(.roundedBorder)

                    Button {
                        draft.moods.removeAll { $0.id == mood.id }
                    } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                }
            }
            Button("Ajouter une personne") { draft.moods.append(.init(person: "")) }
                .buttonStyle(.borderless)
                .font(.caption)
        }
    }

    private var topicsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach($draft.topics) { $topic in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        TextField("Sujet", text: $topic.heading)
                            .textFieldStyle(.roundedBorder)
                            .font(.callout.weight(.semibold))
                        Button {
                            draft.topics.removeAll { $0.id == topic.id }
                        } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                    EditableList(title: "", items: $topic.bullets)
                }
            }
            Button("Ajouter un sujet") {
                draft.topics.append(.init(heading: "", bullets: []))
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
    }

    private var actionItemsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Action items")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            if draft.actionItems.isEmpty {
                Text("Aucun").font(.callout).foregroundStyle(.tertiary)
            }

            ForEach($draft.actionItems) { $item in
                HStack(alignment: .top, spacing: 8) {
                    Toggle("", isOn: $item.isSelected)
                        .labelsHidden()
                        .help("Créer un ticket Jira pour cet item")
                    VStack(spacing: 4) {
                        TextField("Action", text: $item.description, axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                        HStack {
                            Picker("", selection: $item.issueType) {
                                ForEach(MeetingSummary.IssueType.allCases) { type in
                                    Label(type.displayName(in: .english), systemImage: type.symbol)
                                        .tag(type)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 130)
                            .help("Type de ticket Jira détecté — modifiable")

                            TextField(
                                "Responsable",
                                text: Binding(
                                    get: { item.owner ?? "" },
                                    set: { item.owner = $0.isEmpty ? nil : $0 }
                                )
                            )
                            .textFieldStyle(.roundedBorder)
                            TextField(
                                "Échéance (AAAA-MM-JJ)",
                                text: Binding(
                                    get: { item.dueDate ?? "" },
                                    set: { item.dueDate = $0.isEmpty ? nil : $0 }
                                )
                            )
                            .textFieldStyle(.roundedBorder)
                            if let key = item.jiraKey {
                                Text(key).font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Button {
                        draft.actionItems.removeAll { $0.id == item.id }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                }
            }

            Button("Ajouter un action item") {
                draft.actionItems.append(.init(description: ""))
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
    }

    private func footer(_ meeting: Meeting, template: MeetingTemplate) -> some View {
        VStack(spacing: 8) {
            if case .running(let message) = session.publishState {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
            }
            if case .published(let url, let pageTitle, let issues, let failures, let jiraSearchURL) = session.publishState {
                VStack(alignment: .leading, spacing: 4) {
                    if let pageURL = URL(string: url) {
                        Link(L("« %@ »", pageTitle), destination: pageURL).font(.callout)
                    }
                    if !issues.isEmpty {
                        Text(L("Tickets créés : %@", issues.joined(separator: ", ")))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let jiraSearchURL, let searchURL = URL(string: jiraSearchURL) {
                        Link("Voir les tickets dans Jira", destination: searchURL)
                            .font(.caption)
                    }
                    ForEach(failures, id: \.self) { failure in
                        Label(failure, systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if case .failed(let message) = session.publishState {
                Label(message, systemImage: "xmark.octagon")
                    .font(.caption).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if case .published(let url) = session.notionPublishState, let pageURL = URL(string: url) {
                Link("Publié sur Notion", destination: pageURL)
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if case .failed(let message) = session.notionPublishState {
                Label(L("Notion : %@", message), systemImage: "xmark.octagon")
                    .font(.caption).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 8) {
                Picker("Service", selection: Binding(
                    get: { publicationService },
                    set: { service in
                        if publicationService != service {
                            publicationService = service
                            publicationDestination = .profileDefault
                            publicationPageInput = ""
                        }
                    }
                )) {
                    ForEach(session.settings.enabledServices.sorted {
                        $0.displayName < $1.displayName
                    }) { service in
                        Text(service.displayName).tag(ServiceKind?.some(service))
                    }
                }
                .frame(width: 130)
                Picker("Destination", selection: Binding(
                    get: {
                        publicationDestination == .profileDefault ? 0 : 1
                    },
                    set: { value in
                        publicationDestination = value == 0
                            ? .profileDefault
                            : .page(id: publicationPageInput)
                    }
                )) {
                    Text("Défaut du profil").tag(0)
                    Text("Page spécifique").tag(1)
                }
                .frame(width: 170)
                if publicationDestination != .profileDefault {
                    TextField("URL ou identifiant", text: $publicationPageInput)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: publicationPageInput) {
                            publicationDestination = .page(
                                id: normalizedPublicationPageID(publicationPageInput)
                            )
                        }
                }
                Label(publicationDestinationSummary, systemImage: "tray.and.arrow.down")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                if let usage = meeting.tokenUsage {
                    Label(usage.formatted, systemImage: "number")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help("Tokens consommés pour générer ce compte rendu")
                }
            }

            HStack {
                if publicationService == .atlassian {
                    Toggle("Créer les tickets Jira cochés", isOn: $createJiraIssues)
                        .disabled(!session.settings.atlassian.isJiraReady)
                } else if publicationService == .notion {
                    Toggle("Créer les tâches Notion cochées", isOn: $createNotionTasks)
                        .disabled(!session.settings.notion.isTaskDataSourceConfigured)
                }
                Spacer()
                Button("Copier en markdown") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(
                        draft.markdown(template: template, language: meeting.outputLanguage),
                        forType: .string
                    )
                }
                Button(L("Enregistrer les modifications")) { session.saveReviewedSummary(draft) }
                Button(publicationService == .notion ? "Publier sur Notion" : "Publier sur Confluence") {
                    publishUsingReviewDestination()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canPublishUsingReviewDestination)
            }
        }
        .padding()
    }

    private func confluencePublishAction() {
        session.saveReviewedSummary(draft)
        guard let updated = session.reviewedMeeting else { return }
        let hasSelectedItems = draft.actionItems.contains { $0.isSelected }
        if createJiraIssues, session.settings.atlassian.isJiraReady, hasSelectedItems {
            // Always ask where to create the tickets, pre-filled with
            // the default settings: the target project can vary
            // from one meeting to another.
            jiraProjectKeyInput = session.settings.atlassian.jiraProjectKey
            jiraParentKeyInput = session.settings.atlassian.jiraParentKey
            pendingPublishMeeting = updated
            showJiraDestinationSheet = true
        } else {
            Task {
                await session.publish(
                    updated,
                    createJiraIssues: false,
                    destination: publicationDestination
                )
            }
        }
    }

    private var publicationDestinationSummary: String {
        guard let publicationService else { return L("Aucun service de publication sélectionné") }
        return session.destinationSummary(
            service: publicationService,
            destination: publicationDestination
        )
    }

    private var canPublishUsingReviewDestination: Bool {
        guard let publicationService,
              session.settings.canPublish(to: publicationService)
        else { return false }
        if case .page(let id) = publicationDestination { return !id.isEmpty }
        return true
    }

    private func normalizedPublicationPageID(_ input: String) -> String {
        switch publicationService {
        case .notion:
            return NotionConfiguration.extractPageID(from: input) ?? input
        case .atlassian:
            return SprintPage.extractPageID(from: input) ?? input
        case nil:
            return input
        }
    }

    private func publishUsingReviewDestination() {
        session.saveReviewedSummary(draft)
        guard let updated = session.reviewedMeeting else { return }
        switch publicationService {
        case .notion:
            Task {
                await session.publishToNotion(
                    updated,
                    createTasks: createNotionTasks,
                    destination: publicationDestination
                )
            }
        case .atlassian:
            confluencePublishAction()
        case nil:
            break
        }
    }

    private func field(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            TextField(title, text: text).textFieldStyle(.roundedBorder)
        }
    }

    private func multiline(_ title: String, text: Binding<String>, height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            TextEditor(text: text)
                .font(.body)
                .frame(height: height)
                .padding(4)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
        }
    }
}

/// Raw transcript of the meeting (the one used to generate the minutes),
/// shown read-only from the review window.
private struct TranscriptSheet: View {
    let meeting: Meeting
    let transcript: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L("Transcription — %@", meeting.title))
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Button("Copier") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(transcript, forType: .string)
                }
                Button("Fermer") { dismiss() }
            }
            .padding()
            Divider()

            if transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ContentUnavailableView(
                    "Transcript indisponible",
                    systemImage: "text.quote",
                    description: Text("L'audio et le transcript ont peut-être été supprimés.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    Text(transcript)
                        .font(.callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
            }
        }
        .frame(minWidth: 520, minHeight: 480)
    }
}

/// Editable list of strings, used for every bulleted section.
struct EditableList: View {
    let title: String
    @Binding var items: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if items.isEmpty {
                Text("Aucun").font(.callout).foregroundStyle(.tertiary)
            }
            ForEach(items.indices, id: \.self) { index in
                HStack(spacing: 6) {
                    TextField("", text: $items[index], axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                    Button {
                        items.remove(at: index)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                }
            }
            Button("Ajouter") { items.append("") }
                .buttonStyle(.borderless)
                .font(.caption)
        }
    }
}
