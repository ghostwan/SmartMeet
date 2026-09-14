import Foundation

/// Compte rendu structuré produit par le LLM. C'est le contrat partagé par tous les
/// providers : aucun ne dispose de sortie structurée native, le schéma est donc
/// imposé par le prompt puis validé à la réception.
public struct MeetingSummary: Codable, Sendable, Equatable {
    public var title: String
    public var tldr: String
    public var attendees: [String]
    public var topics: [Topic]
    public var decisions: [String]
    public var actionItems: [ActionItem]
    public var openQuestions: [String]
    public var nextSteps: [String]

    // Sections propres à certains types de réunion. Vides quand le modèle n'a pas
    // été sollicité dessus.

    /// Ce qui bloque l'équipe — un daily ouvre là-dessus.
    public var blockers: [Blocker]
    /// Un point par personne, pour un daily.
    public var participantReports: [ParticipantReport]
    /// Ressenti nominatif, pour une rétrospective.
    public var moods: [ParticipantMood]
    /// Météo du sprint : icônes, justification et propos de chaque membre.
    public var sprintWeather: [SprintWeatherEntry]
    /// Format 4L d'une rétrospective.
    public var fourL: FourL?

    /// Type de réunion utilisé pour la génération, qui pilote aussi le rendu.
    public var templateID: String?

    public init(
        title: String = "",
        tldr: String = "",
        attendees: [String] = [],
        topics: [Topic] = [],
        decisions: [String] = [],
        actionItems: [ActionItem] = [],
        openQuestions: [String] = [],
        nextSteps: [String] = [],
        blockers: [Blocker] = [],
        participantReports: [ParticipantReport] = [],
        moods: [ParticipantMood] = [],
        sprintWeather: [SprintWeatherEntry] = [],
        fourL: FourL? = nil,
        templateID: String? = nil
    ) {
        self.title = title
        self.tldr = tldr
        self.attendees = attendees
        self.topics = topics
        self.decisions = decisions
        self.actionItems = actionItems
        self.openQuestions = openQuestions
        self.nextSteps = nextSteps
        self.blockers = blockers
        self.participantReports = participantReports
        self.moods = moods
        self.sprintWeather = sprintWeather
        self.fourL = fourL
        self.templateID = templateID
    }

    private enum CodingKeys: String, CodingKey {
        case title, tldr, attendees, topics, decisions, actionItems, openQuestions, nextSteps
        case blockers, participantReports, moods, sprintWeather, fourL, templateID
    }

    /// Décodage tolérant : les modèles omettent régulièrement les sections vides.
    /// Exiger toutes les clés faisait échouer la génération entière pour un `attendees`
    /// manquant, alors que le compte rendu était par ailleurs exploitable.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        tldr = try container.decodeIfPresent(String.self, forKey: .tldr) ?? ""
        attendees = try container.decodeIfPresent([String].self, forKey: .attendees) ?? []
        topics = try container.decodeIfPresent([Topic].self, forKey: .topics) ?? []
        decisions = try container.decodeIfPresent([String].self, forKey: .decisions) ?? []
        actionItems = try container.decodeIfPresent([ActionItem].self, forKey: .actionItems) ?? []
        openQuestions = try container.decodeIfPresent([String].self, forKey: .openQuestions) ?? []
        nextSteps = try container.decodeIfPresent([String].self, forKey: .nextSteps) ?? []
        blockers = try container.decodeIfPresent([Blocker].self, forKey: .blockers) ?? []
        participantReports = try container.decodeIfPresent(
            [ParticipantReport].self, forKey: .participantReports
        ) ?? []
        moods = try container.decodeIfPresent([ParticipantMood].self, forKey: .moods) ?? []
        sprintWeather = try container.decodeIfPresent(
            [SprintWeatherEntry].self, forKey: .sprintWeather
        ) ?? []
        fourL = try container.decodeIfPresent(FourL.self, forKey: .fourL)
        templateID = try container.decodeIfPresent(String.self, forKey: .templateID)
    }

    /// Un obstacle signalé pendant la réunion.
    public struct Blocker: Codable, Sendable, Equatable, Identifiable {
        public enum Severity: String, Codable, Sendable, CaseIterable {
            case blocking = "bloquant"
            case risk = "risque"

            public var symbol: String {
                switch self {
                case .blocking: "exclamationmark.octagon.fill"
                case .risk: "exclamationmark.triangle.fill"
                }
            }
        }

        public var id: UUID
        public var person: String?
        public var description: String
        public var severity: Severity

        public init(
            id: UUID = UUID(),
            person: String? = nil,
            description: String,
            severity: Severity = .blocking
        ) {
            self.id = id
            self.person = person
            self.description = description
            self.severity = severity
        }

        private enum CodingKeys: String, CodingKey { case person, description, severity }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = UUID()
            person = try container.decodeIfPresent(String.self, forKey: .person)
            description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
            // Le modèle s'écarte parfois du vocabulaire imposé : on retombe sur
            // « bloquant », le cas le plus coûteux à manquer.
            let raw = try container.decodeIfPresent(String.self, forKey: .severity)?.lowercased()
            severity = raw.flatMap(Severity.init(rawValue:)) ?? .blocking
        }
    }

    /// Le point d'une personne lors d'un daily.
    public struct ParticipantReport: Codable, Sendable, Equatable, Identifiable {
        public var id: UUID
        public var person: String
        public var done: [String]
        public var next: [String]
        public var blockers: [String]

        public init(
            id: UUID = UUID(),
            person: String,
            done: [String] = [],
            next: [String] = [],
            blockers: [String] = []
        ) {
            self.id = id
            self.person = person
            self.done = done
            self.next = next
            self.blockers = blockers
        }

        private enum CodingKeys: String, CodingKey { case person, done, next, blockers }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = UUID()
            person = try container.decodeIfPresent(String.self, forKey: .person) ?? ""
            done = try container.decodeIfPresent([String].self, forKey: .done) ?? []
            next = try container.decodeIfPresent([String].self, forKey: .next) ?? []
            blockers = try container.decodeIfPresent([String].self, forKey: .blockers) ?? []
        }
    }

    /// Ce qu'une personne dit de son sprint, avec la météo qu'elle a choisie.
    ///
    /// Partie nominative et volontairement peu résumée : elle est transmise au manager
    /// de la personne, et doit refléter ce qu'elle a réellement exprimé.
    public struct SprintWeatherEntry: Codable, Sendable, Equatable, Identifiable {
        public var id: UUID
        public var person: String
        /// Un membre peut retenir plusieurs icônes pour un sprint contrasté.
        public var icons: [WeatherIcon]
        /// Pourquoi ces icônes.
        public var explanation: String
        /// Ce que la personne raconte de son sprint.
        public var sprintFeedback: [String]

        public init(
            id: UUID = UUID(),
            person: String,
            icons: [WeatherIcon] = [],
            explanation: String = "",
            sprintFeedback: [String] = []
        ) {
            self.id = id
            self.person = person
            self.icons = icons
            self.explanation = explanation
            self.sprintFeedback = sprintFeedback
        }

        private enum CodingKeys: String, CodingKey {
            case person, icons, explanation, sprintFeedback
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = UUID()
            person = try container.decodeIfPresent(String.self, forKey: .person) ?? ""
            explanation = try container.decodeIfPresent(String.self, forKey: .explanation) ?? ""
            sprintFeedback = try container.decodeIfPresent(
                [String].self, forKey: .sprintFeedback
            ) ?? []
            // Le modèle rend du texte libre : on le ramène au vocabulaire contrôlé et
            // on ignore ce qui n'est pas reconnu plutôt que d'échouer.
            let raw = try container.decodeIfPresent([String].self, forKey: .icons) ?? []
            icons = raw.compactMap(WeatherIcon.parse).uniqued()
        }
    }

    /// Rétrospective au format 4L, dépersonnalisée et regroupée par sujet.
    public struct FourL: Codable, Sendable, Equatable {
        public var liked: [Topic]
        public var learned: [Topic]
        public var lacked: [Topic]
        public var longedFor: [Topic]

        public init(
            liked: [Topic] = [],
            learned: [Topic] = [],
            lacked: [Topic] = [],
            longedFor: [Topic] = []
        ) {
            self.liked = liked
            self.learned = learned
            self.lacked = lacked
            self.longedFor = longedFor
        }

        private enum CodingKeys: String, CodingKey { case liked, learned, lacked, longedFor }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            liked = try container.decodeIfPresent([Topic].self, forKey: .liked) ?? []
            learned = try container.decodeIfPresent([Topic].self, forKey: .learned) ?? []
            lacked = try container.decodeIfPresent([Topic].self, forKey: .lacked) ?? []
            longedFor = try container.decodeIfPresent([Topic].self, forKey: .longedFor) ?? []
        }

        public var isEmpty: Bool {
            liked.isEmpty && learned.isEmpty && lacked.isEmpty && longedFor.isEmpty
        }

        /// Les quatre axes dans l'ordre, avec leur libellé localisé.
        public func axes(in language: SummaryLanguage) -> [(label: String, symbol: String, topics: [Topic])] {
            [
                (language.pick(fr: "Ce qui a plu", en: "Liked"), "hand.thumbsup", liked),
                (language.pick(fr: "Ce qu'on a appris", en: "Learned"), "lightbulb", learned),
                (language.pick(fr: "Ce qui a manqué", en: "Lacked"), "exclamationmark.triangle", lacked),
                (language.pick(fr: "Ce qu'on aurait voulu", en: "Longed for"), "sparkles", longedFor),
            ]
        }
    }

    /// Le ressenti d'une personne lors d'une rétrospective.
    public struct ParticipantMood: Codable, Sendable, Equatable, Identifiable {
        public enum Tone: String, Codable, Sendable, CaseIterable {
            case positive = "positif"
            case neutral = "neutre"
            case negative = "négatif"

            public var symbol: String {
                switch self {
                case .positive: "face.smiling"
                case .neutral: "minus.circle"
                case .negative: "face.dashed"
                }
            }
        }

        public var id: UUID
        public var person: String
        public var mood: Tone
        public var comment: String

        public init(
            id: UUID = UUID(),
            person: String,
            mood: Tone = .neutral,
            comment: String = ""
        ) {
            self.id = id
            self.person = person
            self.mood = mood
            self.comment = comment
        }

        private enum CodingKeys: String, CodingKey { case person, mood, comment }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = UUID()
            person = try container.decodeIfPresent(String.self, forKey: .person) ?? ""
            comment = try container.decodeIfPresent(String.self, forKey: .comment) ?? ""
            let raw = try container.decodeIfPresent(String.self, forKey: .mood)?
                .lowercased()
                .folding(options: .diacriticInsensitive, locale: nil)
            mood = switch raw {
            case "positif", "positive", "positiv": .positive
            case "negatif", "negative": .negative
            default: .neutral
            }
        }
    }

    public struct Topic: Codable, Sendable, Equatable, Identifiable {
        public var id: UUID
        public var heading: String
        public var bullets: [String]

        public init(id: UUID = UUID(), heading: String, bullets: [String]) {
            self.id = id
            self.heading = heading
            self.bullets = bullets
        }

        private enum CodingKeys: String, CodingKey { case heading, bullets }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = UUID()
            heading = try container.decodeIfPresent(String.self, forKey: .heading) ?? ""
            bullets = try container.decodeIfPresent([String].self, forKey: .bullets) ?? []
        }
    }

    /// Nature du ticket qu'un action item deviendra dans Jira.
    ///
    /// Le modèle la propose à partir du contenu du compte rendu ; elle reste
    /// modifiable dans la fenêtre de relecture avant publication.
    public enum IssueType: String, Codable, Sendable, CaseIterable, Identifiable {
        case bug
        case task
        case story
        case epic
        case initiative
        case risk

        public var id: String { rawValue }

        public var symbol: String {
            switch self {
            case .bug: "ladybug.fill"
            case .task: "checkmark.circle"
            case .story: "book.closed"
            case .epic: "flag.fill"
            case .initiative: "target"
            case .risk: "exclamationmark.triangle.fill"
            }
        }

        public func displayName(in language: SummaryLanguage) -> String {
            switch self {
            case .bug: language.pick(fr: "Bug", en: "Bug")
            case .task: language.pick(fr: "Tâche", en: "Task")
            case .story: language.pick(fr: "Story", en: "Story")
            case .epic: language.pick(fr: "Epic", en: "Epic")
            case .initiative: language.pick(fr: "Initiative", en: "Initiative")
            case .risk: language.pick(fr: "Risque", en: "Risk")
            }
        }

        /// Nom du type d'issue Jira correspondant, tel qu'attendu par l'API.
        /// Les projets Jira n'ont pas tous un type « Risk » : reste modifiable dans
        /// les réglages ou directement dans la fenêtre de relecture si le projet
        /// cible utilise un autre vocabulaire.
        public var defaultJiraIssueTypeName: String {
            switch self {
            case .bug: "Bug"
            case .task: "Task"
            case .story: "Story"
            case .epic: "Epic"
            case .initiative: "Initiative"
            case .risk: "Risk"
            }
        }

        /// Reconnaît une valeur libre renvoyée par le modèle, en français ou en
        /// anglais, avec quelques variantes orthographiques courantes.
        public static func parse(_ raw: String?) -> IssueType? {
            guard let normalized = raw?
                .lowercased()
                .folding(options: .diacriticInsensitive, locale: nil)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            else { return nil }
            switch normalized {
            case "bug", "anomalie", "defaut", "défaut": return .bug
            case "task", "tache", "tâche": return .task
            case "story", "histoire", "user story": return .story
            case "epic", "epopee", "épopée": return .epic
            case "initiative": return .initiative
            case "risk", "risque": return .risk
            default: return nil
            }
        }

        /// Classement de repli quand le modèle omet `issueType` ou renvoie une
        /// valeur non reconnue : quelques mots-clés suffisent à orienter les cas
        /// les plus fréquents, un `task` générique couvre le reste.
        public static func detect(from description: String) -> IssueType {
            let text = description
                .lowercased()
                .folding(options: .diacriticInsensitive, locale: nil)

            let bugWords = [
                "bug", "erreur", "crash", "plante", "casse", "cassé", "ne fonctionne pas",
                "ne marche pas", "regression", "défaut", "defaut", "anomalie",
            ]
            let riskWords = ["risque", "risk", "menace", "danger"]
            let epicWords = ["epic", "chantier", "gros chantier"]
            let initiativeWords = ["initiative", "programme", "objectif strategique", "objectif stratégique"]
            let storyWords = ["story", "user story", "fonctionnalite", "fonctionnalité", "feature"]

            if bugWords.contains(where: text.contains) { return .bug }
            if riskWords.contains(where: text.contains) { return .risk }
            if epicWords.contains(where: text.contains) { return .epic }
            if initiativeWords.contains(where: text.contains) { return .initiative }
            if storyWords.contains(where: text.contains) { return .story }
            return .task
        }
    }

    public struct ActionItem: Codable, Sendable, Equatable, Identifiable {
        public var id: UUID
        public var owner: String?
        public var description: String
        public var dueDate: String?
        /// Coché dans la fenêtre de relecture : seuls ces items deviennent des tickets.
        public var isSelected: Bool
        /// Nature du ticket à créer, proposée par le modèle et modifiable avant
        /// publication.
        public var issueType: IssueType
        /// Renseigné après publication.
        public var jiraKey: String?

        public init(
            id: UUID = UUID(),
            owner: String? = nil,
            description: String,
            dueDate: String? = nil,
            isSelected: Bool = true,
            issueType: IssueType = .task,
            jiraKey: String? = nil
        ) {
            self.id = id
            self.owner = owner
            self.description = description
            self.dueDate = dueDate
            self.isSelected = isSelected
            self.issueType = issueType
            self.jiraKey = jiraKey
        }

        private enum CodingKeys: String, CodingKey {
            case owner, description, dueDate, isSelected, issueType, jiraKey
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = UUID()
            owner = try container.decodeIfPresent(String.self, forKey: .owner)
            description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
            dueDate = try container.decodeIfPresent(String.self, forKey: .dueDate)
            isSelected = try container.decodeIfPresent(Bool.self, forKey: .isSelected) ?? true
            let rawIssueType = try container.decodeIfPresent(String.self, forKey: .issueType)
            issueType = IssueType.parse(rawIssueType) ?? IssueType.detect(from: description)
            jiraKey = try container.decodeIfPresent(String.self, forKey: .jiraKey)
        }
    }
}

public extension MeetingSummary {
    /// Contrôle de cohérence minimal : un compte rendu sans titre signale une
    /// génération ratée, même si le JSON est syntaxiquement valide.
    ///
    /// La synthèse n'est pas exigée : un daily met les points bloquants en tête et
    /// relègue le `tldr` en fin, quand il le demande.
    var isUsable: Bool {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return !tldr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !blockers.isEmpty
            || !participantReports.isEmpty
            || !moods.isEmpty
            || !sprintWeather.isEmpty
            || !(fourL?.isEmpty ?? true)
            || !topics.isEmpty
            || !decisions.isEmpty
            || !actionItems.isEmpty
    }

    /// Vrai si la section contient quelque chose à afficher.
    func hasContent(_ section: SummarySection) -> Bool {
        switch section {
        case .tldr: !tldr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .blockers: !blockers.isEmpty
        case .participantReports: !participantReports.isEmpty
        case .moods: !moods.isEmpty
        case .sprintWeather: !sprintWeather.isEmpty
        case .fourL: !(fourL?.isEmpty ?? true)
        case .topics: !topics.isEmpty
        case .decisions: !decisions.isEmpty
        case .actionItems: !actionItems.isEmpty
        case .openQuestions: !openQuestions.isEmpty
        case .nextSteps: !nextSteps.isEmpty
        }
    }

    /// Rendu markdown dans l'ordre des sections du type de réunion.
    func markdown(
        template: MeetingTemplate = .generic,
        language: SummaryLanguage = .french
    ) -> String {
        var output = "# \(title)\n\n"
        if !attendees.isEmpty {
            let label = language.pick(fr: "Participants", en: "Attendees")
            output += "**\(label) :** \(attendees.joined(separator: ", "))\n\n"
        }

        for section in template.sections where hasContent(section) {
            let heading = section.displayName(in: language)
            switch section {
            case .tldr:
                output += "\(tldr)\n\n"

            case .blockers:
                output += "## \(heading)\n\n"
                for blocker in blockers {
                    let marker = blocker.severity == .blocking ? "🛑" : "⚠️"
                    let who = blocker.person.map { "**\($0)** — " } ?? ""
                    output += "- \(marker) \(who)\(blocker.description)\n"
                }
                output += "\n"

            case .participantReports:
                output += "## \(heading)\n\n"
                for report in participantReports {
                    output += "### \(report.person)\n\n"
                    if !report.done.isEmpty {
                        output += "_Fait :_\n" + report.done.map { "- \($0)\n" }.joined()
                    }
                    if !report.next.isEmpty {
                        output += "_À venir :_\n" + report.next.map { "- \($0)\n" }.joined()
                    }
                    if !report.blockers.isEmpty {
                        output += "_Bloqué par :_\n" + report.blockers.map { "- \($0)\n" }.joined()
                    }
                    output += "\n"
                }

            case .moods:
                output += "## \(heading)\n\n"
                for mood in moods {
                    let icon = switch mood.mood {
                    case .positive: "🙂"
                    case .neutral: "😐"
                    case .negative: "🙁"
                    }
                    output += "- \(icon) **\(mood.person)** — \(mood.comment)\n"
                }
                output += "\n"

            case .sprintWeather:
                output += "## \(heading)\n\n"
                for entry in sprintWeather {
                    let icons = entry.icons.map(\.emoji).joined(separator: " ")
                    output += "### \(icons.isEmpty ? "" : icons + " ")\(entry.person)\n\n"
                    if !entry.explanation.isEmpty {
                        output += "\(entry.explanation)\n\n"
                    }
                    for point in entry.sprintFeedback {
                        output += "- \(point)\n"
                    }
                    output += "\n"
                }

            case .fourL:
                guard let fourL else { break }
                output += "## \(heading)\n\n"
                for axis in fourL.axes(in: language) where !axis.topics.isEmpty {
                    output += "### \(axis.label)\n\n"
                    for topic in axis.topics {
                        if !topic.heading.isEmpty {
                            output += "**\(topic.heading)**\n\n"
                        }
                        output += topic.bullets.map { "- \($0)\n" }.joined()
                        output += "\n"
                    }
                }

            case .topics:
                for topic in topics where !topic.heading.isEmpty {
                    output += "## \(topic.heading)\n\n"
                    output += topic.bullets.map { "- \($0)\n" }.joined()
                    output += "\n"
                }

            case .decisions:
                output += "## \(heading)\n\n"
                output += decisions.map { "- \($0)\n" }.joined() + "\n"

            case .actionItems:
                output += "## \(heading)\n\n"
                for item in actionItems {
                    let owner = item.owner.map { "**\($0)** — " } ?? ""
                    let due = item.dueDate.map { " _(échéance \($0))_" } ?? ""
                    let key = item.jiraKey.map { " [\($0)]" } ?? ""
                    let type = "_[\(item.issueType.displayName(in: language))]_ "
                    output += "- \(type)\(owner)\(item.description)\(due)\(key)\n"
                }
                output += "\n"

            case .openQuestions:
                output += "## \(heading)\n\n"
                output += openQuestions.map { "- \($0)\n" }.joined() + "\n"

            case .nextSteps:
                output += "## \(heading)\n\n"
                output += nextSteps.map { "- \($0)\n" }.joined() + "\n"
            }
        }
        return output
    }

    /// Rendu avec le type de réunion enregistré dans le compte rendu.
    var markdown: String {
        markdown(template: MeetingTemplate.resolve(id: templateID, in: []))
    }
}
