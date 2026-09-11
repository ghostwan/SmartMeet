import Foundation

/// Construit les prompts à partir du type de réunion.
///
/// Le schéma n'est pas figé : chaque type de réunion demande ses propres sections, et
/// uniquement celles-là. Envoyer un schéma complet puis espérer que le modèle ignore
/// les sections inutiles produisait des sections vides polluant le compte rendu.
enum SummaryPrompt {
    /// Schéma JSON limité aux sections du type de réunion, plus le titre toujours requis.
    static func schema(for template: MeetingTemplate) -> String {
        var fragments = [
            #""title": "string — titre court et informatif de la réunion""#,
            #""attendees": ["string"]"#,
        ]
        fragments += template.sections.map(\.schemaFragment)
        return "{\n  " + fragments.joined(separator: ",\n  ") + "\n}"
    }

    static func instructions(context: SummaryContext, template: MeetingTemplate) -> String {
        var text = """
        Tu rédiges le compte rendu d'une réunion à partir d'un transcript horodaté.

        Le transcript provient d'une capture à deux pistes : « Moi » est l'utilisateur \
        qui enregistre, « Participants » regroupe toutes les autres voix. Attribue les \
        propos aux personnes nommées quand le contexte le permet.

        Règles générales :
        - N'invente jamais une décision, un engagement ou une échéance absente du transcript.
        - Une information incertaine ne doit pas être présentée comme un fait.
        - `owner` et `person` sont des prénoms cités dans le transcript.
        - `dueDate` au format AAAA-MM-JJ ou null. Résous les dates relatives par rapport \
        à la date de la réunion.
        - Laisse une liste vide plutôt que de la remplir avec du contenu inventé.
        - Rédige en français, dans un style factuel et dense.

        Type de réunion : \(template.name).
        Date de la réunion : \(context.dateDescription).
        """

        // Le transcript n'identifie l'utilisateur que par « Moi » : sans cette
        // consigne, ses engagements sortent avec « Moi » comme responsable.
        if let userName = context.userName, !userName.isEmpty {
            text += "\n\nLa personne qui enregistre, désignée par « Moi » dans le "
                + "transcript, s'appelle \(userName). Utilise ce nom, jamais « Moi »."
        } else {
            text += "\n\nN'utilise jamais « Moi » ni « Participants » comme nom de "
                + "personne : ce sont des libellés de piste audio, pas des identités. "
                + "Laisse `owner` à null si la personne n'est pas nommée."
        }

        // Consignes propres aux sections demandées.
        let guidance = template.sections.compactMap(\.guidance)
        if !guidance.isEmpty {
            text += "\n\nConsignes par section :\n"
                + guidance.map { "- \($0)" }.joined(separator: "\n")
        }

        let custom = template.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !custom.isEmpty {
            text += "\n\nConsignes propres à ce type de réunion :\n\(custom)"
        }

        if !context.knownAttendees.isEmpty {
            text += "\n\nParticipants connus (issus du calendrier) : "
                + context.knownAttendees.joined(separator: ", ") + "."
        }
        if !context.vocabulary.isEmpty {
            text += "\nVocabulaire métier à orthographier correctement : "
                + context.vocabulary.joined(separator: ", ") + "."
        }
        return text
    }

    /// Prompt de génération directe, pour une réunion tenant dans la fenêtre de contexte.
    static func single(
        transcript: String,
        context: SummaryContext,
        template: MeetingTemplate
    ) -> String {
        """
        \(instructions(context: context, template: template))

        Réponds UNIQUEMENT avec un objet JSON valide conforme à ce schéma, sans texte \
        autour et sans bloc de code markdown. N'ajoute aucune clé hors de ce schéma :

        \(schema(for: template))

        --- TRANSCRIPT ---

        \(transcript)
        """
    }

    /// Étape « map » : condense une tranche de réunion en notes brutes.
    static func chunk(
        transcript: String,
        index: Int,
        total: Int,
        template: MeetingTemplate
    ) -> String {
        """
        Voici la tranche \(index) sur \(total) du transcript d'une réunion \
        (type : \(template.name)).

        Résume-la en notes factuelles et denses : sujets abordés, décisions prises, \
        engagements avec leur responsable, obstacles signalés, ressentis exprimés, \
        questions laissées ouvertes. Conserve les horodatages, les prénoms et les \
        chiffres. N'invente rien. Pas de JSON, juste des notes en français.

        --- TRANSCRIPT (tranche \(index)/\(total)) ---

        \(transcript)
        """
    }

    /// Étape « reduce » : synthétise les notes de toutes les tranches.
    static func reduce(
        notes: [String],
        context: SummaryContext,
        template: MeetingTemplate
    ) -> String {
        let joined = notes.enumerated()
            .map { "### Tranche \($0.offset + 1)\n\($0.element)" }
            .joined(separator: "\n\n")
        return """
        \(instructions(context: context, template: template))

        Tu disposes des notes de chaque tranche d'une même réunion, dans l'ordre \
        chronologique. Produis un compte rendu unique et cohérent : fusionne les \
        redites, ne conserve qu'une seule fois chaque décision et chaque engagement.

        Réponds UNIQUEMENT avec un objet JSON valide conforme à ce schéma, sans texte \
        autour et sans bloc de code markdown. N'ajoute aucune clé hors de ce schéma :

        \(schema(for: template))

        --- NOTES PAR TRANCHE ---

        \(joined)
        """
    }

    /// Relance après un JSON invalide : on renvoie l'erreur au modèle.
    static func repair(
        previousOutput: String,
        error: String,
        template: MeetingTemplate
    ) -> String {
        """
        La réponse précédente n'était pas un JSON valide conforme au schéma demandé.

        Erreur : \(error)

        Corrige-la et renvoie UNIQUEMENT l'objet JSON valide, sans texte autour et sans \
        bloc de code markdown. Schéma attendu :

        \(schema(for: template))

        --- RÉPONSE À CORRIGER ---

        \(previousOutput.prefix(8000))
        """
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

    var dateDescription: String {
        date.formatted(
            .dateTime.weekday(.wide).day().month(.wide).year()
                .locale(Locale(identifier: "fr_FR"))
        )
    }
}
