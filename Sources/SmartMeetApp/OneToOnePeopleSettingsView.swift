import AppKit
import Atlassian
import Notion
import Summarization
import SwiftUI

/// Configures the recurring one-to-one counterparts for the active profile:
/// each carries its own publication destination and Jira share e-mail, so
/// picking a name at recording time is enough — no path or address to type
/// again every time.
struct OneToOnePeopleSettingsView: View {
    @Bindable var settings: AppSettings
    @Bindable var session: RecordingSession
    @State private var selectedID: String?

    private var people: [OneToOnePerson] { settings.oneToOnePeople }

    private var selected: OneToOnePerson? {
        people.first { $0.id == selectedID }
    }

    var body: some View {
        VStack(spacing: 0) {
            defaultFolderEditor
                .padding([.horizontal, .top])
            Divider().padding(.top, 12)
            HSplitView {
                list
                detail
            }
        }
        .onAppear(perform: normalizeSelection)
        .onChange(of: settings.activeProfileID) { normalizeSelection() }
    }

    /// Default local folder every one-to-one's minutes are saved to as
    /// markdown, unless the person has their own (see `folderEditor`
    /// below) — set once for the whole profile instead of on every person.
    private var defaultFolderEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Dossier de sauvegarde par défaut")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            folderPicker(
                path: settings.oneToOneDefaultFolderPath,
                onChoose: { settings.oneToOneDefaultFolderPath = $0 },
                onClear: { settings.oneToOneDefaultFolderPath = "" }
            )
            Text("Chaque one-to-one enregistre aussi son compte rendu en markdown dans ce dossier, sauf si la personne a le sien.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private var list: some View {
        VStack(spacing: 0) {
            List(selection: $selectedID) {
                ForEach(people) { person in
                    Text(person.name.isEmpty ? L("Sans nom") : person.name)
                        .tag(Optional(person.id))
                }
            }
            .listStyle(.sidebar)

            HStack(spacing: 4) {
                Button {
                    let person = settings.createOneToOnePerson()
                    selectedID = person.id
                } label: {
                    Image(systemName: "plus")
                }
                .help("Ajouter une personne")

                Button {
                    guard let selected else { return }
                    settings.removeOneToOnePerson(selected)
                    normalizeSelection()
                } label: {
                    Image(systemName: "minus")
                }
                .disabled(selected == nil)
                .help("Supprimer")

                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(6)
        }
        .frame(minWidth: 170, maxWidth: 220)
    }

    private var detail: some View {
        ScrollView {
            if let selected {
                VStack(alignment: .leading, spacing: 16) {
                    identity(selected)
                    restrictionEditor(selected)
                    destinationEditor(selected)
                    folderEditor(selected)
                    jiraShareEditor(selected)
                }
                .padding()
            } else {
                ContentUnavailableView(
                    "Aucune personne",
                    systemImage: "person.crop.circle.badge.questionmark",
                    description: Text(
                        "Ajoute les personnes avec qui tu fais des one-to-one réguliers : à l'enregistrement, il ne restera qu'à les choisir dans une liste."
                    )
                )
                .padding()
            }
        }
        .frame(minWidth: 330)
    }

    private func identity(_ person: OneToOnePerson) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Nom").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            TextField(
                "Nom",
                text: Binding(
                    get: { person.name },
                    set: { var updated = person; updated.name = $0; settings.upsert(updated) }
                )
            )
            .textFieldStyle(.roundedBorder)
        }
    }

    private func restrictionEditor(_ person: OneToOnePerson) -> some View {
        let emailBinding = Binding(
            get: { person.email },
            set: {
                var updated = person
                updated.email = $0
                // A manual edit invalidates any accountId resolved from a
                // previous search result.
                updated.confluenceAccountID = ""
                settings.upsert(updated)
            }
        )
        return VStack(alignment: .leading, spacing: 6) {
            Text("Restriction Confluence")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack {
                TextField("Nom ou e-mail", text: emailBinding)
                    .textFieldStyle(.roundedBorder)
                // Searches Confluence directly off whatever is typed above
                // (name or e-mail) instead of asking for it again in a
                // separate field.
                ConfluenceUserSearchButton(
                    search: { await session.searchConfluenceUsers(matching: $0) },
                    onSelect: { match in
                        var updated = person
                        updated.name = updated.name.isEmpty ? match.displayName : updated.name
                        updated.email = match.email ?? updated.email
                        updated.confluenceAccountID = match.accountID
                        // A found account's e-mail is also a sensible default
                        // for the Jira watcher, if not already set.
                        if updated.jiraShareEmail.isEmpty, let email = match.email {
                            updated.jiraShareEmail = email
                        }
                        settings.upsert(updated)
                    },
                    externalQuery: emailBinding
                )
            }
            Text("La page publiée ne sera visible que de toi et de cette personne, si son compte Confluence est trouvé.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func destinationEditor(_ person: OneToOnePerson) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Page de publication")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Picker(
                "Page de publication",
                selection: Binding(
                    get: { destinationMode(for: person) },
                    set: { mode in
                        var updated = person
                        updated.destination = switch mode {
                        case .typeDefault: .profileDefault
                        // Reuses the last page typed here, if any, instead
                        // of starting from an empty field every time —
                        // `person.destination.pageID` alone would be `nil`
                        // as soon as `.typeDefault` was selected in between.
                        case .specificPage: .page(id: person.lastManualPageID)
                        }
                        settings.upsert(updated)
                    }
                )
            ) {
                Text("Destination du type de réunion").tag(DestinationMode.typeDefault)
                Text("Page spécifique").tag(DestinationMode.specificPage)
            }
            .labelsHidden()
            .pickerStyle(.radioGroup)

            if case .page(let id) = person.destination {
                TextField(
                    "URL ou identifiant de la page",
                    text: Binding(
                        get: { id },
                        set: { value in
                            var updated = person
                            let normalized = normalizedPageID(value)
                            updated.destination = .page(id: normalized)
                            updated.lastManualPageID = normalized
                            settings.upsert(updated)
                        }
                    )
                )
                .textFieldStyle(.roundedBorder)
            }

            Text("Ses one-to-one se publient toujours ici, quel que soit le service par défaut du type « one-to-one ».")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func folderEditor(_ person: OneToOnePerson) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Dossier de sauvegarde")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            folderPicker(
                path: person.localFolderPath,
                onChoose: { path in
                    var updated = person
                    updated.localFolderPath = path
                    settings.upsert(updated)
                },
                onClear: {
                    var updated = person
                    updated.localFolderPath = ""
                    settings.upsert(updated)
                }
            )
            Text("Remplace le dossier par défaut pour cette personne uniquement.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    /// Path display plus the two actions ("Choisir…" / clear) shared by the
    /// profile-wide default folder and each person's own override.
    private func folderPicker(
        path: String, onChoose: @escaping (String) -> Void, onClear: @escaping () -> Void
    ) -> some View {
        HStack {
            Text(path.isEmpty ? L("Aucun dossier choisi") : path)
                .font(.caption)
                .foregroundStyle(path.isEmpty ? .tertiary : .primary)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer()
            Button(L("Choisir…")) { chooseFolder(onChoose: onChoose) }
            if !path.isEmpty {
                Button(L("Effacer"), action: onClear)
            }
        }
    }

    private func chooseFolder(onChoose: @escaping (String) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = L("Choisir")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        onChoose(url.path)
    }

    private func jiraShareEditor(_ person: OneToOnePerson) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Partage Jira")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            TextField(
                "E-mail à ajouter en observateur des tickets",
                text: Binding(
                    get: { person.jiraShareEmail },
                    set: {
                        var updated = person
                        updated.jiraShareEmail = $0
                        settings.upsert(updated)
                    }
                )
            )
            .textFieldStyle(.roundedBorder)
            Text("Chaque ticket Jira créé à partir des action items de ce one-to-one ajoute cette adresse comme observateur, en plus de la personne assignée.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private enum DestinationMode: Hashable { case typeDefault, specificPage }

    private func destinationMode(for person: OneToOnePerson) -> DestinationMode {
        switch person.destination {
        case .profileDefault: .typeDefault
        case .page: .specificPage
        }
    }

    private func normalizedPageID(_ input: String) -> String {
        SprintPage.extractPageID(from: input)
            ?? NotionConfiguration.extractPageID(from: input)
            ?? input
    }

    private func normalizeSelection() {
        guard selectedID == nil || !people.contains(where: { $0.id == selectedID }) else { return }
        selectedID = people.first?.id
    }
}
