import Atlassian
import Foundation
import Testing

@testable import Summarization

@Suite("Icônes météo")
struct WeatherIconTests {
    @Test("Les identifiants du schéma sont reconnus")
    func parsesIdentifiers() {
        #expect(WeatherIcon.parse("sun") == .sun)
        #expect(WeatherIcon.parse("partlySunny") == .partlySunny)
        #expect(WeatherIcon.parse("heatwave") == .heatwave)
    }

    @Test("Les libellés français, avec ou sans accent, sont reconnus")
    func parsesFrenchLabels() {
        #expect(WeatherIcon.parse("Éclaircie") == .partlySunny)
        #expect(WeatherIcon.parse("eclaircie") == .partlySunny)
        #expect(WeatherIcon.parse("Orage") == .storm)
        #expect(WeatherIcon.parse("brouillard") == .fog)
        #expect(WeatherIcon.parse("arc-en-ciel") == .rainbow)
    }

    @Test("Les libellés anglais et les variantes courantes sont reconnus")
    func parsesEnglishAndAliases() {
        #expect(WeatherIcon.parse("Storm") == .storm)
        #expect(WeatherIcon.parse("thunderstorm") == .storm)
        #expect(WeatherIcon.parse("overcast") == .cloudy)
        #expect(WeatherIcon.parse("rainy") == .rain)
    }

    @Test("Les emoji sont reconnus")
    func parsesEmoji() {
        #expect(WeatherIcon.parse("☀️") == .sun)
        #expect(WeatherIcon.parse("⛈️") == .storm)
    }

    @Test("Une valeur inconnue est ignorée plutôt que de faire échouer le décodage")
    func rejectsUnknown() {
        #expect(WeatherIcon.parse("licorne") == nil)
        #expect(WeatherIcon.parse("") == nil)
    }
}

@Suite("Météo du sprint")
struct SprintWeatherTests {
    @Test("Une personne peut retenir plusieurs icônes")
    func decodesMultipleIcons() throws {
        let json = """
        {"title":"Retro","sprintWeather":[
          {"person":"Clément","icons":["soleil","orage"],
           "explanation":"Sujet passionnant mais interruptions",
           "sprintFeedback":["Six interruptions","Frustré de ne pas avoir fini"]}
        ]}
        """
        let summary = try JSONDecoder().decode(MeetingSummary.self, from: Data(json.utf8))
        let entry = try #require(summary.sprintWeather.first)
        #expect(entry.icons == [.sun, .storm])
        #expect(entry.sprintFeedback.count == 2)
        #expect(summary.isUsable)
    }

    @Test("Les icônes non reconnues sont écartées sans perdre l'entrée")
    func dropsUnknownIconsOnly() throws {
        let json = """
        {"title":"R","sprintWeather":[
          {"person":"A","icons":["soleil","licorne","orage"],"explanation":"x","sprintFeedback":[]}
        ]}
        """
        let summary = try JSONDecoder().decode(MeetingSummary.self, from: Data(json.utf8))
        #expect(summary.sprintWeather.first?.icons == [.sun, .storm])
    }

    @Test("Une icône répétée n'apparaît qu'une fois")
    func deduplicatesIcons() throws {
        let json = """
        {"title":"R","sprintWeather":[
          {"person":"A","icons":["sun","soleil","☀️"],"explanation":"","sprintFeedback":[]}
        ]}
        """
        let summary = try JSONDecoder().decode(MeetingSummary.self, from: Data(json.utf8))
        #expect(summary.sprintWeather.first?.icons == [.sun])
    }

    @Test("La normalisation des libellés de piste s'applique aussi à la météo")
    func sanitizesTrackLabels() {
        let summary = MeetingSummary(
            title: "R",
            sprintWeather: [
                .init(person: "Moi", icons: [.sun]),
                .init(person: "Participants", icons: [.rain]),
                .init(person: "Sandra", icons: [.storm]),
            ]
        )
        let cleaned = SummaryGenerator.sanitize(
            summary, context: SummaryContext(userName: "Alex")
        )
        #expect(cleaned.sprintWeather.map(\.person) == ["Alex", "Sandra"])
    }
}

@Suite("Format 4L")
struct FourLTests {
    private let json = """
    {"title":"Retro","fourL":{
      "liked":[{"heading":"Revues de code","bullets":["Passent vite"]}],
      "learned":[{"heading":"Protobuf","bullets":["Normalisable côté gateway"]}],
      "lacked":[{"heading":"Specs","bullets":["Cas d'erreur absents"]}],
      "longedFor":[{"heading":"Rotation","bullets":["Astreinte écrite"]}]
    }}
    """

    @Test("Les quatre axes sont décodés")
    func decodesAllAxes() throws {
        let summary = try JSONDecoder().decode(MeetingSummary.self, from: Data(json.utf8))
        let fourL = try #require(summary.fourL)
        #expect(fourL.liked.first?.heading == "Revues de code")
        #expect(fourL.learned.first?.heading == "Protobuf")
        #expect(fourL.lacked.first?.heading == "Specs")
        #expect(fourL.longedFor.first?.heading == "Rotation")
        #expect(!fourL.isEmpty)
    }

    @Test("Un axe absent reste une liste vide")
    func missingAxisIsEmpty() throws {
        let partial = #"{"title":"R","fourL":{"liked":[{"heading":"A","bullets":["b"]}]}}"#
        let summary = try JSONDecoder().decode(MeetingSummary.self, from: Data(partial.utf8))
        #expect(summary.fourL?.lacked.isEmpty == true)
        #expect(summary.fourL?.isEmpty == false)
    }

    @Test("Un 4L entièrement vide ne rend aucune section")
    func emptyFourLRendersNothing() {
        let summary = MeetingSummary(title: "R", tldr: "S", fourL: .init())
        #expect(!summary.hasContent(.fourL))
    }

    @Test("Les axes portent des libellés selon la langue")
    func axisLabelsFollowLanguage() throws {
        let summary = try JSONDecoder().decode(MeetingSummary.self, from: Data(json.utf8))
        let fourL = try #require(summary.fourL)
        #expect(fourL.axes(in: .french).map(\.label)
            == ["Ce qui a plu", "Ce qu'on a appris", "Ce qui a manqué", "Ce qu'on aurait voulu"])
        #expect(fourL.axes(in: .english).map(\.label)
            == ["Liked", "Learned", "Lacked", "Longed for"])
    }

    @Test("La rétrospective fournie adopte le format 4L ouvert par la météo")
    func retroTemplateUsesFourL() {
        #expect(MeetingTemplate.retrospective.sections.first == .sprintWeather)
        #expect(MeetingTemplate.retrospective.sections.contains(.fourL))
        // Le format 4L remplace les sujets libres.
        #expect(!MeetingTemplate.retrospective.sections.contains(.topics))
    }
}

@Suite("Langue du compte rendu")
struct SummaryLanguageTests {
    private var retroSummary: MeetingSummary {
        MeetingSummary(
            title: "Retro",
            sprintWeather: [
                .init(person: "Sandra", icons: [.storm, .fog], explanation: "Bloquée", sprintFeedback: ["Quatre jours perdus"])
            ],
            fourL: .init(liked: [.init(heading: "Revues", bullets: ["Rapides"])])
        )
    }

    @Test("Les titres de sections suivent la langue")
    func sectionHeadingsAreLocalised() {
        #expect(SummarySection.sprintWeather.displayName(in: .french) == "Météo du sprint")
        #expect(SummarySection.sprintWeather.displayName(in: .english) == "Sprint weather")
        #expect(SummarySection.blockers.displayName(in: .english) == "Blockers")
    }

    @Test("Le markdown est rendu dans la langue demandée")
    func markdownFollowsLanguage() {
        let french = retroSummary.markdown(template: .retrospective, language: .french)
        #expect(french.contains("## Météo du sprint"))
        #expect(french.contains("### Ce qui a plu"))

        let english = retroSummary.markdown(template: .retrospective, language: .english)
        #expect(english.contains("## Sprint weather"))
        #expect(english.contains("### Liked"))
    }

    @Test("Le rendu Confluence suit aussi la langue")
    func confluenceFollowsLanguage() {
        let english = ConfluenceStorageRenderer.render(
            summary: retroSummary,
            transcript: "",
            audioNote: nil,
            template: .retrospective,
            language: .english
        )
        #expect(english.contains("<h2>Sprint weather</h2>"))
        #expect(english.contains("Full transcript"))
        #expect(english.contains("⛈️"))
    }

    @Test("Le prompt est rédigé dans la langue de sortie")
    func promptIsWrittenInTargetLanguage() {
        let english = SummaryPrompt.instructions(
            context: SummaryContext(), template: .retrospective, language: .english
        )
        #expect(english.contains("Write the entire output in English"))
        #expect(!english.contains("Règles générales"))

        let french = SummaryPrompt.instructions(
            context: SummaryContext(), template: .retrospective, language: .french
        )
        #expect(french.contains("Rédige la totalité du compte rendu en français"))
    }

    @Test("Le vocabulaire météo est transmis au modèle")
    func promptCarriesWeatherVocabulary() {
        let prompt = SummaryPrompt.instructions(
            context: SummaryContext(), template: .retrospective, language: .french
        )
        #expect(prompt.contains("partlySunny"))
        #expect(prompt.contains("post-its"))
    }

    @Test("Le titre de page suit la langue")
    func titleFollowsLanguage() {
        let date = Calendar(identifier: .gregorian).date(
            from: DateComponents(
                timeZone: TimeZone(identifier: "Europe/Paris"),
                year: 2026, month: 9, day: 7
            )
        )!
        #expect(
            MeetingTemplate.daily.pageTitle(summaryTitle: "x", date: date, language: .french)
                == "Daily Lundi 7 septembre 2026"
        )
        #expect(
            MeetingTemplate.daily.pageTitle(summaryTitle: "x", date: date, language: .english)
                == "Daily Monday 7 September 2026"
        )
    }
}
