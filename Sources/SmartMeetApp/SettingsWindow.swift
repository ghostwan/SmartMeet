import Atlassian
import Diarization
import Notion
import Summarization
import SwiftUI
import Transcription

struct SettingsWindow: View {
    @Bindable var settings: AppSettings
    /// Nécessaire pour résoudre la page de sprint, qui exige un appel réseau.
    @Bindable var session: RecordingSession
    @State private var spaces: [ConfluenceSpaceSummary] = []
    @State private var issueTypes: [String] = []
    @State private var statusMessage: String?
    @State private var vocabularyText: String = ""
    @State private var knownPeopleText: String = ""
    @State private var sprintPageInput: String = ""
    @State private var sprintStatus: String?
    @State private var isResolvingSprint = false
    @State private var notionPageInput: String = ""
    @State private var notionPageStatus: String?
    @State private var notionVerifyStatus: String?
    @State private var isVerifyingNotion = false
    @State private var availableLocales: [(id: String, label: String)] = []

    var body: some View {
        TabView {
            transcriptionTab.tabItem { Label("Transcription", systemImage: "waveform") }
            summaryTab.tabItem { Label("Compte rendu", systemImage: "sparkles") }
            TemplatesSettingsView(settings: settings, session: session)
                .tabItem { Label("Types de réunion", systemImage: "square.stack") }
            atlassianTab.tabItem { Label("Atlassian", systemImage: "cloud") }
            notionTab.tabItem { Label("Notion", systemImage: "doc.text.image") }
        }
        .frame(width: 760, height: 480)
        .onAppear {
            vocabularyText = settings.vocabulary.joined(separator: ", ")
            knownPeopleText = settings.knownPeople.joined(separator: ", ")
        }
        .task { await loadLocales() }
    }

    /// Construit la liste des langues à partir de ce que le framework `Speech`
    /// sait effectivement transcrire sur cette machine, plutôt qu'une liste figée.
    private func loadLocales() async {
        availableLocales = await SupportedTranscriptionLocales.all()
        // Ancien format d'identifiant (ex. « fr-FR ») non présent tel quel dans la
        // liste renvoyée par le framework (ex. « fr_FR ») : on migre silencieusement
        // vers l'identifiant exact pour que le picker affiche la bonne sélection.
        guard !availableLocales.contains(where: { $0.id == settings.localeIdentifier }) else { return }
        if let resolved = await SupportedTranscriptionLocales.resolvedIdentifier(for: settings.locale) {
            settings.localeIdentifier = resolved
        }
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
                ForEach(availableLocales, id: \.id) { locale in
                    Text(locale.label).tag(locale.id)
                }
            }
            if availableLocales.isEmpty {
                Text("Chargement des langues disponibles…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

            Section("Personnes") {
                TextEditor(text: $knownPeopleText)
                    .frame(height: 80)
                    .font(.callout)
                    .onChange(of: knownPeopleText) {
                        settings.knownPeople = knownPeopleText
                            .split(whereSeparator: { $0 == "," || $0 == "\n" })
                            .map { $0.trimmingCharacters(in: .whitespaces) }
                            .filter { !$0.isEmpty }
                    }
                Text("Prénoms (et noms) des personnes avec qui tu interagis régulièrement, bien orthographiés, séparés par des virgules. Comme le vocabulaire métier, ils sont injectés dans le moteur de reconnaissance et dans le prompt — utile quand la transcription ou le compte rendu déforme un prénom.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Toggle("Utiliser le calendrier pour le titre et les participants", isOn: $settings.useCalendar)

            Section("Détection des réunions") {
                Toggle("Proposer d'enregistrer quand une réunion est détectée", isOn: $settings.detectMeetings)
                Toggle("Démarrer sans demander", isOn: $settings.autoStartOnDetection)
                    .disabled(!settings.detectMeetings)
                Text("La détection combine le calendrier et l'application de visioconférence qui capte le micro. Le démarrage automatique reste désactivé par défaut : enregistrer des personnes sans les prévenir n'est pas un comportement à activer à leur place.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle(
                    "Proposer de générer le compte rendu quand la réunion semble terminée",
                    isOn: $settings.detectMeetingEnd
                )
                Text("Basé sur l'application de visioconférence qui n'utilise plus le micro depuis un moment — une simple proposition, jamais un arrêt automatique : une coupure passagère (réseau, micro coupé volontairement…) ne doit pas arrêter l'enregistrement à ta place.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Diarisation (expérimental)") {
                Toggle(
                    "Distinguer les voix sur le micro (réunion en présentiel)",
                    isOn: $settings.diarizeMicrophoneTrack
                )
                Text(L(
                    "Pour une réunion où plusieurs personnes parlent dans le même micro. Basé sur la hauteur et le timbre de la voix, pas sur un modèle de reconnaissance vocale : fonctionne surtout quand les voix sont nettement différentes, et jusqu'à %d locuteurs. Une seule voix n'est pas scindée à tort si la séparation n'est pas nette.",
                    MicrophoneDiarizer.defaultMaxSpeakers
                ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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

            Picker("Langue par défaut du compte rendu", selection: $settings.defaultOutputLanguage) {
                ForEach(SummaryLanguage.allCases) { language in
                    Text("\(language.flag) \(language.displayName)").tag(language)
                }
            }
            Text("Modifiable avant chaque enregistrement. Indépendante de la langue parlée en réunion : une équipe francophone peut livrer un compte rendu en anglais.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Section("À l'arrêt de l'enregistrement") {
                Toggle("Générer le compte rendu", isOn: $settings.autoSummarize)
                Toggle("Publier sur Confluence sans relecture", isOn: $settings.autoPublish)
                    .disabled(!settings.autoSummarize || !settings.canPublish)
                Toggle("Créer aussi les tickets Jira", isOn: $settings.autoCreateJiraIssues)
                    .disabled(!settings.autoPublish || !settings.atlassian.isJiraReady)
                Text("Une notification prévient dès que le compte rendu est prêt, avec le lien vers la page si la publication est automatique. La publication sans relecture reste désactivée par défaut : un compte rendu écrit par un modèle mérite un coup d'œil avant d'atterrir sur un espace d'équipe.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var atlassianTab: some View {
        Form {
            Section("Compte") {
                TextField("Site", text: $settings.atlassian.site, prompt: Text("acme"))
                TextField("E-mail", text: $settings.atlassian.email)
                SecureField("Jeton d'API", text: $settings.atlassianToken)
                Button("Générer un jeton sur id.atlassian.com") {
                    openInBrowser(URL(string: "https://id.atlassian.com/manage-profile/security/api-tokens")!)
                }
                .buttonStyle(.link)
                .font(.caption)
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

    private var notionTab: some View {
        Form {
            Section("Intégration") {
                SecureField("Jeton d'intégration", text: $settings.notionToken)
                Button("Créer une intégration sur notion.so/my-integrations") {
                    openInBrowser(URL(string: "https://www.notion.so/my-integrations")!)
                }
                .buttonStyle(.link)
                .font(.caption)
                Text("Crée une intégration interne sur notion.so/my-integrations, copie son jeton ici, puis partage la page parente ci-dessous avec elle (••• sur la page → Connexions → ton intégration). Le jeton est conservé dans le trousseau, jamais dans les préférences.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Page parente") {
                if settings.notion.isConfigured {
                    HStack {
                        Text(settings.notion.parentPageID).font(.callout).lineLimit(1)
                        Spacer()
                        Button("Retirer") {
                            settings.notion = NotionConfiguration()
                            notionPageStatus = nil
                        }
                    }
                } else {
                    Label(
                        "Aucune page parente : les comptes rendus seront créés à la racine de l'espace (pages privées de l'intégration).",
                        systemImage: "tray"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                HStack {
                    TextField(
                        settings.notion.isConfigured ? "Changer de page" : "URL ou identifiant de la page (optionnel)",
                        text: $notionPageInput
                    )
                    .onSubmit { applyNotionPage() }

                    Button("Définir") { applyNotionPage() }
                        .disabled(notionPageInput.isEmpty)
                }

                if let notionPageStatus {
                    Text(notionPageStatus).font(.caption).foregroundStyle(.secondary)
                }

                Text("Colle l'URL d'une page Notion pour y créer les comptes rendus en enfant (la page doit être partagée avec l'intégration ci-dessus). Sans page définie, ils sont créés à la racine de l'espace connecté au jeton.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button(isVerifyingNotion ? "…" : "Tester la connexion") {
                    Task { await verifyNotionAccess() }
                }
                .disabled(isVerifyingNotion || !settings.canPublishToNotion)
                if let notionVerifyStatus {
                    Text(notionVerifyStatus).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    /// `NSWorkspace.shared.open(url)` respecte les liens universels : si l'app
    /// desktop Notion est installée, elle intercepte tout lien `notion.so` — y
    /// compris `/my-integrations`, une page qui n'existe que sur le web et que
    /// l'app desktop ne sait pas afficher. On force donc explicitement le
    /// navigateur par défaut plutôt que de laisser macOS router l'URL.
    private func openInBrowser(_ url: URL) {
        guard let browser = NSWorkspace.shared.urlForApplication(
            toOpen: URL(string: "https://apple.com")!
        ) else {
            NSWorkspace.shared.open(url)
            return
        }
        NSWorkspace.shared.open(
            [url], withApplicationAt: browser, configuration: NSWorkspace.OpenConfiguration()
        )
    }

    private func applyNotionPage() {
        guard let id = NotionConfiguration.extractPageID(from: notionPageInput) else {
            notionPageStatus = L("❌ Identifiant ou URL de page non reconnu.")
            return
        }
        settings.notion.parentPageID = id
        notionPageStatus = L("✅ Page enregistrée.")
        notionPageInput = ""
    }

    private func verifyNotionAccess() async {
        isVerifyingNotion = true
        notionVerifyStatus = L("Connexion…")
        let client = NotionClient(configuration: settings.notion, token: settings.notionToken)
        do {
            try await client.verifyAccess()
            notionVerifyStatus = L("✅ Connexion réussie.")
        } catch {
            notionVerifyStatus = L("❌ %@", error.localizedDescription)
        }
        isVerifyingNotion = false
    }

    /// La page de sprint se fixe une fois en début de sprint ; tous les types de
    /// réunion qui la référencent suivent ensuite automatiquement.
    private var sprintSection: some View {
        Section("Page de sprint courante") {
            if let sprint = settings.sprintPage {
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(sprint.title).font(.callout).lineLimit(1)
                        Text(L(
                            "%@ · définie le %@",
                            sprint.spaceKey,
                            sprint.setAt.formatted(date: .abbreviated, time: .shortened)
                        ))
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

            if settings.sprintPage != nil {
                Text("Changer de page ne migre pas les comptes rendus déjà publiés : ils restent sur l'ancienne page de sprint.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private func applySprintPage() async {
        isResolvingSprint = true
        sprintStatus = await session.setSprintPage(from: sprintPageInput)
        isResolvingSprint = false
        if settings.sprintPage != nil { sprintPageInput = "" }
    }

    private func loadRemoteOptions() async {
        statusMessage = L("Connexion…")
        let configuration = settings.atlassian
        let token = settings.atlassianToken

        do {
            let confluence = ConfluenceClient(configuration: configuration, token: token)
            spaces = try await confluence.spaces().sorted { $0.name < $1.name }

            if configuration.isJiraReady {
                let jira = JiraClient(configuration: configuration, token: token)
                issueTypes = (try? await jira.issueTypes()) ?? []
            }
            statusMessage = L("✅ %d espaces, %d types de ticket", spaces.count, issueTypes.count)
        } catch {
            statusMessage = L("❌ %@", error.localizedDescription)
        }
    }
}
