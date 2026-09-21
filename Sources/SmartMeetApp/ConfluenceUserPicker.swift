import Atlassian
import SwiftUI

/// Quick Confluence user search, used in place of typing an e-mail by hand
/// for the one-to-one counterpart (or any other "restrict this page to…"
/// picker): a magnifying-glass button opens a small popover with the
/// matching accounts — accepting either a display name or a full e-mail
/// address, see `ConfluenceClient.searchUsers(matching:)` — debounced so
/// every keystroke doesn't fire a request. Either searches its own input
/// field, or (via `externalQuery`) reuses a field the caller already has,
/// so the person isn't asked to type the same name twice.
struct ConfluenceUserSearchButton: View {
    let search: (String) async -> [ConfluenceUserMatch]
    let onSelect: (ConfluenceUserMatch) -> Void
    /// When set, the popover searches straight off this field's current text
    /// (a name or an e-mail already typed next to the magnifying glass)
    /// instead of showing its own input — avoids asking the same thing
    /// twice for the one-to-one restriction field, which already accepts
    /// both.
    var externalQuery: Binding<String>? = nil

    @State private var isPresented = false
    @State private var internalQuery = ""
    @State private var results: [ConfluenceUserMatch] = []
    @State private var isSearching = false

    private var query: String { externalQuery?.wrappedValue ?? internalQuery }

    var body: some View {
        Button {
            isPresented = true
        } label: {
            Image(systemName: "magnifyingglass")
        }
        .buttonStyle(.borderless)
        .help("Rechercher un compte Confluence par nom ou par e-mail")
        .popover(isPresented: $isPresented) {
            VStack(alignment: .leading, spacing: 8) {
                if externalQuery == nil {
                    TextField("Nom ou e-mail sur Confluence…", text: $internalQuery)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                }

                if isSearching {
                    ProgressView().controlSize(.small)
                } else if query.trimmingCharacters(in: .whitespaces).count >= 2 && results.isEmpty {
                    Text("Aucun résultat").font(.caption).foregroundStyle(.secondary)
                } else if externalQuery != nil
                    && query.trimmingCharacters(in: .whitespaces).count < 2
                {
                    Text("Tape au moins 2 caractères dans le champ à gauche")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !results.isEmpty {
                    List(results) { match in
                        Button {
                            onSelect(match)
                            isPresented = false
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(match.displayName)
                                if let email = match.email {
                                    Text(email).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    .frame(width: 220, height: min(CGFloat(results.count) * 44, 176))
                }
            }
            .padding(10)
            // Debounced: waits for a pause in typing before hitting Confluence,
            // and cancels automatically if `query` changes again mid-flight.
            .task(id: query) {
                let trimmed = query.trimmingCharacters(in: .whitespaces)
                guard trimmed.count >= 2 else {
                    results = []
                    return
                }
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                isSearching = true
                results = await search(trimmed)
                isSearching = false
            }
        }
    }
}
