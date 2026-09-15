import Summarization
import SwiftUI

/// Common SF Symbols offered for a profile's icon — a short curated list
/// rather than a full symbol picker, since a profile only needs to be
/// visually distinguishable at a glance in the switcher.
private let profileSymbolChoices = [
    "briefcase", "house", "person.crop.circle", "graduationcap",
    "hammer", "heart", "star", "figure.2",
]

/// Profiles scope which meeting types are visible, which business vocabulary
/// applies, which services (and credentials) are configured, which behavior
/// preferences (auto-publish, meeting detection, diarization…) are active,
/// and which service minutes publish to by default — so a "Work" profile and
/// a "Personal" profile can behave completely differently without juggling
/// settings by hand every time.
struct ProfilesSettingsView: View {
    @Bindable var settings: AppSettings
    @Bindable var session: RecordingSession
    @State private var newProfileName = ""

    var body: some View {
        HSplitView {
            list
            detail
        }
    }

    private var list: some View {
        VStack(spacing: 0) {
            List(selection: Binding(
                get: { settings.activeProfileID },
                set: { if let id = $0 { session.selectProfile(id) } }
            )) {
                ForEach(settings.profiles) { profile in
                    Label(profile.name, systemImage: profile.symbol).tag(profile.id)
                }
            }
            .listStyle(.sidebar)
            .disabled(session.isRecording)

            HStack(spacing: 4) {
                TextField("Nouveau profil", text: $newProfileName)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    .onSubmit(addProfile)
                Button { addProfile() } label: { Image(systemName: "plus") }
                    .disabled(newProfileName.trimmingCharacters(in: .whitespaces).isEmpty)
                Button {
                    settings.removeProfile(settings.activeProfile)
                    session.selectProfile(settings.activeProfileID)
                } label: {
                    Image(systemName: "minus")
                }
                .disabled(settings.profiles.count <= 1 || session.isRecording)
                .help("Supprimer le profil actif")
            }
            .buttonStyle(.borderless)
            .padding(6)
        }
        .frame(minWidth: 170, maxWidth: 220)
    }

    private func addProfile() {
        let name = newProfileName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let profile = settings.addProfile(name: name, activate: false)
        session.selectProfile(profile.id)
        newProfileName = ""
    }

    private var detail: some View {
        Form {
            Section("Identité") {
                TextField("Nom", text: Binding(
                    get: { settings.activeProfile.name },
                    set: { var profile = settings.activeProfile; profile.name = $0; settings.activeProfile = profile }
                ))

                Picker("Icône", selection: Binding(
                    get: { settings.activeProfile.symbol },
                    set: { var profile = settings.activeProfile; profile.symbol = $0; settings.activeProfile = profile }
                )) {
                    ForEach(profileSymbolChoices, id: \.self) { symbol in
                        Label(symbol, systemImage: symbol).tag(symbol)
                    }
                }
            }

            Section("Publication") {
                Picker("Service par défaut", selection: Binding(
                    get: { settings.activeProfile.defaultServiceKind },
                    set: {
                        var profile = settings.activeProfile
                        profile.defaultServiceKind = $0
                        settings.activeProfile = profile
                    }
                )) {
                    Text("Aucun").tag(ServiceKind?.none)
                    ForEach(settings.enabledServices.sorted { $0.displayName < $1.displayName }) { kind in
                        Text(kind.displayName).tag(ServiceKind?.some(kind))
                    }
                }
                Text("Service utilisé pour la publication automatique et mis en avant lors d'une publication manuelle. Avec un seul service ajouté, celui-ci est choisi automatiquement.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Text("Le vocabulaire métier, les types de réunion activés, les services de publication (avec leurs identifiants) et les préférences de comportement (transcription, détection, publication automatique…) s'appliquent tous au profil actif ci-dessus, pas globalement.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(minWidth: 330)
    }
}
