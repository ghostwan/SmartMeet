import Atlassian
import Foundation
import Testing

@testable import Summarization

@Suite("Types de réunion")
struct MeetingTemplateTests {
    @Test("Le daily remonte les points bloquants en premier")
    func dailyLeadsWithBlockers() {
        #expect(MeetingTemplate.daily.sections.first == .blockers)
        #expect(MeetingTemplate.daily.sections.contains(.participantReports))
        // La synthèse existe mais passe après : ce n'est pas l'information utile.
        #expect(MeetingTemplate.daily.sections.last == .tldr)
    }

    @Test("La rétrospective ouvre sur le ressenti et ne demande pas de synthèse")
    func retroLeadsWithMoods() {
        #expect(MeetingTemplate.retrospective.sections.first == .moods)
        #expect(!MeetingTemplate.retrospective.sections.contains(.tldr))
    }

    @Test("La consigne de dépersonnalisation est bien transmise au modèle")
    func retroInstructsDepersonalisation() {
        let prompt = SummaryPrompt.single(
            transcript: "…",
            context: SummaryContext(),
            template: .retrospective
        )
        #expect(prompt.contains("n'attribue aucun propos"))
        #expect(prompt.contains("Rétrospective"))
    }

    @Test("Le schéma ne contient que les sections du type de réunion")
    func schemaIsScoped() {
        let daily = SummaryPrompt.schema(for: .daily)
        #expect(daily.contains("blockers"))
        #expect(daily.contains("participantReports"))
        // Un daily ne doit pas se voir proposer ces sections, sinon le modèle les remplit.
        #expect(!daily.contains("moods"))
        #expect(!daily.contains("openQuestions"))

        let retro = SummaryPrompt.schema(for: .retrospective)
        #expect(retro.contains("moods"))
        #expect(!retro.contains("participantReports"))
    }

    @Test("Le titre et les participants sont toujours demandés")
    func schemaAlwaysHasTitle() {
        for template in MeetingTemplate.builtIns {
            let schema = SummaryPrompt.schema(for: template)
            #expect(schema.contains("\"title\""))
            #expect(schema.contains("\"attendees\""))
        }
    }

    @Test("Les consignes de section accompagnent la section demandée")
    func sectionGuidanceIsIncluded() {
        let daily = SummaryPrompt.instructions(context: SummaryContext(), template: .daily)
        #expect(daily.contains("severity"))

        let generic = SummaryPrompt.instructions(context: SummaryContext(), template: .generic)
        #expect(!generic.contains("severity"))
    }

    @Test("Un identifiant inconnu retombe sur le type générique")
    func resolveFallsBack() {
        #expect(MeetingTemplate.resolve(id: "n'existe pas", in: []) == .generic)
        #expect(MeetingTemplate.resolve(id: nil, in: []) == .generic)
        #expect(MeetingTemplate.resolve(id: MeetingTemplate.daily.id, in: []) == .daily)
    }

    @Test("Un type personnalisé prime s'il porte l'identifiant demandé")
    func resolveFindsCustom() {
        let custom = MeetingTemplate(id: "mine", name: "Mon type", sections: [.tldr])
        #expect(MeetingTemplate.resolve(id: "mine", in: [custom]) == custom)
    }
}

@Suite("Décodage des sections spécialisées")
struct SpecialisedSectionDecodingTests {
    @Test("Les points bloquants décodent personne et sévérité")
    func decodesBlockers() throws {
        let json = """
        {"title":"Daily","blockers":[
          {"person":"Sandra","description":"Bloquée par la revue","severity":"bloquant"},
          {"person":null,"description":"Risque sur la date","severity":"risque"}
        ]}
        """
        let summary = try JSONDecoder().decode(MeetingSummary.self, from: Data(json.utf8))
        #expect(summary.blockers.count == 2)
        #expect(summary.blockers[0].severity == .blocking)
        #expect(summary.blockers[1].severity == .risk)
        #expect(summary.blockers[1].person == nil)
        // Un daily sans synthèse reste exploitable.
        #expect(summary.isUsable)
    }

    @Test("Une sévérité inattendue retombe sur « bloquant »")
    func unknownSeverityFallsBack() throws {
        let json = #"{"title":"D","blockers":[{"description":"X","severity":"critique"}]}"#
        let summary = try JSONDecoder().decode(MeetingSummary.self, from: Data(json.utf8))
        // Le repli va vers le cas le plus coûteux à manquer.
        #expect(summary.blockers[0].severity == .blocking)
    }

    @Test("Le ressenti tolère les variantes d'accentuation")
    func moodAccentTolerance() throws {
        let json = """
        {"title":"Retro","moods":[
          {"person":"A","mood":"négatif","comment":"fatigué"},
          {"person":"B","mood":"negatif","comment":"idem"},
          {"person":"C","mood":"positif","comment":"content"},
          {"person":"D","mood":"???","comment":""}
        ]}
        """
        let summary = try JSONDecoder().decode(MeetingSummary.self, from: Data(json.utf8))
        #expect(summary.moods.map(\.mood) == [.negative, .negative, .positive, .neutral])
    }

    @Test("Le point par personne décode ses trois rubriques")
    func decodesParticipantReports() throws {
        let json = """
        {"title":"D","participantReports":[
          {"person":"Martin","done":["A","B"],"next":["C"],"blockers":[]}
        ]}
        """
        let summary = try JSONDecoder().decode(MeetingSummary.self, from: Data(json.utf8))
        #expect(summary.participantReports.first?.done.count == 2)
        #expect(summary.participantReports.first?.blockers.isEmpty == true)
    }
}

@Suite("Rendu selon le type de réunion")
struct TemplateRenderingTests {
    private var dailySummary: MeetingSummary {
        MeetingSummary(
            title: "Daily du 12",
            tldr: "Deux blocages.",
            blockers: [
                .init(person: "Sandra", description: "Attend la revue", severity: .blocking)
            ],
            participantReports: [
                .init(person: "Martin", done: ["Fix protobuf"], next: ["Tests"], blockers: [])
            ],
            templateID: MeetingTemplate.daily.id
        )
    }

    @Test("Le markdown d'un daily commence par les points bloquants")
    func dailyMarkdownOrder() {
        let markdown = dailySummary.markdown(template: .daily)
        let blockersIndex = markdown.range(of: "## Points bloquants")?.lowerBound
        let reportsIndex = markdown.range(of: "## Point par personne")?.lowerBound
        #expect(blockersIndex != nil)
        #expect(reportsIndex != nil)
        #expect(blockersIndex! < reportsIndex!)
        // La synthèse existe mais arrive après.
        #expect(markdown.range(of: "Deux blocages.")!.lowerBound > reportsIndex!)
    }

    @Test("Les points bloquants sont publiés dans un encadré d'alerte")
    func blockersRenderAsPanel() {
        let html = ConfluenceStorageRenderer.render(
            summary: dailySummary, transcript: "", audioNote: nil, template: .daily
        )
        #expect(html.contains(#"ac:name="warning""#))
        #expect(html.contains("Sandra"))
    }

    @Test("Un risque seul n'escalade pas en encadré d'alerte")
    func riskOnlyUsesNotePanel() {
        let summary = MeetingSummary(
            title: "D",
            blockers: [.init(description: "Date serrée", severity: .risk)]
        )
        let html = ConfluenceStorageRenderer.render(
            summary: summary, transcript: "", audioNote: nil, template: .daily
        )
        #expect(html.contains(#"ac:name="note""#))
        #expect(!html.contains(#"ac:name="warning""#))
    }

    @Test("Le ressenti d'une rétrospective est rendu en tableau nominatif")
    func moodsRenderAsTable() {
        let summary = MeetingSummary(
            title: "Retro",
            topics: [.init(heading: "Charge de travail", bullets: ["Trop de contextes"])],
            moods: [.init(person: "Sandra", mood: .negative, comment: "Sous l'eau")]
        )
        let html = ConfluenceStorageRenderer.render(
            summary: summary, transcript: "", audioNote: nil, template: .retrospective
        )
        let moodIndex = html.range(of: "Sandra")?.lowerBound
        let topicIndex = html.range(of: "Charge de travail")?.lowerBound
        #expect(moodIndex != nil && topicIndex != nil)
        // Le ressenti nominatif vient avant les sujets dépersonnalisés.
        #expect(moodIndex! < topicIndex!)
        #expect(html.contains("<table>"))
    }

    @Test("Une section hors du type de réunion n'est jamais rendue")
    func sectionsOutsideTemplateAreIgnored() {
        // Le modèle a répondu avec des questions ouvertes que le daily ne demandait pas.
        let summary = MeetingSummary(
            title: "D",
            openQuestions: ["Une question parasite"],
            blockers: [.init(description: "Bloqué")]
        )
        let markdown = summary.markdown(template: .daily)
        #expect(!markdown.contains("Une question parasite"))

        let html = ConfluenceStorageRenderer.render(
            summary: summary, transcript: "", audioNote: nil, template: .daily
        )
        #expect(!html.contains("Une question parasite"))
    }

    @Test("Le pied de page mentionne le type de réunion")
    func footerNamesTemplate() {
        let html = ConfluenceStorageRenderer.render(
            summary: dailySummary, transcript: "", audioNote: nil, template: .daily
        )
        #expect(html.contains("Daily"))
    }
}

@Suite("Normalisation des libellés de piste")
struct SanitizationTests {
    private func summary() -> MeetingSummary {
        MeetingSummary(
            title: "T",
            attendees: ["Moi", "Participants", "Sandra", "Sandra"],
            actionItems: [
                .init(owner: "Moi", description: "A"),
                .init(owner: "Participants", description: "B"),
                .init(owner: "Martin", description: "C"),
            ],
            blockers: [.init(person: "Moi", description: "X")],
            participantReports: [
                .init(person: "Moi", done: ["a"]),
                .init(person: "Participants", done: ["b"]),
                .init(person: "Yoann", done: ["c"]),
            ],
            moods: [.init(person: "Participants"), .init(person: "Clément")]
        )
    }

    @Test("« Moi » devient le nom de l'utilisateur")
    func replacesSelfLabel() {
        let cleaned = SummaryGenerator.sanitize(
            summary(), context: SummaryContext(userName: "Alex")
        )
        #expect(cleaned.actionItems[0].owner == "Alex")
        #expect(cleaned.blockers[0].person == "Alex")
        #expect(cleaned.attendees.contains("Alex"))
    }

    @Test("« Participants » ne désigne personne et devient null")
    func dropsCollectiveLabel() {
        let cleaned = SummaryGenerator.sanitize(
            summary(), context: SummaryContext(userName: "Alex")
        )
        #expect(cleaned.actionItems[1].owner == nil)
        #expect(!cleaned.attendees.contains("Participants"))
    }

    @Test("Sans nom d'utilisateur, « Moi » devient null plutôt que d'être affiché")
    func withoutUserName() {
        let cleaned = SummaryGenerator.sanitize(summary(), context: SummaryContext())
        #expect(cleaned.actionItems[0].owner == nil)
        #expect(!cleaned.attendees.contains("Moi"))
    }

    @Test("Les entrées nominatives sans identité exploitable sont retirées")
    func dropsAnonymousEntries() {
        let cleaned = SummaryGenerator.sanitize(
            summary(), context: SummaryContext(userName: "Alex")
        )
        // « Participants » disparaît, « Moi » devient Alex, Yoann reste.
        #expect(cleaned.participantReports.map(\.person) == ["Alex", "Yoann"])
        #expect(cleaned.moods.map(\.person) == ["Clément"])
    }

    @Test("Les vrais noms ne sont jamais altérés et les doublons disparaissent")
    func preservesRealNames() {
        let cleaned = SummaryGenerator.sanitize(
            summary(), context: SummaryContext(userName: "Alex")
        )
        #expect(cleaned.actionItems[2].owner == "Martin")
        #expect(cleaned.attendees == ["Alex", "Sandra"])
    }
}
