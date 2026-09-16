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
        HSplitView {
            list
            detail
        }
        .onAppear(perform: normalizeSelection)
        .onChange(of: settings.activeProfileID) { normalizeSelection() }
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
        VStack(alignment: .leading, spacing: 6) {
            Text("Restriction Confluence")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack {
                TextField(
                    "E-mail",
                    text: Binding(
                        get: { person.email },
                        set: {
                            var updated = person
                            updated.email = $0
                            // A manual edit invalidates any accountId resolved
                            // from a previous search result.
                            updated.confluenceAccountID = ""
                            settings.upsert(updated)
                        }
                    )
                )
                .textFieldStyle(.roundedBorder)
                ConfluenceUserSearchButton(
                    search: { await session.searchConfluenceUsers(matching: $0) },
                    onSelect: { match in
                        var updated = person
                        updated.name = updated.name.isEmpty ? match.displayName : updated.name
                        updated.email = match.email ?? updated.email
                        updated.confluenceAccountID = match.accountID
                        settings.upsert(updated)
                    }
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
                        case .specificPage: .page(id: person.destination.pageID ?? "")
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
                            updated.destination = .page(id: normalizedPageID(value))
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
