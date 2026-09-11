import Atlassian
import Summarization
import SwiftUI

/// Éditeur des types de réunion. Les modèles fournis sont en lecture seule et se
/// dupliquent ; les modèles personnalisés se modifient librement.
struct TemplatesSettingsView: View {
    @Bindable var settings: AppSettings
    @Bindable var session: RecordingSession
    @State private var selectedID: String = MeetingTemplate.generic.id

    private var selected: MeetingTemplate {
        settings.template(id: selectedID)
    }

    var body: some View {
        HSplitView {
            list
            detail
        }
    }

    private var list: some View {
        VStack(spacing: 0) {
            List(selection: $selectedID) {
                Section("Fournis") {
                    ForEach(MeetingTemplate.builtIns) { template in
                        Label(template.name, systemImage: template.symbol).tag(template.id)
                    }
                }
                if !settings.customTemplates.isEmpty {
                    Section("Personnalisés") {
                        ForEach(settings.customTemplates) { template in
                            Label(template.name, systemImage: template.symbol).tag(template.id)
                        }
                    }
                }
            }
            .listStyle(.sidebar)

            HStack(spacing: 4) {
                Button {
                    let copy = settings.duplicate(selected)
                    selectedID = copy.id
                } label: {
                    Image(systemName: "plus")
                }
                .help("Dupliquer ce type")

                Button {
                    settings.remove(selected)
                    selectedID = MeetingTemplate.generic.id
                } label: {
                    Image(systemName: "minus")
                }
                .disabled(selected.isBuiltIn)
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
            VStack(alignment: .leading, spacing: 16) {
                if selected.isBuiltIn {
                    Label(
                        "Type fourni, non modifiable. Duplique-le pour l'adapter.",
                        systemImage: "lock"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                identity
                titleEditor
                destinationEditor
                sectionsEditor
                instructionsEditor

                Toggle(
                    "Type par défaut au démarrage",
                    isOn: Binding(
                        get: { settings.defaultTemplateID == selected.id },
                        set: { settings.defaultTemplateID = $0 ? selected.id : MeetingTemplate.generic.id }
                    )
                )
            }
            .padding()
            .disabled(selected.isBuiltIn)
            // Les modèles fournis restent lisibles malgré `disabled`.
            .opacity(selected.isBuiltIn ? 0.75 : 1)
        }
        .frame(minWidth: 330)
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Nom").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            TextField("Nom", text: binding(\.name)).textFieldStyle(.roundedBorder)
        }
    }

    /// Le titre produit par le modèle varie d'une réunion à l'autre ; le format
    /// impose une convention de nommage stable dans l'arborescence Confluence.
    private var titleEditor: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Titre de la page publiée")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            TextField("Format", text: binding(\.titleFormat)).textFieldStyle(.roundedBorder)

            Text("Aperçu : " + selected.pageTitle(
                summaryTitle: "Point sur la migration", date: .now
            ))
            .font(.caption)
            .foregroundStyle(.primary)

            FlowText(
                items: TitleFormat.placeholders.map { "\($0.token) → \($0.description)" }
            )
        }
    }

    private var destinationEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Destination")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Picker("Page parente", selection: parentModeBinding) {
                Text("Page de sprint courante").tag(ParentMode.sprint)
                Text("Page fixe").tag(ParentMode.fixed)
                Text("Accueil de l'espace").tag(ParentMode.home)
            }
            .pickerStyle(.radioGroup)

            if case .page(let id) = selected.parent {
                TextField(
                    "URL ou identifiant de la page",
                    text: Binding(
                        get: { id },
                        set: { newValue in
                            var template = selected
                            template.parent = .page(
                                id: SprintPage.extractPageID(from: newValue) ?? newValue
                            )
                            settings.upsert(template)
                        }
                    )
                )
                .textFieldStyle(.roundedBorder)
            }

            if !selected.parent.isSprintPage {
                TextField(
                    "Espace (vide = espace par défaut)",
                    text: binding(\.spaceKeyOverride)
                )
                .textFieldStyle(.roundedBorder)
            }

            Label(
                session.destinationSummary(for: selected),
                systemImage: "tray.and.arrow.down"
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            if selected.parent.isSprintPage, settings.sprintPage == nil {
                Label(
                    "Aucune page de sprint définie — onglet Atlassian. En attendant, les comptes rendus iront à l'accueil de l'espace.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }
        }
    }

    private enum ParentMode: Hashable { case sprint, fixed, home }

    private var parentModeBinding: Binding<ParentMode> {
        Binding(
            get: {
                switch selected.parent {
                case .sprintPage: .sprint
                case .page: .fixed
                case .spaceHome: .home
                }
            },
            set: { mode in
                var template = selected
                template.parent = switch mode {
                case .sprint: .sprintPage
                case .fixed: .page(id: selected.parent.fixedPageID ?? "")
                case .home: .spaceHome
                }
                settings.upsert(template)
            }
        )
    }

    private var sectionsEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Sections, dans l'ordre de rendu")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("L'ordre compte : il détermine à la fois ce qui est demandé au modèle et la disposition du compte rendu publié.")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            ForEach(Array(selected.sections.enumerated()), id: \.element) { index, section in
                HStack(spacing: 6) {
                    Text("\(index + 1).").font(.caption.monospaced()).foregroundStyle(.tertiary)
                    Text(section.displayName).font(.callout)
                    Spacer()
                    Button { move(section, by: -1) } label: { Image(systemName: "arrow.up") }
                        .disabled(index == 0)
                    Button { move(section, by: 1) } label: { Image(systemName: "arrow.down") }
                        .disabled(index == selected.sections.count - 1)
                    Button { toggle(section) } label: { Image(systemName: "minus.circle") }
                }
                .buttonStyle(.borderless)
            }

            let available = SummarySection.allCases.filter { !selected.sections.contains($0) }
            if !available.isEmpty {
                Menu("Ajouter une section") {
                    ForEach(available) { section in
                        Button(section.displayName) { toggle(section) }
                    }
                }
                .menuStyle(.borderlessButton)
                .frame(width: 170)
                .font(.caption)
            }
        }
    }

    private var instructionsEditor: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Consignes de rédaction")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            TextEditor(text: binding(\.instructions))
                .font(.callout)
                .frame(height: 170)
                .padding(4)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            Text("Ajoutées telles quelles au prompt. C'est ici qu'on décrit le ton, le niveau de détail, ou une règle particulière — par exemple ne nommer personne dans les sujets d'une rétrospective.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Édition

    private func binding<Value>(
        _ keyPath: WritableKeyPath<MeetingTemplate, Value>
    ) -> Binding<Value> {
        Binding(
            get: { selected[keyPath: keyPath] },
            set: { newValue in
                var template = selected
                template[keyPath: keyPath] = newValue
                settings.upsert(template)
            }
        )
    }

    private func toggle(_ section: SummarySection) {
        var template = selected
        if let index = template.sections.firstIndex(of: section) {
            template.sections.remove(at: index)
        } else {
            template.sections.append(section)
        }
        settings.upsert(template)
    }

    private func move(_ section: SummarySection, by offset: Int) {
        var template = selected
        guard let index = template.sections.firstIndex(of: section) else { return }
        let target = index + offset
        guard template.sections.indices.contains(target) else { return }
        template.sections.swapAt(index, target)
        settings.upsert(template)
    }
}

/// Liste compacte des jetons disponibles, sur plusieurs lignes.
private struct FlowText: View {
    let items: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(items, id: \.self) { item in
                Text(item).font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }
}
