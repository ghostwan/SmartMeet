import Foundation

/// A possible section of the meeting minutes. The meeting type chooses which
/// sections to request from the model, and in what order to render them.
public enum SummarySection: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Summary in a few sentences.
    case tldr
    /// What's blocking the team, surfaced first for a daily.
    case blockers
    /// One entry per person: what they did, what they plan next.
    case participantReports
    /// Named mood of each member, for a retrospective.
    case moods
    /// Sprint weather: each member picks one or more icons, explains their
    /// choice, and shares what they take away from their sprint. Named section,
    /// meant to be shared with managers.
    case sprintWeather
    /// 4L retrospective format: Liked, Learned, Lacked, Longed for.
    case fourL
    /// Topics covered, grouped by theme.
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


    /// JSON schema fragment requested from the model for this section.
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
            #""actionItems": [{ "owner": "string|null", "description": "string", "dueDate": "string|null", "issueType": "bug|task|story|epic|initiative|risk" }]"#
        case .openQuestions:
            #""openQuestions": ["string"]"#
        case .nextSteps:
            #""nextSteps": ["string"]"#
        }
    }

    /// Section-specific fill-in guidance, in the minutes' language.
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

        case .tldr, .topics, .decisions, .openQuestions, .nextSteps:
            nil

        case .actionItems:
            language.pick(
                fr: """
                Dans `actionItems`, `issueType` classe la nature du futur ticket Jira \
                parmi : `bug` (anomalie ou dysfonctionnement à corriger), `task` \
                (tâche technique ou opérationnelle ponctuelle), `story` (fonctionnalité \
                utilisateur à livrer), `epic` (chantier important regroupant plusieurs \
                tâches sur plusieurs sprints), `initiative` (objectif stratégique \
                regroupant plusieurs epics) ou `risk` (risque identifié qui n'est pas \
                encore un blocage mais mérite d'être suivi). Choisis la valeur la plus \
                précise possible à partir du contenu réellement discuté ; à défaut, \
                utilise `task`.
                """,
                en: """
                In `actionItems`, `issueType` classifies the future Jira ticket among: \
                `bug` (a defect or malfunction to fix), `task` (a one-off technical or \
                operational chore), `story` (a user-facing feature to deliver), `epic` \
                (a large body of work spanning several sprints), `initiative` (a \
                strategic goal grouping several epics), or `risk` (an identified risk \
                that is not yet a blocker but should be tracked). Pick the most precise \
                value based on what was actually discussed; default to `task` otherwise.
                """
            )
        }
    }
}

/// Meeting type: determines the requested sections, their order, and the extra
/// authoring guidance sent to the model.
public struct MeetingTemplate: Codable, Sendable, Identifiable, Equatable, Hashable {
    public var id: String
    public var name: String
    public var symbol: String
    /// The order is authoritative, both for the requested schema and for rendering.
    public var sections: [SummarySection]
    /// Free-form instructions appended to the prompt.
    public var instructions: String
    /// Composition of the published page's title. See `TitleFormat.placeholders`.
    ///
    /// Literal parts are not translated: it's a naming convention chosen by the
    /// team, not content. Only date tokens follow the minutes' language. Preferring
    /// `{type}` over a hardcoded label keeps the title consistent with the type
    /// name displayed in the app.
    public var titleFormat: String
    /// Destination Confluence space. Empty = the default space from settings.
    public var spaceKeyOverride: String
    /// Page under which to publish.
    public var parent: ParentPageReference
    /// Publication service for this type. `nil` inherits the profile's
    /// effective service; a concrete value never silently falls back to a
    /// different service if it later becomes unavailable.
    public var serviceKind: ServiceKind?
    /// True for a type that involves exactly two people (the user and a single
    /// counterpart) — a one-to-one, typically. This drives two things: the UI
    /// asks for that counterpart before recording, and the published page is
    /// restricted to those two accounts rather than visible to the whole space.
    public var requiresParticipant: Bool
    /// Built-in templates cannot be deleted, only duplicated.
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
        serviceKind: ServiceKind? = nil,
        requiresParticipant: Bool = false,
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
        self.serviceKind = serviceKind
        self.requiresParticipant = requiresParticipant
        self.isBuiltIn = isBuiltIn
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, symbol, sections, instructions
        case titleFormat, spaceKeyOverride, parent, serviceKind, requiresParticipant, isBuiltIn
    }

    /// Tolerant decoding: templates saved before the destination field was added
    /// must remain usable.
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
        let rawServiceKind = try container.decodeIfPresent(String.self, forKey: .serviceKind)
        serviceKind = rawServiceKind.flatMap(ServiceKind.init(rawValue:))
        requiresParticipant = try container.decodeIfPresent(Bool.self, forKey: .requiresParticipant) ?? false
        isBuiltIn = try container.decodeIfPresent(Bool.self, forKey: .isBuiltIn) ?? false
    }

    /// Title of the published page for a given meeting.
    public func pageTitle(
        summaryTitle: String,
        date: Date,
        language: SummaryLanguage = .french,
        participant: String = ""
    ) -> String {
        TitleFormat.render(
            titleFormat,
            summaryTitle: summaryTitle,
            templateName: name,
            date: date,
            language: language,
            participant: participant
        )
    }
}

public extension MeetingTemplate {
    /// Localized UI name for an untouched built-in template. The persisted
    /// `name` remains the source of truth for prompts, publication titles,
    /// inference and custom templates; checking both the stable identifier and
    /// canonical name ensures that a user-renamed built-in stays exactly as
    /// they named it instead of being replaced by a translation.
    var localizedName: String {
        let canonicalName: String?
        switch (id, name) {
        case ("builtin.generic", "Réunion de travail"):
            canonicalName = "Réunion de travail"
        case ("builtin.daily", "Daily"):
            canonicalName = "Daily"
        case ("builtin.synchro", "Synchro"):
            canonicalName = "Synchro"
        case ("builtin.retro", "Rétrospective"):
            canonicalName = "Rétrospective"
        case ("builtin.personal", "Réunion générique"):
            canonicalName = "Réunion générique"
        case ("builtin.oneToOne", "One to One"):
            canonicalName = "One to One"
        default:
            canonicalName = nil
        }

        guard let canonicalName else { return name }
        return NSLocalizedString(
            canonicalName,
            bundle: .main,
            value: canonicalName,
            comment: "Built-in meeting template name"
        )
    }

    static let generic = MeetingTemplate(
        id: "builtin.generic",
        name: "Réunion de travail",
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
        // Blockers come before everything else: it's the only information
        // acted upon within the hour that follows a daily.
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
        // A daily is identified by its date, not by a title the model
        // rephrases differently every day.
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

    /// For an exchange unrelated to work (personal, family, friends,
    /// administrative…): same sections as the work type, but without the
    /// vocabulary or professional framing imposed by the prompt. This is the
    /// neutral baseline every new profile starts with.
    static let personal = MeetingTemplate(
        id: "builtin.personal",
        name: "Réunion générique",
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

    /// One-on-one between the user and a single other person (manager, peer,
    /// recurring interview…). Unlike other types, it involves one specific named
    /// person: the UI asks who before recording, and the published page is
    /// restricted to them and the user — not the rest of the space.
    static let oneToOne = MeetingTemplate(
        id: "builtin.oneToOne",
        name: "One to One",
        symbol: "person.2",
        sections: [.tldr, .decisions, .actionItems, .topics, .openQuestions, .nextSteps],
        instructions: """
        C'est un tête-à-tête entre l'utilisateur et une seule autre personne, pas une \
        réunion d'équipe. Reste factuel sur ce qui a été dit par les deux \
        interlocuteurs, sans reformuler en langage de management.

        Les décisions et action items sont nominatifs : chacun sait déjà qui est qui, \
        inutile de le préciser lourdement.
        """,
        titleFormat: "1:1 {participant} — {date}",
        requiresParticipant: true,
        isBuiltIn: true
    )

    static let builtIns: [MeetingTemplate] = [personal, generic, daily, synchro, retrospective, oneToOne]

    static let builtInIDs = Set(builtIns.map(\.id))

    var hasBuiltInIdentity: Bool { Self.builtInIDs.contains(id) }

    /// Looks up a template by identifier, falling back to the generic template
    /// (the neutral "Réunion générique" baseline, not the work-oriented one).
    /// A custom template takes priority over a built-in template with the same
    /// identifier: this is how editing a built-in type (see `AppSettings.upsert`)
    /// is honored rather than the original hardcoded version.
    static func resolve(id: String?, in custom: [MeetingTemplate]) -> MeetingTemplate {
        guard let id else { return .personal }
        return custom.first { $0.id == id } ?? builtIns.first { $0.id == id } ?? .personal
    }

    /// Guesses the meeting type from its title — useful as soon as a meeting is
    /// suggested by the calendar or a video conferencing app, before the user has
    /// manually picked a type from the menu.
    ///
    /// A simple keyword match rather than a model: a meeting title is short and
    /// rarely follows elaborate grammar, a substring match is good enough and stays
    /// predictable for the user (unlike a probabilistic score, hard to explain if
    /// the guessed type is surprising). `nil` when nothing matches: it's up to the
    /// caller to keep whatever type is already selected rather than force generic.
    static func infer(fromTitle title: String, in candidates: [MeetingTemplate]) -> MeetingTemplate? {
        let normalized = title
            .lowercased()
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        guard !normalized.isEmpty else { return nil }

        // Keywords specific to the built-in types, in French and English: a
        // meeting title follows the organizer's language, not necessarily the
        // minutes' language. Generic and personal conversation have no reliable
        // keyword — they're fallbacks, not types we detect.
        let builtInKeywords: [String: [String]] = [
            daily.id: ["daily", "standup", "stand-up", "stand up", "point quotidien"],
            synchro.id: ["synchro", "sync"],
            retrospective.id: ["retro", "rétro", "retrospective", "rétrospective"],
            oneToOne.id: ["one to one", "one-to-one", "1:1", "1-1", "tete a tete", "tête-à-tête"],
        ]

        for candidate in candidates {
            let keywords = builtInKeywords[candidate.id] ?? []
            if keywords.contains(where: normalized.contains) {
                return candidate
            }
        }

        // Custom (or renamed built-in) types: absent dedicated keywords, the
        // type's own name is the only available hint. A name that's too short
        // ("IT", "QA"…) would produce too many false positives, so it's ignored.
        for candidate in candidates where builtInKeywords[candidate.id] == nil {
            let candidateName = candidate.name
                .lowercased()
                .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            guard candidateName.count >= 4 else { continue }
            if normalized.contains(candidateName) {
                return candidate
            }
        }

        return nil
    }
}
