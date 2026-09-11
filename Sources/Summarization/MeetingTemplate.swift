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
    /// Sujets abordés, regroupés par thème.
    case topics
    case decisions
    case actionItems
    case openQuestions
    case nextSteps

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .tldr: "Synthèse"
        case .blockers: "Points bloquants"
        case .participantReports: "Point par personne"
        case .moods: "Ressenti de l'équipe"
        case .topics: "Sujets"
        case .decisions: "Décisions"
        case .actionItems: "Action items"
        case .openQuestions: "Questions ouvertes"
        case .nextSteps: "Prochaines étapes"
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

    /// Consigne de remplissage propre à la section.
    var guidance: String? {
        switch self {
        case .blockers:
            "Dans `blockers`, ne liste que ce qui empêche réellement quelqu'un d'avancer "
                + "ou menace une échéance. `severity` vaut « bloquant » si la personne est "
                + "à l'arrêt, « risque » si elle avance encore mais qu'un danger est identifié."
        case .participantReports:
            "Dans `participantReports`, une entrée par personne ayant parlé, dans l'ordre "
                + "de prise de parole. `done` est ce qu'elle a terminé, `next` ce qu'elle "
                + "prévoit, `blockers` ce qui la freine. N'invente pas d'entrée pour "
                + "quelqu'un qui ne s'est pas exprimé."
        case .moods:
            "Dans `moods`, une entrée par personne, avec son ressenti explicite ou déduit "
                + "de son ton et de ses propos. `comment` cite ou reformule brièvement ce "
                + "qui justifie ce ressenti."
        case .topics:
            nil
        default:
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
    public func pageTitle(summaryTitle: String, date: Date) -> String {
        TitleFormat.render(
            titleFormat,
            summaryTitle: summaryTitle,
            templateName: name,
            date: date
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
        sections: [.moods, .topics, .actionItems, .decisions],
        instructions: """
        C'est une rétrospective d'équipe.

        Commence par le ressenti de chaque membre, nominativement : c'est la seule \
        partie où les personnes sont citées.

        Regroupe ensuite les échanges par sujet, et surtout **n'attribue aucun propos \
        à qui que ce soit** dans cette partie. Les titres de sujets décrivent le thème \
        (« Charge de travail », « Qualité des specs », « Outillage de test »), pas les \
        personnes. Fusionne les remarques convergentes de plusieurs participants en un \
        seul point. Cette dépersonnalisation est volontaire : elle permet d'aborder les \
        sujets sensibles sans mettre personne en cause.

        Les action items restent nominatifs, puisqu'il faut bien un responsable.
        """,
        titleFormat: "Rétrospective — {date}",
        parent: .sprintPage,
        isBuiltIn: true
    )

    static let builtIns: [MeetingTemplate] = [generic, daily, synchro, retrospective]

    /// Retrouve un modèle par identifiant, avec repli sur le modèle générique.
    static func resolve(id: String?, in custom: [MeetingTemplate]) -> MeetingTemplate {
        guard let id else { return .generic }
        return (builtIns + custom).first { $0.id == id } ?? .generic
    }
}
