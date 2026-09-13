import Atlassian
import Foundation
import Notion
import Observation
import Summarization

/// Réglages persistés dans `UserDefaults`, hors secrets qui vont au trousseau.
@MainActor
@Observable
public final class AppSettings {
    private enum Key {
        static let provider = "summaryProvider"
        static let opencodeModel = "opencodeModel"
        static let ollamaModel = "ollamaModel"
        static let locale = "transcriptionLocale"
        static let vocabulary = "vocabulary"
        static let knownPeople = "knownPeople"
        static let atlassian = "atlassianConfiguration"
        static let autoSummarize = "autoSummarize"
        static let useCalendar = "useCalendar"
        static let customTemplates = "customTemplates"
        static let defaultTemplate = "defaultTemplateID"
        static let userName = "userName"
        static let outputLanguage = "outputLanguage"
        static let detectMeetings = "detectMeetings"
        static let autoStartOnDetection = "autoStartOnDetection"
        static let autoPublish = "autoPublish"
        static let autoCreateJiraIssues = "autoCreateJiraIssues"
        static let diarizeMicrophoneTrack = "diarizeMicrophoneTrack"
        static let notion = "notionConfiguration"
        static let disabledTemplateIDs = "disabledTemplateIDs"
        static let recentTranscriptionLocales = "recentTranscriptionLocales"
    }

    private let defaults = UserDefaults.standard
    private let keychain = KeychainStore()
    private let notionKeychain = KeychainStore(service: "com.smartmeet.notion")
    static let tokenAccount = "atlassian-api-token"
    static let notionTokenAccount = "notion-integration-token"

    public var providerKind: SummaryProviderKind {
        didSet { defaults.set(providerKind.rawValue, forKey: Key.provider) }
    }
    public var opencodeModel: String {
        didSet { defaults.set(opencodeModel, forKey: Key.opencodeModel) }
    }
    public var ollamaModel: String {
        didSet { defaults.set(ollamaModel, forKey: Key.ollamaModel) }
    }
    public var localeIdentifier: String {
        didSet { defaults.set(localeIdentifier, forKey: Key.locale) }
    }
    /// Langues parlées récemment utilisées, la plus récente en tête — permet de les
    /// remonter en haut du sélecteur plutôt que de les noyer dans la liste complète
    /// des locales supportées par le framework.
    public var recentTranscriptionLocales: [String] {
        didSet { defaults.set(recentTranscriptionLocales, forKey: Key.recentTranscriptionLocales) }
    }
    public var vocabulary: [String] {
        didSet { defaults.set(vocabulary, forKey: Key.vocabulary) }
    }
    /// Prénoms (et noms) des personnes avec qui l'utilisateur interagit régulièrement,
    /// bien orthographiés. Séparé du vocabulaire métier pour rester lisible, mais
    /// utilisé exactement pareil : injecté dans la reconnaissance vocale et dans le
    /// prompt du compte rendu, pour qu'un prénom mal reconnu ou mal orthographié par
    /// le modèle se corrige de lui-même.
    public var knownPeople: [String] {
        didSet { defaults.set(knownPeople, forKey: Key.knownPeople) }
    }
    /// Nom de l'utilisateur : le transcript ne le connaît que sous le libellé « Moi ».
    public var userName: String {
        didSet { defaults.set(userName, forKey: Key.userName) }
    }
    /// Langue proposée par défaut pour le compte rendu.
    public var defaultOutputLanguage: SummaryLanguage {
        didSet { defaults.set(defaultOutputLanguage.rawValue, forKey: Key.outputLanguage) }
    }
    /// Propose d'enregistrer quand une réunion est détectée.
    public var detectMeetings: Bool {
        didSet { defaults.set(detectMeetings, forKey: Key.detectMeetings) }
    }
    /// Démarre sans demander. Volontairement désactivé par défaut : enregistrer des
    /// personnes à leur insu n'est pas un comportement qu'on active pour elles.
    public var autoStartOnDetection: Bool {
        didSet { defaults.set(autoStartOnDetection, forKey: Key.autoStartOnDetection) }
    }
    public var autoSummarize: Bool {
        didSet { defaults.set(autoSummarize, forKey: Key.autoSummarize) }
    }
    /// Publie sur Confluence sans relecture. Désactivé par défaut : le compte rendu
    /// est généré par un modèle, il mérite un coup d'œil avant d'atterrir sur un
    /// espace d'équipe.
    public var autoPublish: Bool {
        didSet { defaults.set(autoPublish, forKey: Key.autoPublish) }
    }
    /// Crée aussi les tickets Jira lors d'une publication automatique.
    public var autoCreateJiraIssues: Bool {
        didSet { defaults.set(autoCreateJiraIssues, forKey: Key.autoCreateJiraIssues) }
    }
    public var useCalendar: Bool {
        didSet { defaults.set(useCalendar, forKey: Key.useCalendar) }
    }
    /// Diarisation expérimentale de la piste micro : distingue jusqu'à deux
    /// locuteurs partageant le même micro (réunion en présentiel), à partir de
    /// traits acoustiques classiques — pas un modèle de reconnaissance vocale.
    /// Désactivé par défaut : la séparation peut se tromper, notamment si les deux
    /// voix se ressemblent.
    public var diarizeMicrophoneTrack: Bool {
        didSet { defaults.set(diarizeMicrophoneTrack, forKey: Key.diarizeMicrophoneTrack) }
    }
    /// Types de réunion créés par l'utilisateur, en plus des modèles fournis.
    public var customTemplates: [MeetingTemplate] {
        didSet {
            guard let data = try? JSONEncoder().encode(customTemplates) else { return }
            defaults.set(data, forKey: Key.customTemplates)
        }
    }
    /// Type proposé par défaut au démarrage d'un enregistrement.
    public var defaultTemplateID: String {
        didSet { defaults.set(defaultTemplateID, forKey: Key.defaultTemplate) }
    }

    public var atlassian: AtlassianConfiguration {
        didSet {
            guard let data = try? JSONEncoder().encode(atlassian) else { return }
            defaults.set(data, forKey: Key.atlassian)
        }
    }

    /// Jeton d'API : lu et écrit dans le trousseau, jamais dans les préférences.
    public var atlassianToken: String {
        didSet { keychain.write(atlassianToken, account: Self.tokenAccount) }
    }

    public var notion: NotionConfiguration {
        didSet {
            guard let data = try? JSONEncoder().encode(notion) else { return }
            defaults.set(data, forKey: Key.notion)
        }
    }

    /// Jeton d'intégration Notion : trousseau, jamais les préférences.
    public var notionToken: String {
        didSet { notionKeychain.write(notionToken, account: Self.notionTokenAccount) }
    }

    /// Types de réunion (fournis ou personnalisés) volontairement masqués de la
    /// liste de sélection. Pas supprimés — juste absents de `allTemplates` — pour
    /// rester réversible et ne rien casser dans l'historique des réunions déjà
    /// enregistrées avec ce type.
    public var disabledTemplateIDs: Set<String> {
        didSet {
            defaults.set(Array(disabledTemplateIDs), forKey: Key.disabledTemplateIDs)
        }
    }

    public init() {
        providerKind = SummaryProviderKind(
            rawValue: defaults.string(forKey: Key.provider) ?? ""
        ) ?? .opencode
        opencodeModel = defaults.string(forKey: Key.opencodeModel) ?? "github-copilot/claude-sonnet-5"
        ollamaModel = defaults.string(forKey: Key.ollamaModel) ?? "gemma4"
        localeIdentifier = defaults.string(forKey: Key.locale) ?? "fr-FR"
        recentTranscriptionLocales = defaults.stringArray(forKey: Key.recentTranscriptionLocales) ?? []
        vocabulary = defaults.stringArray(forKey: Key.vocabulary) ?? [
            "Crowdin", "ACME", "Confluence", "Jira", "ACME",
            "SmartMeet", "ACME", "ACME",
        ]
        knownPeople = defaults.stringArray(forKey: Key.knownPeople) ?? []
        userName = defaults.string(forKey: Key.userName) ?? NSFullUserName()
        defaultOutputLanguage = SummaryLanguage(
            rawValue: defaults.string(forKey: Key.outputLanguage) ?? ""
        ) ?? .french
        detectMeetings = defaults.object(forKey: Key.detectMeetings) as? Bool ?? true
        autoStartOnDetection = defaults.object(forKey: Key.autoStartOnDetection) as? Bool ?? false
        autoSummarize = defaults.object(forKey: Key.autoSummarize) as? Bool ?? true
        autoPublish = defaults.object(forKey: Key.autoPublish) as? Bool ?? false
        autoCreateJiraIssues = defaults.object(forKey: Key.autoCreateJiraIssues) as? Bool ?? false
        useCalendar = defaults.object(forKey: Key.useCalendar) as? Bool ?? true
        diarizeMicrophoneTrack = defaults.object(forKey: Key.diarizeMicrophoneTrack) as? Bool ?? false

        if let data = defaults.data(forKey: Key.customTemplates),
           let decoded = try? JSONDecoder().decode([MeetingTemplate].self, from: data) {
            customTemplates = decoded
        } else {
            customTemplates = []
        }
        defaultTemplateID = defaults.string(forKey: Key.defaultTemplate)
            ?? MeetingTemplate.generic.id

        if let data = defaults.data(forKey: Key.atlassian),
           let decoded = try? JSONDecoder().decode(AtlassianConfiguration.self, from: data) {
            atlassian = decoded
        } else {
            atlassian = AtlassianConfiguration()
        }

        if let data = defaults.data(forKey: Key.notion),
           let decoded = try? JSONDecoder().decode(NotionConfiguration.self, from: data) {
            notion = decoded
        } else {
            notion = NotionConfiguration()
        }

        disabledTemplateIDs = Set(defaults.stringArray(forKey: Key.disabledTemplateIDs) ?? [])

        let keychain = KeychainStore()
        keychain.seedFromEnvironmentIfNeeded(
            account: Self.tokenAccount, variable: "ATLASSIAN_API_TOKEN"
        )
        atlassianToken = keychain.read(account: Self.tokenAccount) ?? ""

        let notionKeychain = KeychainStore(service: "com.smartmeet.notion")
        notionKeychain.seedFromEnvironmentIfNeeded(
            account: Self.notionTokenAccount, variable: "NOTION_API_TOKEN"
        )
        notionToken = notionKeychain.read(account: Self.notionTokenAccount) ?? ""
    }

    public var locale: Locale { Locale(identifier: localeIdentifier) }

    /// Vocabulaire métier et prénoms combinés : c'est ce qui doit être injecté dans
    /// la reconnaissance vocale et dans le prompt, pas seulement l'un ou l'autre.
    public var contextualVocabulary: [String] { vocabulary + knownPeople }

    public func makeProvider() -> any SummaryProvider {
        switch providerKind {
        case .opencode: OpencodeProvider(model: opencodeModel)
        case .ollama: OllamaProvider(model: ollamaModel)
        }
    }

    public var canPublish: Bool {
        atlassian.isConfluenceReady && !atlassianToken.isEmpty
    }

    public var canPublishToNotion: Bool {
        notion.isConfigured && !notionToken.isEmpty
    }

    /// Page de sprint courante, parent commun des réunions du sprint.
    public var sprintPage: SprintPage? {
        get { atlassian.sprintPage }
        set { atlassian.sprintPage = newValue }
    }

    /// Vrai si au moins un type de réunion s'appuie sur la page de sprint.
    public var usesSprintPage: Bool {
        allTemplates.contains { $0.parent.isSprintPage }
    }

    /// Modèles fournis puis modèles personnalisés, dans l'ordre d'affichage. Un type
    /// fourni édité est représenté par sa version en vigueur (l'éventuelle
    /// surcharge dans `customTemplates`), pas la version d'origine codée en dur.
    /// Les types masqués (`disabledTemplateIDs`) n'apparaissent pas ici : c'est la
    /// liste proposée à la sélection, pas l'inventaire complet.
    public var allTemplates: [MeetingTemplate] {
        let effectiveBuiltIns = MeetingTemplate.builtIns.map { template(id: $0.id) }
        let trueCustoms = customTemplates.filter { custom in
            !MeetingTemplate.builtIns.contains { $0.id == custom.id }
        }
        return (effectiveBuiltIns + trueCustoms).filter { !disabledTemplateIDs.contains($0.id) }
    }

    /// Tous les types, y compris masqués — pour l'écran de réglages qui doit
    /// permettre de les réafficher.
    public var allTemplatesIncludingDisabled: [MeetingTemplate] {
        let effectiveBuiltIns = MeetingTemplate.builtIns.map { template(id: $0.id) }
        let trueCustoms = customTemplates.filter { custom in
            !MeetingTemplate.builtIns.contains { $0.id == custom.id }
        }
        return effectiveBuiltIns + trueCustoms
    }

    public func isTemplateEnabled(_ template: MeetingTemplate) -> Bool {
        !disabledTemplateIDs.contains(template.id)
    }

    /// Masque ou réaffiche un type dans la liste de sélection. Si le type masqué
    /// était le type par défaut, on retombe sur le générique pour ne pas proposer un
    /// type introuvable au prochain démarrage.
    public func setTemplateEnabled(_ enabled: Bool, for template: MeetingTemplate) {
        if enabled {
            disabledTemplateIDs.remove(template.id)
        } else {
            disabledTemplateIDs.insert(template.id)
            if defaultTemplateID == template.id { defaultTemplateID = MeetingTemplate.generic.id }
        }
    }

    public func template(id: String?) -> MeetingTemplate {
        MeetingTemplate.resolve(id: id, in: customTemplates)
    }

    /// Fait remonter une langue parlée en tête des « récentes », pour qu'elle
    /// apparaisse en haut du sélecteur la prochaine fois. Appelé quand la langue est
    /// réellement utilisée (début d'enregistrement), pas à chaque changement de
    /// sélection dans le picker.
    public func recordTranscriptionLocaleUsed(_ identifier: String) {
        var recents = recentTranscriptionLocales.filter { $0 != identifier }
        recents.insert(identifier, at: 0)
        recentTranscriptionLocales = Array(recents.prefix(5))
    }

    /// Duplique un modèle pour créer une variante indépendante, avec un nouvel
    /// identifiant.
    public func duplicate(_ template: MeetingTemplate) -> MeetingTemplate {
        var copy = template
        copy.id = UUID().uuidString
        copy.name = "\(template.name) (copie)"
        copy.isBuiltIn = false
        customTemplates.append(copy)
        return copy
    }

    /// Enregistre un modèle, qu'il soit personnalisé ou une édition d'un type fourni :
    /// dans les deux cas c'est une surcharge stockée par identifiant.
    public func upsert(_ template: MeetingTemplate) {
        if let index = customTemplates.firstIndex(where: { $0.id == template.id }) {
            customTemplates[index] = template
        } else {
            customTemplates.append(template)
        }
    }

    /// Pour un type personnalisé, suppression définitive. Pour un type fourni édité,
    /// retire la surcharge et fait donc revenir à la version d'origine.
    public func remove(_ template: MeetingTemplate) {
        customTemplates.removeAll { $0.id == template.id }
        if defaultTemplateID == template.id { defaultTemplateID = MeetingTemplate.generic.id }
    }
}
