import Foundation

/// Une section possible du compte rendu. Le type de réunion choisit lesquelles
/// demander au modèle, et dans quel ordre les rendre.
public enum SummarySection: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Synthèse en quelques phrases.
    case tldr
    /// Ce qui bloque l'équipe, remonté en tête pour un daily.
    case blockers
    /// Un point par personne : ce qu'elle a fait, ce qu'elle prévoit.
    case participantReports
    /// Ressenti nominatif de chaque membre, pour une rétrospective.
    case moods
    /// Météo du sprint : chaque membre choisit une ou plusieurs icônes, explique son
    /// choix, et dit ce qu'il retient de son sprint. Partie nominative, destinée à
    /// être transmise aux managers.
    case sprintWeather
    /// Format 4L d'une rétrospective : Liked, Learned, Lacked, Longed for.
    case fourL
    /// Sujets abordés, regroupés par thème.
    case topics
    case decisions
    case actionItems
    case openQuestions
    case nextSteps

    public var id: String { rawValue }

    public var displayName: String { displayName(in: .french) }

    public func displayName(in language: SummaryLanguage) -> String {
        switch self {
        case .tldr: language.pick(fr: "Synthèse", en: "Summary")
        case .blockers: language.pick(fr: "Points bloquants", en: "Blockers")
        case .participantReports: language.pick(fr: "Point par personne", en: "Individual updates")
        case .moods: language.pick(fr: "Ressenti de l'équipe", en: "Team mood")
        case .sprintWeather: language.pick(fr: "Météo du sprint", en: "Sprint weather")
        case .fourL: language.pick(fr: "4L", en: "4L")
        case .topics: language.pick(fr: "Sujets", en: "Topics")
        case .decisions: language.pick(fr: "Décisions", en: "Decisions")
        case .actionItems: language.pick(fr: "Action items", en: "Action items")
        case .openQuestions: language.pick(fr: "Questions ouvertes", en: "Open questions")
        case .nextSteps: language.pick(fr: "Prochaines étapes", en: "Next steps")
        }
    }


    /// Fragment de schéma JSON demandé au modèle pour cette section.
    var schemaFragment: String {
        switch self {
        case .tldr:
            #""tldr": "string — 2 à 3 phrases de synthèse""#
        case .blockers:
            #""blockers": [{ "person": "string|null", "description": "string", "severity": "bloquant|risque" }]"#
        case .participantReports:
            #""participantReports": [{ "person": "string", "done": ["string"], "next": ["string"], "blockers": ["string"] }]"#
        case .moods:
            #""moods": [{ "person": "string", "mood": "positif|neutre|négatif", "comment": "string" }]"#
        case .sprintWeather:
            #""sprintWeather": [{ "person": "string", "icons": ["string"], "explanation": "string", "sprintFeedback": ["string"] }]"#
        case .fourL:
            #""fourL": { "liked": [{ "heading": "string", "bullets": ["string"] }], "learned": [{ "heading": "string", "bullets": ["string"] }], "lacked": [{ "heading": "string", "bullets": ["string"] }], "longedFor": [{ "heading": "string", "bullets": ["string"] }] }"#
        case .topics:
            #""topics": [{ "heading": "string", "bullets": ["string"] }]"#
        case .decisions:
            #""decisions": ["string"]"#
        case .actionItems:
            #""actionItems": [{ "owner": "string|null", "description": "string", "dueDate": "string|null" }]"#
        case .openQuestions:
            #""openQuestions": ["string"]"#
        case .nextSteps:
            #""nextSteps": ["string"]"#
        }
    }

    /// Consigne de remplissage propre à la section, dans la langue du compte rendu.
    func guidance(in language: SummaryLanguage) -> String? {
        switch self {
        case .blockers:
            language.pick(
                fr: """
                Dans `blockers`, ne liste que ce qui empêche réellement quelqu'un \
                d'avancer ou menace une échéance. `severity` vaut « bloquant » si la \
                personne est à l'arrêt, « risque » si elle avance encore mais qu'un \
                danger est identifié.
                """,
                en: """
                In `blockers`, list only what actually prevents someone from making \
                progress or threatens a deadline. `severity` is "bloquant" when the \
                person is stuck, "risque" when they can still move forward but a danger \
                has been identified.
                """
            )

        case .participantReports:
            language.pick(
                fr: """
                Dans `participantReports`, une entrée par personne ayant parlé, dans \
                l'ordre de prise de parole. `done` est ce qu'elle a terminé, `next` ce \
                qu'elle prévoit, `blockers` ce qui la freine. N'invente pas d'entrée \
                pour quelqu'un qui ne s'est pas exprimé.
                """,
                en: """
                In `participantReports`, one entry per person who spoke, in speaking \
                order. `done` is what they completed, `next` what they plan, `blockers` \
                what is slowing them down. Do not invent an entry for someone who did \
                not speak.
                """
            )

        case .moods:
            language.pick(
                fr: """
                Dans `moods`, une entrée par personne, avec son ressenti explicite ou \
                déduit de son ton et de ses propos. `comment` cite ou reformule \
                brièvement ce qui justifie ce ressenti.
                """,
                en: """
                In `moods`, one entry per person, with the mood they stated or that can \
                be inferred from their tone and words. `comment` briefly quotes or \
                rephrases what justifies it.
                """
            )

        case .sprintWeather:
            language.pick(
                fr: """
                Dans `sprintWeather`, une entrée par personne ayant pris la parole. \
                `icons` contient une ou plusieurs valeurs parmi : \(WeatherIcon.promptVocabulary). \
                Un membre peut en choisir plusieurs — soleil et orage pour un sprint \
                contrasté, par exemple : reprends-les toutes. `explanation` restitue ce \
                qu'il a dit pour justifier ce choix. `sprintFeedback` reprend ce qu'il \
                raconte de son sprint : charge, difficultés, satisfactions, relations \
                avec l'équipe. Reste fidèle à ses propos et à ses nuances, ne lisse pas \
                et ne résume pas à l'excès : cette partie est transmise à son manager et \
                doit refléter ce que la personne a réellement exprimé. Ne retranscris \
                pas le contenu des post-its, uniquement ce qui est dit à l'oral.
                """,
                en: """
                In `sprintWeather`, one entry per person who spoke. `icons` holds one or \
                more values from: \(WeatherIcon.promptVocabulary). Someone may pick \
                several — sun and storm for a mixed sprint, for instance: keep them all. \
                `explanation` conveys what they said to justify that choice. \
                `sprintFeedback` captures what they say about their sprint: workload, \
                difficulties, satisfactions, relationships within the team. Stay faithful \
                to their words and their nuance, do not smooth things over or \
                over-summarise: this part is shared with their manager and must reflect \
                what the person actually expressed. Do not transcribe sticky notes, only \
                what is said out loud.
                """
            )

        case .fourL:
            language.pick(
                fr: """
                Dans `fourL`, répartis les échanges selon les quatre axes : `liked` ce \
                qui a plu, `learned` ce qui a été appris, `lacked` ce qui a manqué, \
                `longedFor` ce qui aurait été souhaité. Chaque axe regroupe les remarques \
                par sujet : `heading` nomme le thème, `bullets` détaille. N'attribue \
                aucun propos à personne dans cette partie et fusionne les remarques \
                convergentes de plusieurs participants. Un axe sans matière reste une \
                liste vide.
                """,
                en: """
                In `fourL`, split the discussion across the four axes: `liked` what went \
                well, `learned` what was learned, `lacked` what was missing, `longedFor` \
                what people wished for. Each axis groups remarks by topic: `heading` names \
                the theme, `bullets` gives the detail. Do not attribute any statement to \
                anyone in this part, and merge converging remarks from several \
                participants. An axis with nothing to say stays an empty list.
                """
            )

        case .tldr, .topics, .decisions, .actionItems, .openQuestions, .nextSteps:
            nil
        }
    }
}

/// Type de réunion : détermine les sections demandées, leur ordre, et les consignes
/// de rédaction supplémentaires envoyées au modèle.
public struct MeetingTemplate: Codable, Sendable, Identifiable, Equatable, Hashable {
    public var id: String
    public var name: String
    public var symbol: String
    /// L'ordre fait foi, à la fois pour le schéma demandé et pour le rendu.
    public var sections: [SummarySection]
    /// Consignes libres ajoutées au prompt.
    public var instructions: String
    /// Composition du titre de la page publiée. Voir `TitleFormat.placeholders`.
    ///
    /// Les parties littérales ne sont pas traduites : c'est une convention de nommage
    /// choisie par l'équipe, pas du contenu. Seuls les jetons de date suivent la
    /// langue du compte rendu. Préférer `{type}` à un libellé en dur permet au titre
    /// de rester cohérent avec le nom du type affiché dans l'application.
    public var titleFormat: String
    /// Espace Confluence de destination. Vide = espace par défaut des réglages.
    public var spaceKeyOverride: String
    /// Page sous laquelle publier.
    public var parent: ParentPageReference
    /// Les modèles fournis ne sont pas supprimables, seulement dupliquables.
    public var isBuiltIn: Bool

    public init(
        id: String = UUID().uuidString,
        name: String,
        symbol: String = "doc.text",
        sections: [SummarySection],
        instructions: String = "",
        titleFormat: String = "{summary} — {date}",
        spaceKeyOverride: String = "",
        parent: ParentPageReference = .spaceHome,
        isBuiltIn: Bool = false
    ) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.sections = sections
        self.instructions = instructions
        self.titleFormat = titleFormat
        self.spaceKeyOverride = spaceKeyOverride
        self.parent = parent
        self.isBuiltIn = isBuiltIn
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, symbol, sections, instructions
        case titleFormat, spaceKeyOverride, parent, isBuiltIn
    }

    /// Décodage tolérant : les types enregistrés avant l'ajout de la destination
    /// doivent rester utilisables.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        symbol = try container.decodeIfPresent(String.self, forKey: .symbol) ?? "doc.text"
        sections = try container.decodeIfPresent([SummarySection].self, forKey: .sections) ?? []
        instructions = try container.decodeIfPresent(String.self, forKey: .instructions) ?? ""
        titleFormat = try container.decodeIfPresent(String.self, forKey: .titleFormat)
            ?? "{summary} — {date}"
        spaceKeyOverride = try container.decodeIfPresent(String.self, forKey: .spaceKeyOverride) ?? ""
        parent = try container.decodeIfPresent(ParentPageReference.self, forKey: .parent)
            ?? .spaceHome
        isBuiltIn = try container.decodeIfPresent(Bool.self, forKey: .isBuiltIn) ?? false
    }

    /// Titre de la page publiée pour une réunion donnée.
    public func pageTitle(
        summaryTitle: String,
        date: Date,
        language: SummaryLanguage = .french
    ) -> String {
        TitleFormat.render(
            titleFormat,
            summaryTitle: summaryTitle,
            templateName: name,
            date: date,
            language: language
        )
    }
}

public extension MeetingTemplate {
    static let generic = MeetingTemplate(
        id: "builtin.generic",
        name: "Réunion générique",
        symbol: "doc.text",
        sections: [.tldr, .decisions, .actionItems, .topics, .openQuestions, .nextSteps],
        instructions: "",
        titleFormat: "{summary} — {date}",
        isBuiltIn: true
    )

    static let daily = MeetingTemplate(
        id: "builtin.daily",
        name: "Daily",
        symbol: "sun.horizon",
        // Les points bloquants passent avant tout le reste : c'est la seule
        // information sur laquelle on agit dans l'heure qui suit un daily.
        sections: [.blockers, .participantReports, .actionItems, .tldr],
        instructions: """
        C'est un point quotidien d'équipe, court et opérationnel.

        Fais remonter en premier ce qui bloque ou menace l'équipe : c'est la seule \
        partie sur laquelle on agit immédiatement. Sois direct, nomme les personnes \
        concernées et l'obstacle précis, sans enrobage.

        Établis ensuite un point par personne. Reste factuel et bref : deux ou trois \
        éléments par rubrique suffisent. Si quelqu'un n'a rien signalé de bloquant, \
        laisse sa liste `blockers` vide plutôt que d'inventer.

        La synthèse `tldr` vient en dernier et tient en deux phrases.
        """,
        // Un daily se retrouve par sa date, pas par un titre que le modèle
        // reformule différemment chaque jour.
        titleFormat: "Daily {Weekday} {date}",
        parent: .sprintPage,
        isBuiltIn: true
    )

    static let synchro = MeetingTemplate(
        id: "builtin.synchro",
        name: "Synchro",
        symbol: "arrow.triangle.2.circlepath",
        sections: [.tldr, .decisions, .actionItems, .topics, .openQuestions, .nextSteps],
        instructions: """
        C'est une réunion de synchronisation entre plusieurs parties prenantes.

        Mets l'accent sur les décisions arrêtées et les engagements pris, avec leur \
        responsable. Distingue nettement ce qui est tranché de ce qui reste en \
        suspens : tout ce qui n'a pas été explicitement décidé va dans les questions \
        ouvertes.
        """,
        titleFormat: "{summary} — {Weekday} {date}",
        parent: .sprintPage,
        isBuiltIn: true
    )

    static let retrospective = MeetingTemplate(
        id: "builtin.retro",
        name: "Rétrospective",
        symbol: "arrow.counterclockwise",
        sections: [.sprintWeather, .fourL, .actionItems, .decisions],
        instructions: """
        C'est une rétrospective d'équipe au format 4L, ouverte par une météo du sprint.

        La météo du sprint est nominative et destinée à être transmise aux managers : \
        restitue fidèlement ce que chaque personne dit de son sprint, avec ses nuances \
        et ses réserves. Ne lisse pas, ne reformule pas en positif ce qui est exprimé \
        négativement. Plusieurs icônes météo par personne sont normales et doivent \
        toutes être conservées.

        Les 4L sont au contraire dépersonnalisés : **n'attribue aucun propos à qui que \
        ce soit** dans cette partie. Les titres décrivent le thème (« Charge de \
        travail », « Qualité des specs », « Outillage de test »), jamais les personnes. \
        Fusionne les remarques convergentes de plusieurs participants en un seul point. \
        Cette dépersonnalisation est volontaire : elle permet d'aborder les sujets \
        sensibles sans mettre personne en cause.

        Les post-its et le tableau ne sont pas dans le transcript : appuie-toi \
        uniquement sur ce qui est dit à l'oral.

        Les action items restent nominatifs, puisqu'il faut bien un responsable.
        """,
        titleFormat: "{type} — {date}",
        parent: .sprintPage,
        isBuiltIn: true
    )

    /// Pour un échange sans rapport avec le travail (personnel, familial, amical,
    /// administratif…) : mêmes sections que le type générique, mais sans vocabulaire
    /// ni cadre professionnel imposé par le prompt.
    static let personal = MeetingTemplate(
        id: "builtin.personal",
        name: "Conversation personnelle",
        symbol: "bubble.left.and.bubble.right",
        sections: [.tldr, .decisions, .actionItems, .topics, .openQuestions, .nextSteps],
        instructions: """
        Ce n'est pas une réunion professionnelle : c'est une conversation personnelle \
        (échange familial, amical, administratif, entre particuliers…). N'emploie \
        aucun vocabulaire ni cadre d'entreprise — pas de « réunion », « équipe », \
        « sprint », « ticket »… Rédige comme on résumerait une discussion entre \
        proches.

        Ne force aucune section à contenir quelque chose si la conversation n'a \
        débouché ni sur décision, ni sur action, ni sur sujet ouvert : laisse-les \
        vides plutôt que d'inventer du contenu qui n'a pas eu lieu.
        """,
        titleFormat: "{summary} — {date}",
        isBuiltIn: true
    )

    static let builtIns: [MeetingTemplate] = [generic, daily, synchro, retrospective, personal]

    /// Retrouve un modèle par identifiant, avec repli sur le modèle générique.
    /// Un modèle personnalisé prime sur un modèle fourni de même identifiant : c'est
    /// ainsi qu'une édition d'un type fourni (voir `AppSettings.upsert`) est prise en
    /// compte plutôt que la version d'origine codée en dur.
    static func resolve(id: String?, in custom: [MeetingTemplate]) -> MeetingTemplate {
        guard let id else { return .generic }
        return custom.first { $0.id == id } ?? builtIns.first { $0.id == id } ?? .generic
    }
}
