import Summarization
import SwiftUI

/// Éditeur des types de réunion. Les modèles fournis sont en lecture seule et se
/// dupliquent ; les modèles personnalisés se modifient librement.
struct TemplatesSettingsView: View {
    @Bindable var settings: AppSettings
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
