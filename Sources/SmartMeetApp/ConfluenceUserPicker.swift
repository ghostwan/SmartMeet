import Atlassian
import SwiftUI

/// Quick Confluence user search, used in place of typing an e-mail by hand
/// for the one-to-one counterpart: a magnifying-glass button opens a small
/// popover with a search field and the matching accounts, debounced so every
/// keystroke doesn't fire a request.
struct ConfluenceUserSearchButton: View {
    let search: (String) async -> [ConfluenceUserMatch]
    let onSelect: (ConfluenceUserMatch) -> Void

    @State private var isPresented = false
    @State private var query = ""
    @State private var results: [ConfluenceUserMatch] = []
    @State private var isSearching = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            Image(systemName: "magnifyingglass")
        }
        .buttonStyle(.borderless)
        .help("Rechercher un compte Confluence par nom, plutôt que taper son e-mail")
        .popover(isPresented: $isPresented) {
            VStack(alignment: .leading, spacing: 8) {
                TextField("Nom sur Confluence…", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)

                if isSearching {
                    ProgressView().controlSize(.small)
                } else if query.trimmingCharacters(in: .whitespaces).count >= 2 && results.isEmpty {
                    Text("Aucun résultat").font(.caption).foregroundStyle(.secondary)
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
