import Atlassian
import Notion
import Summarization
import SwiftUI

/// Meeting-type editor for the active profile. The sidebar is the profile's
/// actual list, not a global inventory with hidden rows: built-ins are added
/// from the `+` menu and remain editable, while a blank custom type can be
/// created from scratch.
struct TemplatesSettingsView: View {
    @Bindable var settings: AppSettings
    @Bindable var session: RecordingSession
    @State private var selectedID: String = MeetingTemplate.personal.id

    private var selected: MeetingTemplate {
        settings.template(id: selectedID)
    }

    /// True if the selected built-in type has been edited (override stored
    /// in custom templates, under the same identifier).
    private var hasOverride: Bool {
        settings.customTemplates.contains { $0.id == selectedID }
    }

    private var activeTemplates: [MeetingTemplate] { settings.allTemplates }

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
                ForEach(activeTemplates) { template in
                    row(for: template)
                }
            }
            .listStyle(.sidebar)

            HStack(spacing: 4) {
                Menu {
                    if !settings.availableBuiltInTemplates.isEmpty {
                        Section("Modèles fournis") {
                            ForEach(settings.availableBuiltInTemplates) { template in
                                Button {
                                    settings.addBuiltInTemplate(template)
                                    selectedID = template.id
                                    session.selectedTemplateID = settings.defaultTemplateID
                                } label: {
                                    Label(template.localizedName, systemImage: template.symbol)
                                }
                            }
                        }
                    }
                    Button {
                        let template = settings.createCustomTemplate()
                        selectedID = template.id
                    } label: {
                        Label("Nouveau type personnalisé", systemImage: "doc.badge.plus")
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .help("Ajouter un type de réunion")

                Button {
                    let removedID = selected.id
                    settings.removeTemplateFromActiveProfile(selected)
                    normalizeSelection()
                    if session.selectedTemplateID == removedID {
                        session.selectedTemplateID = settings.defaultTemplateID
                    }
                } label: {
                    Image(systemName: "minus")
                }
                .disabled(activeTemplates.count <= 1)
                .help(selected.hasBuiltInIdentity ? "Retirer ce type du profil" : "Supprimer")

                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(6)
        }
        .frame(minWidth: 170, maxWidth: 220)
    }

    private func row(for template: MeetingTemplate) -> some View {
        Label(template.localizedName, systemImage: template.symbol)
            .tag(template.id)
    }

    private var detail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if selected.hasBuiltInIdentity {
                    Label(
                        L("Type fourni et modifiable. La réinitialisation restaure sa version d'origine."),
                        systemImage: "pencil"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    if hasOverride {
                        Button("Réinitialiser au modèle d'origine") {
                            settings.resetBuiltInTemplate(selected)
                        }
                    }
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
                        set: { if $0 { settings.defaultTemplateID = selected.id } }
                    )
                )
            }
            .padding()
        }
        .frame(minWidth: 330)
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Nom").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            TextField("Nom", text: nameBinding).textFieldStyle(.roundedBorder)
        }
    }

    /// An untouched built-in is shown in the app's language, but the first
    /// edit becomes an explicit persisted override and is never translated.
    private var nameBinding: Binding<String> {
        Binding(
            get: { selected.localizedName },
            set: { newValue in
                var template = selected
                template.name = newValue
                settings.upsert(template)
            }
        )
    }

    /// The title produced by the model varies from one meeting to another;
    /// the format enforces a stable naming convention within the Confluence
    /// tree.
    private var titleEditor: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Titre de la page publiée")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            TextField("Format", text: binding(\.titleFormat)).textFieldStyle(.roundedBorder)

            Text(L("Aperçu : %@", selected.pageTitle(
                summaryTitle: L("Point sur la migration"),
                date: .now,
                language: settings.defaultOutputLanguage
            )))
            .font(.caption)
            .foregroundStyle(.primary)

            Text("Les parties littérales ne sont pas traduites : seuls les jetons de date suivent la langue du compte rendu.")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            FlowText(
                items: TitleFormat.placeholders.map { "\($0.token) → \(L($0.description))" }
            )
        }
    }

    private var destinationEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Destination")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Picker("Service de publication", selection: Binding(
                get: { selected.serviceKind },
                set: { service in
                    var template = selected
                    if template.serviceKind != service {
                        template.serviceKind = service
                        template.destination = .profileDefault
                    }
                    settings.upsert(template)
                }
            )) {
                Text(inheritedServiceLabel).tag(ServiceKind?.none)
                ForEach(settings.enabledServices.sorted { $0.displayName < $1.displayName }) { kind in
                    Text(kind.displayName).tag(ServiceKind?.some(kind))
                }
            }

            Picker("Page de publication", selection: destinationModeBinding) {
                Text("Destination par défaut du profil").tag(DestinationMode.profileDefault)
                Text("Page spécifique").tag(DestinationMode.specificPage)
            }
            .pickerStyle(.radioGroup)

            if case .page(let id) = selected.destination {
                TextField(
                    "URL ou identifiant de la page",
                    text: Binding(
                        get: { id },
                        set: { value in
                            var template = selected
                            template.destination = .page(id: normalizedPageID(value))
                            settings.upsert(template)
                        }
                    )
                )
                .textFieldStyle(.roundedBorder)
            }

            if settings.publicationServiceKind(for: selected) == nil {
                Label(
                    "Ajoute un service au profil ou choisis un service par défaut pour permettre la publication automatique.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            } else if selected.destination == .profileDefault {
                Text("La destination par défaut se configure dans l'onglet Services.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Label(
                session.destinationSummary(for: selected),
                systemImage: "tray.and.arrow.down"
            )
            .font(.caption)
            .foregroundStyle(.secondary)

        }
    }

    private var inheritedServiceLabel: String {
        let inherited = settings.activeProfile.effectivePublicationServiceKind?.displayName
            ?? L("aucun service")
        return L("Hériter du profil (%@)", inherited)
    }

    private enum DestinationMode: Hashable { case profileDefault, specificPage }

    private var destinationModeBinding: Binding<DestinationMode> {
        Binding(
            get: {
                switch selected.destination {
                case .profileDefault: .profileDefault
                case .page: .specificPage
                }
            },
            set: { mode in
                var template = selected
                template.destination = switch mode {
                case .profileDefault: .profileDefault
                case .specificPage: .page(id: selected.destination.pageID ?? "")
                }
                settings.upsert(template)
            }
        )
    }

    private func normalizedPageID(_ input: String) -> String {
        switch settings.publicationServiceKind(for: selected) {
        case .notion:
            return NotionConfiguration.extractPageID(from: input) ?? input
        case .atlassian:
            return SprintPage.extractPageID(from: input) ?? input
        case nil:
            return input
        }
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
                    Text(section.displayName(in: settings.defaultOutputLanguage)).font(.callout)
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
                        Button(section.displayName(in: settings.defaultOutputLanguage)) { toggle(section) }
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

    // MARK: - Editing

    private func normalizeSelection() {
        guard !activeTemplates.contains(where: { $0.id == selectedID }) else { return }
        selectedID = activeTemplates.first?.id ?? MeetingTemplate.personal.id
    }

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

/// Compact list of available tokens, spread over several lines.
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
