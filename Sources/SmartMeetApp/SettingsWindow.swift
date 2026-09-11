import Atlassian
import Summarization
import SwiftUI

struct SettingsWindow: View {
    @Bindable var settings: AppSettings
    /// Nécessaire pour résoudre la page de sprint, qui exige un appel réseau.
    @Bindable var session: RecordingSession
    @State private var spaces: [ConfluenceSpaceSummary] = []
    @State private var issueTypes: [String] = []
    @State private var statusMessage: String?
    @State private var vocabularyText: String = ""
    @State private var sprintPageInput: String = ""
    @State private var sprintStatus: String?
    @State private var isResolvingSprint = false

    var body: some View {
        TabView {
            transcriptionTab.tabItem { Label("Transcription", systemImage: "waveform") }
            summaryTab.tabItem { Label("Compte rendu", systemImage: "sparkles") }
            TemplatesSettingsView(settings: settings, session: session)
                .tabItem { Label("Types de réunion", systemImage: "square.stack") }
            atlassianTab.tabItem { Label("Atlassian", systemImage: "cloud") }
        }
        .frame(width: 620, height: 480)
        .onAppear { vocabularyText = settings.vocabulary.joined(separator: ", ") }
    }

    private var transcriptionTab: some View {
        Form {
            Section("Identité") {
                TextField("Votre nom", text: $settings.userName)
                Text("Le transcript ne vous désigne que par « Moi ». Ce nom permet de vous attribuer correctement décisions et action items.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Picker("Langue", selection: $settings.localeIdentifier) {
                Text("Français").tag("fr-FR")
                Text("English (US)").tag("en-US")
                Text("English (UK)").tag("en-GB")
                Text("Deutsch").tag("de-DE")
                Text("Español").tag("es-ES")
                Text("Italiano").tag("it-IT")
            }

            Section("Vocabulaire métier") {
                TextEditor(text: $vocabularyText)
                    .frame(height: 80)
                    .font(.callout)
                    .onChange(of: vocabularyText) {
                        settings.vocabulary = vocabularyText
                            .split(whereSeparator: { $0 == "," || $0 == "\n" })
                            .map { $0.trimmingCharacters(in: .whitespaces) }
                            .filter { !$0.isEmpty }
                    }
                Text("Noms propres et termes métier, séparés par des virgules. Ils sont injectés dans le moteur de reconnaissance et dans le prompt.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Toggle("Utiliser le calendrier pour le titre et les participants", isOn: $settings.useCalendar)
        }
        .formStyle(.grouped)
        .padding()
    }

    private var summaryTab: some View {
        Form {
            Picker("Provider", selection: $settings.providerKind) {
                ForEach(SummaryProviderKind.allCases) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }

            switch settings.providerKind {
            case .opencode:
                TextField("Modèle", text: $settings.opencodeModel)
                Text("Passe par le binaire `opencode`, client Copilot authentifié. Aucune API publique ne permet d'utiliser un abonnement Copilot directement depuis une application tierce.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .ollama:
                TextField("Modèle", text: $settings.ollamaModel)
                Text("Entièrement local : aucune donnée ne quitte la machine. Qualité inférieure sur la résolution des dates relatives.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Toggle("Générer le compte rendu automatiquement à l'arrêt", isOn: $settings.autoSummarize)
        }
        .formStyle(.grouped)
        .padding()
    }

    private var atlassianTab: some View {
        Form {
            Section("Compte") {
                TextField("Site", text: $settings.atlassian.site, prompt: Text("ACME"))
                TextField("E-mail", text: $settings.atlassian.email)
                SecureField("Jeton d'API", text: $settings.atlassianToken)
                Text("Le jeton est conservé dans le trousseau, jamais dans les préférences.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Confluence par défaut") {
                if spaces.isEmpty {
                    TextField("Clé de l'espace", text: $settings.atlassian.spaceKey)
                } else {
                    Picker("Espace", selection: $settings.atlassian.spaceKey) {
                        ForEach(spaces) { space in
                            Text("\(space.name) (\(space.key))").tag(space.key)
                        }
                    }
                }
                TextField(
                    "Page parente (id, vide = accueil)",
                    text: $settings.atlassian.parentPageID
                )
                Text("Valeurs utilisées par les types de réunion qui ne définissent pas leur propre destination.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            sprintSection

            Section("Jira") {
                TextField("Projet", text: $settings.atlassian.jiraProjectKey)
                if issueTypes.isEmpty {
                    TextField("Type de ticket", text: $settings.atlassian.jiraIssueType)
                } else {
                    Picker("Type de ticket", selection: $settings.atlassian.jiraIssueType) {
                        ForEach(issueTypes, id: \.self) { Text($0).tag($0) }
                    }
                }
                TextField("Epic parent", text: $settings.atlassian.jiraParentKey)
                Text("Certains projets imposent un epic parent via un validateur de workflow, que l'API createmeta ne déclare pas.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("Tester la connexion") { Task { await loadRemoteOptions() } }
                if let statusMessage {
                    Text(statusMessage).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    /// La page de sprint se fixe une fois en début de sprint ; tous les types de
    /// réunion qui la référencent suivent ensuite automatiquement.
    private var sprintSection: some View {
        Section("Page de sprint courante") {
            if let sprint = settings.sprintPage {
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(sprint.title).font(.callout).lineLimit(1)
                        Text("\(sprint.spaceKey) · définie le \(sprint.setAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Retirer") {
                        session.clearSprintPage()
                        sprintStatus = nil
                    }
                }
            }

            HStack {
                TextField(
                    settings.sprintPage == nil ? "URL ou identifiant de la page" : "Changer de page",
                    text: $sprintPageInput
                )
                .onSubmit { Task { await applySprintPage() } }

                Button(isResolvingSprint ? "…" : "Définir") {
                    Task { await applySprintPage() }
                }
                .disabled(sprintPageInput.isEmpty || isResolvingSprint)
            }

            if let sprintStatus {
                Text(sprintStatus).font(.caption).foregroundStyle(.secondary)
            }

            Text("Colle l'URL de la page qui agrège le sprint. Les types de réunion réglés sur « page de sprint » y publieront leurs comptes rendus, dans l'espace de cette page.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func applySprintPage() async {
        isResolvingSprint = true
        sprintStatus = await session.setSprintPage(from: sprintPageInput)
        isResolvingSprint = false
        if settings.sprintPage != nil { sprintPageInput = "" }
    }

    private func loadRemoteOptions() async {
        statusMessage = "Connexion…"
        let configuration = settings.atlassian
        let token = settings.atlassianToken

        do {
            let confluence = ConfluenceClient(configuration: configuration, token: token)
            spaces = try await confluence.spaces().sorted { $0.name < $1.name }

            if configuration.isJiraReady {
                let jira = JiraClient(configuration: configuration, token: token)
                issueTypes = (try? await jira.issueTypes()) ?? []
            }
            statusMessage = "✅ \(spaces.count) espaces, \(issueTypes.count) types de ticket"
        } catch {
            statusMessage = "❌ \(error.localizedDescription)"
        }
    }
}
