import Foundation

/// Construit les prompts à partir du type de réunion et de la langue de sortie.
///
/// Le schéma n'est pas figé : chaque type de réunion demande ses propres sections, et
/// uniquement celles-là. Envoyer un schéma complet puis espérer que le modèle ignore
/// les sections inutiles produisait des sections vides polluant le compte rendu.
///
/// Les consignes sont rédigées dans la langue de sortie. Une consigne en français
/// suivie d'un « réponds en anglais » fait dériver les modèles locaux vers un mélange
/// des deux ; formuler directement dans la langue cible tient beaucoup mieux.
enum SummaryPrompt {
    /// Schéma JSON limité aux sections du type de réunion, plus le titre toujours requis.
    static func schema(for template: MeetingTemplate) -> String {
        var fragments = [
            #""title": "string""#,
            #""attendees": ["string"]"#,
        ]
        fragments += template.sections.map(\.schemaFragment)
        return "{\n  " + fragments.joined(separator: ",\n  ") + "\n}"
    }

    static func instructions(
        context: SummaryContext,
        template: MeetingTemplate,
        language: SummaryLanguage
    ) -> String {
        var text = language.pick(
            fr: """
            Tu rédiges le compte rendu d'une réunion à partir d'un transcript horodaté.

            Le transcript provient d'une capture à deux pistes : « Moi » est \
            l'utilisateur qui enregistre, « Participants » regroupe toutes les autres \
            voix. Attribue les propos aux personnes nommées quand le contexte le permet.

            Règles générales :
            - N'invente jamais une décision, un engagement ou une échéance absente du \
            transcript.
            - Une information incertaine ne doit pas être présentée comme un fait.
            - `owner` et `person` sont des prénoms cités dans le transcript.
            - `dueDate` au format AAAA-MM-JJ ou null. Résous les dates relatives par \
            rapport à la date de la réunion.
            - Laisse une liste vide plutôt que de la remplir avec du contenu inventé.
            - Rédige la totalité du compte rendu en français, dans un style factuel et \
            dense.
            """,
            en: """
            You are writing the minutes of a meeting from a time-stamped transcript.

            The transcript comes from a two-track capture: "Moi" is the person \
            recording, "Participants" covers every other voice. Attribute statements to \
            named people whenever the context allows it.

            General rules:
            - Never invent a decision, a commitment or a deadline that is absent from \
            the transcript.
            - Uncertain information must not be presented as fact.
            - `owner` and `person` are first names mentioned in the transcript.
            - `dueDate` in YYYY-MM-DD format, or null. Resolve relative dates against \
            the meeting date.
            - Leave a list empty rather than filling it with invented content.
            - Write the entire output in English, in a factual and dense style, even \
            though the transcript is in another language.
            """
        )

        text += "\n\n" + language.pick(
            fr: "Type de réunion : \(template.name).\nDate de la réunion : \(context.dateDescription(in: language)).",
            en: "Meeting type: \(template.name).\nMeeting date: \(context.dateDescription(in: language))."
        )

        // Le transcript n'identifie l'utilisateur que par « Moi » : sans cette
        // consigne, ses engagements sortent avec « Moi » comme responsable.
        if let userName = context.userName, !userName.isEmpty {
            text += "\n\n" + language.pick(
                fr: "La personne qui enregistre, désignée par « Moi » dans le transcript, s'appelle \(userName). Utilise ce nom, jamais « Moi ».",
                en: "The person recording, referred to as \"Moi\" in the transcript, is named \(userName). Use that name, never \"Moi\"."
            )
        } else {
            text += "\n\n" + language.pick(
                fr: "N'utilise jamais « Moi » ni « Participants » comme nom de personne : ce sont des libellés de piste audio, pas des identités. Laisse `owner` à null si la personne n'est pas nommée.",
                en: "Never use \"Moi\" or \"Participants\" as a person's name: these are audio track labels, not identities. Leave `owner` null when the person is not named."
            )
        }

        // Consignes propres aux sections demandées.
        let guidance = template.sections.compactMap { $0.guidance(in: language) }
        if !guidance.isEmpty {
            text += "\n\n" + language.pick(fr: "Consignes par section :", en: "Section guidance:")
                + "\n" + guidance.map { "- \($0)" }.joined(separator: "\n")
        }

        let custom = template.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !custom.isEmpty {
            text += "\n\n" + language.pick(
                fr: "Consignes propres à ce type de réunion :",
                en: "Guidance specific to this meeting type:"
            ) + "\n\(custom)"
        }

        if !context.knownAttendees.isEmpty {
            text += "\n\n" + language.pick(
                fr: "Participants connus (issus du calendrier) : ",
                en: "Known attendees (from the calendar): "
            ) + context.knownAttendees.joined(separator: ", ") + "."
        }
        if !context.vocabulary.isEmpty {
            text += "\n" + language.pick(
                fr: "Vocabulaire métier à orthographier correctement : ",
                en: "Domain vocabulary to spell correctly: "
            ) + context.vocabulary.joined(separator: ", ") + "."
        }
        return text
    }

    private static func schemaDirective(
        for template: MeetingTemplate,
        language: SummaryLanguage
    ) -> String {
        language.pick(
            fr: """
            Réponds UNIQUEMENT avec un objet JSON valide conforme à ce schéma, sans \
            texte autour et sans bloc de code markdown. N'ajoute aucune clé hors de ce \
            schéma. Les noms de clés restent tels quels, seules les valeurs sont \
            rédigées en français :

            \(schema(for: template))
            """,
            en: """
            Reply ONLY with a valid JSON object matching this schema, with no \
            surrounding text and no markdown code fence. Do not add any key outside \
            this schema. Key names stay exactly as written; only the values are in \
            English:

            \(schema(for: template))
            """
        )
    }

    /// Prompt de génération directe, pour une réunion tenant dans la fenêtre de contexte.
    static func single(
        transcript: String,
        context: SummaryContext,
        template: MeetingTemplate,
        language: SummaryLanguage
    ) -> String {
        """
        \(instructions(context: context, template: template, language: language))

        \(schemaDirective(for: template, language: language))

        --- TRANSCRIPT ---

        \(transcript)
        """
    }

    /// Étape « map » : condense une tranche de réunion en notes brutes.
    ///
    /// Les notes intermédiaires restent dans la langue de sortie : les traduire à
    /// l'étape finale seulement ferait perdre des nuances à chaque passe.
    static func chunk(
        transcript: String,
        index: Int,
        total: Int,
        template: MeetingTemplate,
        language: SummaryLanguage
    ) -> String {
        language.pick(
            fr: """
            Voici la tranche \(index) sur \(total) du transcript d'une réunion \
            (type : \(template.name)).

            Résume-la en notes factuelles et denses, en français : sujets abordés, \
            décisions prises, engagements avec leur responsable, obstacles signalés, \
            ressentis exprimés, questions laissées ouvertes. Conserve les horodatages, \
            les prénoms et les chiffres. N'invente rien. Pas de JSON, juste des notes.

            --- TRANSCRIPT (tranche \(index)/\(total)) ---

            \(transcript)
            """,
            en: """
            Here is chunk \(index) of \(total) from a meeting transcript \
            (type: \(template.name)).

            Summarise it as dense factual notes, in English: topics covered, decisions \
            made, commitments with their owner, blockers raised, feelings expressed, \
            open questions. Keep timestamps, first names and figures. Invent nothing. \
            No JSON, just notes.

            --- TRANSCRIPT (chunk \(index)/\(total)) ---

            \(transcript)
            """
        )
    }

    /// Étape « reduce » : synthétise les notes de toutes les tranches.
    static func reduce(
        notes: [String],
        context: SummaryContext,
        template: MeetingTemplate,
        language: SummaryLanguage
    ) -> String {
        let joined = notes.enumerated()
            .map { language.pick(fr: "### Tranche \($0.offset + 1)", en: "### Chunk \($0.offset + 1)") + "\n\($0.element)" }
            .joined(separator: "\n\n")

        let framing = language.pick(
            fr: """
            Tu disposes des notes de chaque tranche d'une même réunion, dans l'ordre \
            chronologique. Produis un compte rendu unique et cohérent : fusionne les \
            redites, ne conserve qu'une seule fois chaque décision et chaque engagement.
            """,
            en: """
            You have the notes for each chunk of a single meeting, in chronological \
            order. Produce one coherent set of minutes: merge duplicates, keep each \
            decision and each commitment only once.
            """
        )

        return """
        \(instructions(context: context, template: template, language: language))

        \(framing)

        \(schemaDirective(for: template, language: language))

        --- \(language.pick(fr: "NOTES PAR TRANCHE", en: "NOTES PER CHUNK")) ---

        \(joined)
        """
    }

    /// Relance après un JSON invalide : on renvoie l'erreur au modèle.
    static func repair(
        previousOutput: String,
        error: String,
        template: MeetingTemplate,
        language: SummaryLanguage
    ) -> String {
        language.pick(
            fr: """
            La réponse précédente n'était pas un JSON valide conforme au schéma demandé.

            Erreur : \(error)

            Corrige-la et renvoie UNIQUEMENT l'objet JSON valide, sans texte autour et \
            sans bloc de code markdown. Schéma attendu :

            \(schema(for: template))

            --- RÉPONSE À CORRIGER ---

            \(previousOutput.prefix(8000))
            """,
            en: """
            The previous reply was not valid JSON matching the requested schema.

            Error: \(error)

            Fix it and return ONLY the valid JSON object, with no surrounding text and \
            no markdown code fence. Expected schema:

            \(schema(for: template))

            --- REPLY TO FIX ---

            \(previousOutput.prefix(8000))
            """
        )
    }
}

/// Contexte injecté dans le prompt, au-delà du transcript lui-même.
public struct SummaryContext: Sendable {
    public var date: Date
    public var knownAttendees: [String]
    public var vocabulary: [String]
    /// Nom de la personne qui enregistre. Le transcript ne connaît que « Moi » pour
    /// la piste micro ; sans ce nom, ses engagements restent anonymes.
    public var userName: String?

    public init(
        date: Date = .now,
        knownAttendees: [String] = [],
        vocabulary: [String] = [],
        userName: String? = nil
    ) {
        self.date = date
        self.knownAttendees = knownAttendees
        self.vocabulary = vocabulary
        self.userName = userName
    }

    func dateDescription(in language: SummaryLanguage) -> String {
        date.formatted(
            .dateTime.weekday(.wide).day().month(.wide).year().locale(language.locale)
        )
    }
}
