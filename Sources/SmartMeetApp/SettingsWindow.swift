import Diarization
import Summarization
import SwiftUI
import Transcription

struct SettingsWindow: View {
    @Bindable var settings: AppSettings
    /// Needed to resolve the sprint page, which requires a network call.
    @Bindable var session: RecordingSession
    @State private var vocabularyText: String = ""
    @State private var knownPeopleText: String = ""
    @State private var availableLocales: [(id: String, label: String)] = []

    var body: some View {
        TabView {
            ProfilesSettingsView(settings: settings, session: session)
                .tabItem { Label("Profils", systemImage: "person.2.crop.square.stack") }
            transcriptionTab.tabItem { Label("Transcription", systemImage: "waveform") }
            summaryTab.tabItem { Label("Compte rendu", systemImage: "sparkles") }
            TemplatesSettingsView(settings: settings, session: session)
                .tabItem { Label("Types de réunion", systemImage: "square.stack") }
            ServicesSettingsView(settings: settings, session: session)
                .tabItem { Label("Services", systemImage: "tray.and.arrow.up") }
        }
        .frame(width: 760, height: 480)
        .onAppear {
            vocabularyText = settings.vocabulary.joined(separator: ", ")
            knownPeopleText = settings.knownPeople.joined(separator: ", ")
        }
        .onChange(of: settings.activeProfileID) {
            vocabularyText = settings.vocabulary.joined(separator: ", ")
        }
        .task { await loadLocales() }
    }

    /// Builds the language list from what the `Speech` framework can
    /// actually transcribe on this machine, rather than a fixed list.
    private func loadLocales() async {
        availableLocales = await SupportedTranscriptionLocales.all()
        // Old identifier format (e.g. "fr-FR") not present as-is in the list
        // returned by the framework (e.g. "fr_FR"): silently migrate to the
        // exact identifier so the picker shows the correct selection.
        guard !availableLocales.contains(where: { $0.id == settings.localeIdentifier }) else { return }
        if let resolved = await SupportedTranscriptionLocales.resolvedIdentifier(for: settings.locale) {
            settings.localeIdentifier = resolved
        }
    }

    private var transcriptionTab: some View {
        Form {
            Section("Identité") {
                TextField("Votre nom", text: $settings.userName)
                Text("Le transcript ne vous désigne que par « Moi ». Ce nom permet de vous attribuer correctement décisions et action items.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Picker("Langue", selection: $settings.localeIdentifier) {
                ForEach(availableLocales, id: \.id) { locale in
                    Text(locale.label).tag(locale.id)
                }
            }
            if availableLocales.isEmpty {
                Text("Chargement des langues disponibles…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Vocabulaire métier") {
                TextEditor(text: $vocabularyText)
                    .frame(height: 80)
                    .font(.callout)
                    .onChange(of: vocabularyText) {
                        settings.vocabulary = vocabularyText
                            .split(whereSeparator: { $0 == "," || $0 == "\n" })
                            .map { $0.trimmingCharacters(in: .whitespaces) }
                            .filter { !$0.isEmpty }
                    }
                Text("Noms propres et termes métier, séparés par des virgules. Ils sont injectés dans le moteur de reconnaissance et dans le prompt.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Personnes") {
                TextEditor(text: $knownPeopleText)
                    .frame(height: 80)
                    .font(.callout)
                    .onChange(of: knownPeopleText) {
                        settings.knownPeople = knownPeopleText
                            .split(whereSeparator: { $0 == "," || $0 == "\n" })
                            .map { $0.trimmingCharacters(in: .whitespaces) }
                            .filter { !$0.isEmpty }
                    }
                Text("Prénoms (et noms) des personnes avec qui tu interagis régulièrement, bien orthographiés, séparés par des virgules. Comme le vocabulaire métier, ils sont injectés dans le moteur de reconnaissance et dans le prompt — utile quand la transcription ou le compte rendu déforme un prénom.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Toggle("Utiliser le calendrier pour le titre et les participants", isOn: $settings.useCalendar)

            Section("Détection des réunions") {
                Toggle("Proposer d'enregistrer quand une réunion est détectée", isOn: $settings.detectMeetings)
                Toggle("Démarrer sans demander", isOn: $settings.autoStartOnDetection)
                    .disabled(!settings.detectMeetings)
                Text("La détection combine le calendrier et l'application de visioconférence qui capte le micro. Le démarrage automatique reste désactivé par défaut : enregistrer des personnes sans les prévenir n'est pas un comportement à activer à leur place.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle(
                    "Proposer de générer le compte rendu quand la réunion semble terminée",
                    isOn: $settings.detectMeetingEnd
                )
                Text("Basé sur l'application de visioconférence qui n'utilise plus le micro depuis un moment — une simple proposition, jamais un arrêt automatique : une coupure passagère (réseau, micro coupé volontairement…) ne doit pas arrêter l'enregistrement à ta place.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Diarisation (expérimental)") {
                Toggle(
                    "Distinguer les voix sur le micro (réunion en présentiel)",
                    isOn: $settings.diarizeMicrophoneTrack
                )
                Text(L(
                    "Pour une réunion où plusieurs personnes parlent dans le même micro. Basé sur la hauteur et le timbre de la voix, pas sur un modèle de reconnaissance vocale : fonctionne surtout quand les voix sont nettement différentes, et jusqu'à %d locuteurs. Une seule voix n'est pas scindée à tort si la séparation n'est pas nette.",
                    MicrophoneDiarizer.defaultMaxSpeakers
                ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var summaryTab: some View {
        Form {
            Picker("Provider", selection: $settings.providerKind) {
                ForEach(SummaryProviderKind.allCases) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }

            switch settings.providerKind {
            case .opencode:
                TextField("Modèle", text: $settings.opencodeModel)
                Text("Passe par le binaire `opencode`, client Copilot authentifié. Aucune API publique ne permet d'utiliser un abonnement Copilot directement depuis une application tierce.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .copilotACP:
                TextField("Modèle", text: $settings.copilotACPModel)
                Text("Passe par le binaire `copilot --acp` (GitHub Copilot CLI), en protocole ACP plutôt qu'en sortie texte parsée : compte de tokens exact, sans dépendre d'`opencode`.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .appleOnDevice:
                Text("Modèle embarqué d'Apple Intelligence : entièrement local, aucune donnée ne quitte la machine, aucune installation. Fenêtre de contexte réduite (~4096 tokens) : convient aux réunions courtes, moins bien aux réunions longues même découpées.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .ollama:
                TextField("Modèle", text: $settings.ollamaModel)
                Text("Entièrement local : aucune donnée ne quitte la machine. Qualité inférieure sur la résolution des dates relatives.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .claudeCode:
                TextField("Modèle", text: $settings.claudeCodeModel)
                Text("Passe par le binaire `claude` (Claude Code CLI) en mode non interactif (`claude -p --output-format json`), abonnement Claude authentifié via le CLI.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Picker("Langue par défaut du compte rendu", selection: $settings.defaultOutputLanguage) {
                ForEach(SummaryLanguage.allCases) { language in
                    Text("\(language.flag) \(language.displayName)").tag(language)
                }
            }
            Text("Modifiable avant chaque enregistrement. Indépendante de la langue parlée en réunion : une équipe francophone peut livrer un compte rendu en anglais.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Section("À l'arrêt de l'enregistrement") {
                Toggle("Générer le compte rendu", isOn: $settings.autoSummarize)
                Toggle("Publier sur Confluence sans relecture", isOn: $settings.autoPublish)
                    .disabled(!settings.autoSummarize || !settings.canPublish)
                Toggle("Créer aussi les tickets Jira", isOn: $settings.autoCreateJiraIssues)
                    .disabled(!settings.autoPublish || !settings.atlassian.isJiraReady)
                Text("Une notification prévient dès que le compte rendu est prêt, avec le lien vers la page si la publication est automatique. La publication sans relecture reste désactivée par défaut : un compte rendu écrit par un modèle mérite un coup d'œil avant d'atterrir sur un espace d'équipe.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

}
