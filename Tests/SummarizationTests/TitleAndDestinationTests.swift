import Atlassian
import Foundation
import Testing

@testable import Summarization

@Suite("Format du titre de page")
struct TitleFormatTests {
    // Monday September 7, 2026, 2:30 PM.
    private let date = Calendar(identifier: .gregorian).date(
        from: DateComponents(
            timeZone: TimeZone(identifier: "Europe/Paris"),
            year: 2026, month: 9, day: 7, hour: 14, minute: 30
        )
    )!

    private func render(_ format: String, summary: String = "Point migration") -> String {
        TitleFormat.render(
            format, summaryTitle: summary, templateName: "Daily", date: date
        )
    }

    @Test("Le daily nomme le jour et la date")
    func dailyTitle() {
        #expect(render("Daily {Weekday} {date}") == "Daily Lundi 7 septembre 2026")
    }

    @Test("Le jour existe en minuscule et en capitale initiale")
    func weekdayCasing() {
        #expect(render("{Weekday}") == "Lundi")
        #expect(render("réunion du {weekday}") == "réunion du lundi")
    }

    @Test("Les formats de date courts et ISO sont disponibles")
    func dateVariants() {
        #expect(render("{shortDate}") == "07/09/2026")
        #expect(render("{isoDate}") == "2026-09-07")
        #expect(render("{date}") == "7 septembre 2026")
    }

    @Test("Le titre du modèle et le nom du type sont substituables")
    func summaryAndType() {
        #expect(render("{summary}") == "Point migration")
        #expect(render("{type} — {summary}") == "Daily — Point migration")
    }

    @Test("Un titre de modèle vide ne laisse pas de séparateur orphelin")
    func emptySummaryLeavesNoDash() {
        #expect(render("{summary} — {date}", summary: "") == "7 septembre 2026")
        #expect(render("{date} — {summary}", summary: "") == "7 septembre 2026")
    }

    @Test("Un format sans jeton connu reste tel quel")
    func literalFormat() {
        #expect(render("Réunion hebdomadaire") == "Réunion hebdomadaire")
    }

    @Test("Un format vide retombe sur le titre du modèle")
    func emptyFormatFallsBack() {
        #expect(render("") == "Point migration")
    }

    @Test("Les types fournis produisent des titres exploitables")
    func builtInTemplates() {
        #expect(
            MeetingTemplate.daily.pageTitle(summaryTitle: "peu importe", date: date)
                == "Daily Lundi 7 septembre 2026"
        )
        #expect(
            MeetingTemplate.retrospective.pageTitle(summaryTitle: "x", date: date)
                == "Rétrospective — 7 septembre 2026"
        )
        #expect(
            MeetingTemplate.generic.pageTitle(summaryTitle: "Comité produit", date: date)
                == "Comité produit — 7 septembre 2026"
        )
    }

    @Test("Le jeton participant se substitue, et disparaît proprement si absent")
    func participantToken() {
        #expect(
            TitleFormat.render(
                "1:1 {participant} — {date}", summaryTitle: "x", templateName: "One to One",
                date: date, participant: "Sandra"
            ) == "1:1 Sandra — 7 septembre 2026"
        )
        // Without a participant set, the separator doesn't leave a double space.
        #expect(
            TitleFormat.render(
                "1:1 {participant} — {date}", summaryTitle: "x", templateName: "One to One",
                date: date
            ) == "1:1 — 7 septembre 2026"
        )
        #expect(
            MeetingTemplate.oneToOne.pageTitle(summaryTitle: "x", date: date, participant: "Sandra")
                == "1:1 Sandra — 7 septembre 2026"
        )
    }
}

@Suite("Page de sprint")
struct SprintPageTests {
    @Test("Un identifiant nu est accepté")
    func plainIdentifier() {
        #expect(SprintPage.extractPageID(from: "6707707935") == "6707707935")
        #expect(SprintPage.extractPageID(from: "  6707707935  ") == "6707707935")
    }

    @Test("L'URL moderne d'une page est reconnue")
    func modernURL() {
        let url = "https://acme.atlassian.net/wiki/spaces/SMARTMEET/pages/6707707935/Sprint+42"
        #expect(SprintPage.extractPageID(from: url) == "6707707935")
    }

    @Test("L'ancienne URL viewpage est reconnue")
    func legacyURL() {
        let url = "https://acme.atlassian.net/wiki/pages/viewpage.action?pageId=123456"
        #expect(SprintPage.extractPageID(from: url) == "123456")
    }

    @Test("Une saisie non exploitable est rejetée")
    func rejectsGarbage() {
        #expect(SprintPage.extractPageID(from: "") == nil)
        #expect(SprintPage.extractPageID(from: "Sprint 42") == nil)
        #expect(SprintPage.extractPageID(from: "https://example.com/rien") == nil)
    }
}

@Suite("Résolution de la destination")
struct DestinationTests {
    @Test("Une page spécifique conserve son identifiant quel que soit le service")
    func specificPageKeepsID() {
        var template = MeetingTemplate(name: "Comité", sections: [.tldr])
        template.destination = .page(id: "424242")
        #expect(template.destination.pageID == "424242")
    }

    @Test("La destination survit à un aller-retour d'encodage")
    func codableRoundTrip() throws {
        var template = MeetingTemplate(name: "Sprint review", sections: [.tldr])
        template.titleFormat = "Review {Weekday} {date}"
        template.serviceKind = .notion
        template.destination = .page(id: "notion-page")

        let data = try JSONEncoder().encode(template)
        let decoded = try JSONDecoder().decode(MeetingTemplate.self, from: data)
        #expect(decoded == template)
    }

    @Test("Un type enregistré avant l'ajout de la destination reste lisible")
    func decodesLegacyTemplate() throws {
        let json = """
        {"id":"vieux","name":"Ancien","symbol":"doc","sections":["tldr"],
         "instructions":"","isBuiltIn":false}
        """
        let template = try JSONDecoder().decode(MeetingTemplate.self, from: Data(json.utf8))
        #expect(template.name == "Ancien")
        #expect(template.parent == .spaceHome)
        #expect(template.titleFormat == "{summary} — {date}")
        #expect(template.serviceKind == nil)
        #expect(template.destination == .profileDefault)
    }

    @Test("Un service inconnu retombe sur l'héritage du profil")
    func unknownServiceFallsBackToInheritance() throws {
        let json = """
        {"id":"future","name":"Future","symbol":"doc","sections":["tldr"],
         "instructions":"","serviceKind":"future-service","isBuiltIn":false}
        """
        let template = try JSONDecoder().decode(MeetingTemplate.self, from: Data(json.utf8))
        #expect(template.serviceKind == nil)
    }

    @Test("Une page spécifique commune aux services survit à l'encodage")
    func commonSpecificPageRoundTrip() throws {
        var template = MeetingTemplate.personal
        template.serviceKind = .atlassian
        template.destination = .page(id: "424242")
        let data = try JSONEncoder().encode(template)
        let decoded = try JSONDecoder().decode(MeetingTemplate.self, from: data)
        #expect(decoded.destination == .page(id: "424242"))
        #expect(decoded.serviceKind == .atlassian)
    }
}
