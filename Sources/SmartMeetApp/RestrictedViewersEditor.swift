import Atlassian
import Summarization
import SwiftUI

/// Multi-person "restrict this page to…" editor, usable for any meeting type
/// (not just a one-to-one, which already restricts to its fixed
/// counterpart). Reuses the same debounced Confluence search as the
/// one-to-one picker to add people, with a plain remove button per row.
struct RestrictedViewersEditor: View {
    let viewers: [RestrictedViewer]
    let search: (String) async -> [ConfluenceUserMatch]
    let onAdd: (ConfluenceUserMatch) -> Void
    let onRemove: (RestrictedViewer) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("🔒").font(.caption)
                Text("Visible uniquement de :").font(.caption).foregroundStyle(.secondary)
                ConfluenceUserSearchButton(search: search, onSelect: onAdd)
                Spacer()
            }

            if viewers.isEmpty {
                Text("Tout l'espace Confluence — aucune restriction ajoutée")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(viewers) { viewer in
                    HStack(spacing: 6) {
                        Text(viewer.displayName).font(.caption)
                        if let email = viewer.email {
                            Text(email).font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            onRemove(viewer)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
        }
        .help("En plus de toi, ces personnes pourront voir la page publiée — les autres membres de l'espace Confluence n'y auront pas accès.")
    }
}
