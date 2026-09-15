import Atlassian
import Notion
import Summarization
import SwiftUI

/// Publication services, as a dynamic list rather than fixed tabs always
/// shown regardless of whether they're configured: only services the user
/// has actually added *under the active profile* appear here, with a `+` to
/// add Notion or Atlassian — and room for a third kind later without
/// restructuring this screen. Everything here (the enabled set, each
/// service's site/workspace, and its token) is scoped to `settings
/// .activeProfile`, so switching profiles switches which Confluence site or
/// Notion workspace is targeted.
struct ServicesSettingsView: View {
    @Bindable var settings: AppSettings
    @Bindable var session: RecordingSession
    @State private var selectedKind: ServiceKind?

    @State private var spaces: [ConfluenceSpaceSummary] = []
    @State private var issueTypes: [String] = []
    @State private var statusMessage: String?
    @State private var sprintPageInput: String = ""
    @State private var sprintStatus: String?
    @State private var isResolvingSprint = false
    @State private var notionPageInput: String = ""
    @State private var notionPageStatus: String?
    @State private var notionVerifyStatus: String?
    @State private var isVerifyingNotion = false
    @State private var notionDataSources: [NotionDataSourceSummary] = []
    @State private var notionTaskDatabaseName = "Tâches SmartMeet"
    @State private var notionTaskStatus: String?
    @State private var isLoadingNotionDataSources = false

    private var enabledSorted: [ServiceKind] {
        settings.enabledServices.sorted { $0.displayName < $1.displayName }
    }

    var body: some View {
        HSplitView {
            list
            detail
        }
        .onAppear {
            if selectedKind == nil || !settings.enabledServices.contains(selectedKind!) {
                selectedKind = enabledSorted.first
            }
        }
    }

    private var list: some View {
        VStack(spacing: 0) {
            List(selection: $selectedKind) {
                ForEach(enabledSorted) { kind in
                    Label(kind.displayName, systemImage: kind.symbol).tag(kind)
                }
            }
            .listStyle(.sidebar)

            HStack(spacing: 4) {
                let available = ServiceKind.allCases.filter { !settings.enabledServices.contains($0) }
                Menu {
                    ForEach(available) { kind in
                        Button(kind.displayName) {
                            settings.enabledServices.insert(kind)
                            selectedKind = kind
                        }
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .disabled(available.isEmpty)
                .help("Ajouter un service")

                if let selectedKind {
                    Button {
                        settings.enabledServices.remove(selectedKind)
                        if settings.activeProfile.defaultServiceKind == selectedKind {
                            var profile = settings.activeProfile
                            profile.defaultServiceKind = nil
                            settings.activeProfile = profile
                        }
                        if settings.enabledServices.isEmpty { settings.autoPublish = false }
                        self.selectedKind = enabledSorted.first
                    } label: {
                        Image(systemName: "minus")
                    }
                    .help("Retirer ce service (sa configuration est conservée)")
                }

                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(6)
        }
        .frame(minWidth: 160, maxWidth: 200)
    }

    @ViewBuilder
    private var detail: some View {
        if let selectedKind {
            switch selectedKind {
            case .atlassian: atlassianForm
            case .notion: notionForm
            }
        } else {
            ContentUnavailableView(
                "Aucun service configuré",
                systemImage: "tray",
                description: Text("Ajoute Notion ou Atlassian avec le bouton + pour publier tes comptes rendus.")
            )
            .frame(minWidth: 330)
        }
    }

    private var atlassianForm: some View {
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
                Toggle(
                    "Créer les tickets Jira lors des publications automatiques",
                    isOn: $settings.autoCreateJiraIssues
                )
                .disabled(!settings.atlassian.isJiraReady)
                Text("Certains projets imposent un epic parent via un validateur de workflow, que l'API createmeta ne déclare pas.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Cette option s'applique uniquement lorsque ce profil publie automatiquement via Atlassian.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            transcriptSection(for: .atlassian)

            HStack {
                Button("Tester la connexion") { Task { await loadRemoteOptions() } }
                if let statusMessage {
                    Text(statusMessage).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(minWidth: 330)
    }

    private var notionForm: some View {
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
                            settings.notion.parentPageID = ""
                            settings.notion.parentPageTitle = ""
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

            Section("Base de tâches") {
                if settings.notion.isTaskDataSourceConfigured {
                    HStack {
                        Text(settings.notion.taskDataSourceTitle.isEmpty
                            ? settings.notion.taskDataSourceID
                            : settings.notion.taskDataSourceTitle)
                            .lineLimit(1)
                        Spacer()
                        Button("Retirer") {
                            settings.notion.taskDataSourceID = ""
                            settings.notion.taskDataSourceTitle = ""
                            settings.autoCreateNotionTasks = false
                        }
                    }
                }

                HStack {
                    Picker("Base existante", selection: Binding(
                        get: { settings.notion.taskDataSourceID },
                        set: { id in
                            settings.notion.taskDataSourceID = id
                            settings.notion.taskDataSourceTitle = notionDataSources
                                .first { $0.id == id }?.title ?? ""
                        }
                    )) {
                        Text("Choisir…").tag("")
                        ForEach(notionDataSources) { source in
                            Text(source.title).tag(source.id)
                        }
                    }
                    Button(isLoadingNotionDataSources ? "…" : "Actualiser") {
                        Task { await loadNotionDataSources() }
                    }
                    .disabled(isLoadingNotionDataSources || !settings.canPublishToNotion)
                }

                HStack {
                    TextField("Nom de la nouvelle base", text: $notionTaskDatabaseName)
                    Button("Créer") { Task { await createNotionTaskDataSource() } }
                        .disabled(
                            notionTaskDatabaseName.trimmingCharacters(in: .whitespaces).isEmpty
                                || !settings.notion.isConfigured
                                || !settings.canPublishToNotion
                        )
                }

                Toggle(
                    "Créer des tâches Notion lors des publications automatiques",
                    isOn: $settings.autoCreateNotionTasks
                )
                .disabled(!settings.notion.isTaskDataSourceConfigured)

                Text("La base doit être partagée avec l'intégration. Une base créée ici contient les colonnes Name, Owner, Due, Type et Meeting.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let notionTaskStatus {
                    Text(notionTaskStatus).font(.caption).foregroundStyle(.secondary)
                }
            }

            transcriptSection(for: .notion)

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
        .frame(minWidth: 330)
    }

    private func transcriptSection(for service: ServiceKind) -> some View {
        Section("Transcription") {
            Toggle(
                "Inclure la transcription dans la page publiée",
                isOn: Binding(
                    get: { settings.includesTranscript(for: service) },
                    set: { settings.setIncludesTranscript($0, for: service) }
                )
            )
            Text("Lorsqu'elle est incluse, la transcription apparaît tout en bas dans un accordéon replié.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// `NSWorkspace.shared.open(url)` honors universal links: if the Notion
    /// desktop app is installed, it intercepts every `notion.so` link — including
    /// `/my-integrations`, a page that only exists on the web and that the
    /// desktop app can't display. So the default browser is forced explicitly
    /// rather than letting macOS route the URL.
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

    private func loadNotionDataSources() async {
        isLoadingNotionDataSources = true
        notionTaskStatus = L("Connexion…")
        let client = NotionClient(configuration: settings.notion, token: settings.notionToken)
        do {
            notionDataSources = try await client.dataSources()
            notionTaskStatus = L("✅ %d base(s) accessible(s)", notionDataSources.count)
        } catch {
            notionTaskStatus = L("❌ %@", error.localizedDescription)
        }
        isLoadingNotionDataSources = false
    }

    private func createNotionTaskDataSource() async {
        isLoadingNotionDataSources = true
        notionTaskStatus = L("Création…")
        let title = notionTaskDatabaseName.trimmingCharacters(in: .whitespaces)
        let client = NotionClient(configuration: settings.notion, token: settings.notionToken)
        do {
            let source = try await client.createTaskDataSource(title: title)
            notionDataSources.append(source)
            notionDataSources.sort { $0.title < $1.title }
            settings.notion.taskDataSourceID = source.id
            settings.notion.taskDataSourceTitle = source.title
            notionTaskStatus = L("✅ Base créée et sélectionnée.")
        } catch {
            notionTaskStatus = L("❌ %@", error.localizedDescription)
        }
        isLoadingNotionDataSources = false
    }

    /// The sprint page is set once at the start of a sprint; every meeting
    /// type that references it then follows automatically.
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
