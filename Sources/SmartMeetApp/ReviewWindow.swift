import MeetingStore
import Summarization
import SwiftUI

/// Fenêtre de relecture : le compte rendu généré reste éditable avant publication.
/// Rien ne part sur Confluence sans être passé sous les yeux de l'utilisateur.
struct ReviewWindow: View {
    @Bindable var session: RecordingSession
    @State private var draft = MeetingSummary()
    @State private var createJiraIssues = true
    @State private var loadedMeetingID: UUID?

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
        .onChange(of: session.reviewedMeeting?.id, initial: true) { load(meeting) }
        .onChange(of: session.summaryState) { load(session.reviewedMeeting ?? meeting) }
    }

    private func load(_ meeting: Meeting?) {
        guard let meeting, let summary = meeting.summary else { return }
        // Ne pas écraser les corrections en cours si la réunion n'a pas changé.
        guard loadedMeetingID != meeting.id || draft.title.isEmpty else { return }
        draft = summary
        loadedMeetingID = meeting.id
    }

    private func header(for meeting: Meeting) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(meeting.title).font(.title3.weight(.semibold)).lineLimit(1)
                HStack(spacing: 6) {
                    Label(
                        session.template(for: meeting).name,
                        systemImage: session.template(for: meeting).symbol
                    )
                    Text("·")
                    Text(meeting.startedAt.formatted(date: .long, time: .shortened))
                    Text("·")
                    Text(meeting.formattedDuration)
                    Text("·")
                    Text("\(meeting.outputLanguage.flag) \(meeting.outputLanguage.displayName)")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if meeting.hasSummary {
                Button("Régénérer") {
                    Task {
                        loadedMeetingID = nil
                        await session.generateSummary(for: meeting)
                    }
                }
            }
        }
        .padding()
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
        ContentUnavailableView {
            Label("Pas encore de compte rendu", systemImage: "sparkles")
        } description: {
            Text("Génère le compte rendu avec \(session.settings.providerKind.displayName).")
        } actions: {
            Button("Générer le compte rendu") {
                Task { await session.generateSummary(for: meeting) }
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private func editor(_ meeting: Meeting) -> some View {
        let template = session.template(for: meeting)
        return VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    field("Titre", text: $draft.title)
                    Label(
                        "Publié sous : " + template.pageTitle(
                            summaryTitle: draft.title, date: meeting.startedAt
                        ),
                        systemImage: "text.badge.checkmark"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    EditableList(title: "Participants", items: $draft.attendees)

                    // L'ordre d'édition suit celui du rendu : ce qu'on voit ici est ce
                    // qui sera publié, sections comprises.
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
            multiline(section.displayName, text: $draft.tldr, height: 70)
        case .blockers:
            blockersSection
        case .participantReports:
            participantReportsSection
        case .moods:
            moodsSection
        case .topics:
            topicsSection
        case .decisions:
            EditableList(title: section.displayName, items: $draft.decisions)
        case .actionItems:
            actionItemsSection
        case .openQuestions:
            EditableList(title: section.displayName, items: $draft.openQuestions)
        case .nextSteps:
            EditableList(title: section.displayName, items: $draft.nextSteps)
        }
    }

    private var blockersSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle(SummarySection.blockers.displayName)
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

    private var participantReportsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle(SummarySection.participantReports.displayName)
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

    /// Partie nominative destinée aux managers : elle doit rester relisible et
    /// corrigeable avant d'être transmise.
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

                    // Plusieurs icônes par personne : un sprint contrasté se raconte
                    // rarement avec une seule image.
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

    private var moodsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle(SummarySection.moods.displayName)
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
            if case .published(let url, let pageTitle, let issues, let failures) = session.publishState {
                VStack(alignment: .leading, spacing: 4) {
                    if let pageURL = URL(string: url) {
                        Link("« \(pageTitle) »", destination: pageURL).font(.callout)
                    }
                    if !issues.isEmpty {
                        Text("Tickets créés : \(issues.joined(separator: ", "))")
                            .font(.caption).foregroundStyle(.secondary)
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

            HStack(spacing: 8) {
                // La destination effective dépend du type de réunion et de la page de
                // sprint : on la montre avant de publier, pas après.
                Label(session.destinationSummary(for: template), systemImage: "tray.and.arrow.down")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
            }

            HStack {
                Toggle("Créer les tickets Jira cochés", isOn: $createJiraIssues)
                    .disabled(!session.settings.atlassian.isJiraReady)
                Spacer()
                Button("Copier en markdown") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(
                        draft.markdown(template: template, language: meeting.outputLanguage),
                        forType: .string
                    )
                }
                Button("Enregistrer") { session.saveReviewedSummary(draft) }
                Button("Publier sur Confluence") {
                    session.saveReviewedSummary(draft)
                    if let updated = session.reviewedMeeting {
                        Task { await session.publish(updated, createJiraIssues: createJiraIssues) }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!session.settings.canPublish)
            }
        }
        .padding()
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

/// Liste de chaînes éditable, utilisée pour toutes les sections à puces.
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
