import Atlassian
import Foundation
import Testing

@testable import Summarization

@Suite("Extraction du JSON des réponses de modèle")
struct JSONExtractorTests {
    @Test("Objet JSON nu")
    func plainObject() throws {
        let data = try JSONExtractor.extract(from: #"{"title":"A"}"#)
        #expect(String(decoding: data, as: UTF8.self) == #"{"title":"A"}"#)
    }

    @Test("Objet encadré d'un bloc de code markdown")
    func fencedBlock() throws {
        let raw = """
        Voici le compte rendu :

        ```json
        {"title": "Réunion"}
        ```
        """
        let data = try JSONExtractor.extract(from: raw)
        let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(decoded?["title"] as? String == "Réunion")
    }

    @Test("Bloc de code sans marqueur de langage")
    func fenceWithoutLanguage() throws {
        let data = try JSONExtractor.extract(from: "```\n{\"title\": \"X\"}\n```")
        #expect(!data.isEmpty)
    }

    @Test("Texte d'introduction avant l'objet")
    func leadingProse() throws {
        let data = try JSONExtractor.extract(from: "Bien sûr ! {\"title\": \"Y\"} Voilà.")
        let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(decoded?["title"] as? String == "Y")
    }

    @Test("Réponse sans aucun objet JSON")
    func noObject() {
        #expect(throws: SummaryGenerationError.self) {
            try JSONExtractor.extract(from: "Je ne peux pas répondre.")
        }
    }
}

@Suite("Décodage du compte rendu")
struct MeetingSummaryDecodingTests {
    @Test("Les champs absents prennent une valeur par défaut")
    func tolerantDecoding() throws {
        let json = #"{"title":"Point hebdo","tldr":"Synthèse."}"#
        let summary = try JSONDecoder().decode(MeetingSummary.self, from: Data(json.utf8))
        #expect(summary.title == "Point hebdo")
        #expect(summary.decisions.isEmpty)
        #expect(summary.actionItems.isEmpty)
        #expect(summary.isUsable)
    }

    @Test("Un compte rendu sans titre est rejeté")
    func unusableWithoutTitle() throws {
        let json = #"{"title":"","tldr":"Quelque chose"}"#
        let summary = try JSONDecoder().decode(MeetingSummary.self, from: Data(json.utf8))
        #expect(!summary.isUsable)
    }

    @Test("Un compte rendu au titre seul, sans aucune section, est rejeté")
    func unusableWhenEmpty() throws {
        let summary = try JSONDecoder().decode(
            MeetingSummary.self, from: Data(#"{"title":"Vide"}"#.utf8)
        )
        #expect(!summary.isUsable)
    }

    @Test("Les action items reçoivent un identifiant stable")
    func actionItemsGetIdentifiers() throws {
        let json = """
        {"title":"T","tldr":"S","actionItems":[
          {"owner":"Sandra","description":"Valider","dueDate":"2026-09-15"},
          {"owner":null,"description":"Prévenir","dueDate":null}
        ]}
        """
        let summary = try JSONDecoder().decode(MeetingSummary.self, from: Data(json.utf8))
        #expect(summary.actionItems.count == 2)
        #expect(summary.actionItems[0].owner == "Sandra")
        #expect(summary.actionItems[1].owner == nil)
        #expect(summary.actionItems[0].id != summary.actionItems[1].id)
        // Coché par défaut : l'utilisateur décoche ce qu'il ne veut pas en Jira.
        #expect(summary.actionItems.allSatisfy { $0.isSelected })
    }

    @Test("Le rendu markdown contient les sections renseignées")
    func markdownRendering() {
        let summary = MeetingSummary(
            title: "Hebdo",
            tldr: "Trois sujets.",
            decisions: ["Gel des clés"],
            actionItems: [.init(owner: "Martin", description: "Ouvrir un ticket", dueDate: "2026-09-20")]
        )
        let markdown = summary.markdown(template: .generic)
        #expect(markdown.contains("# Hebdo"))
        #expect(markdown.contains("## Décisions"))
        #expect(markdown.contains("**Martin** — Ouvrir un ticket"))
        #expect(markdown.contains("_(échéance 2026-09-20)_"))
    }
}

@Suite("Découpage des transcripts longs")
struct TranscriptSplittingTests {
    @Test("Un transcript court n'est pas découpé")
    func shortTranscript() {
        let chunks = SummaryGenerator.split("a\n\nb\n\nc", maxLength: 1000)
        #expect(chunks.count == 1)
    }

    @Test("Le découpage respecte les frontières de paragraphes")
    func splitsOnParagraphs() {
        let paragraph = String(repeating: "x", count: 100)
        let transcript = Array(repeating: paragraph, count: 10).joined(separator: "\n\n")
        let chunks = SummaryGenerator.split(transcript, maxLength: 250)

        #expect(chunks.count > 1)
        // Aucun paragraphe ne doit avoir été coupé en deux.
        for chunk in chunks {
            for part in chunk.components(separatedBy: "\n\n") {
                #expect(part.count == 100)
            }
        }
    }

    @Test("Aucune donnée perdue au découpage")
    func losesNothing() {
        let transcript = (1...50).map { "Paragraphe \($0) " + String(repeating: "y", count: 60) }
            .joined(separator: "\n\n")
        let chunks = SummaryGenerator.split(transcript, maxLength: 500)
        #expect(chunks.joined(separator: "\n\n") == transcript)
    }
}

@Suite("Rendu au format storage de Confluence")
struct ConfluenceRendererTests {
    @Test("Les caractères XML sont échappés")
    func escapesXML() {
        let rendered = ConfluenceStorageRenderer.escaped("A & B <tag> \"x\"")
        #expect(rendered == "A &amp; B &lt;tag&gt; &quot;x&quot;")
    }

    @Test("Le libellé de piste n'est pas publié comme participant")
    func dropsTrackLabels() {
        let summary = MeetingSummary(
            title: "T", tldr: "S", attendees: ["Moi", "Participants", "Sandra"]
        )
        let html = ConfluenceStorageRenderer.render(
            summary: summary, transcript: "", audioNote: nil
        )
        #expect(html.contains("Sandra"))
        #expect(!html.contains("<strong>Participants :</strong> Moi"))
    }

    @Test("La clé Jira est rendue comme macro native")
    func rendersJiraMacro() {
        let summary = MeetingSummary(
            title: "T",
            tldr: "S",
            actionItems: [.init(description: "Faire", jiraKey: "SEC-1234")]
        )
        let html = ConfluenceStorageRenderer.render(
            summary: summary, transcript: "", audioNote: nil
        )
        #expect(html.contains(#"<ac:structured-macro ac:name="jira">"#))
        #expect(html.contains("SEC-1234"))
    }

    @Test("Le transcript est replié dans une macro expand")
    func foldsTranscript() {
        let html = ConfluenceStorageRenderer.render(
            summary: MeetingSummary(title: "T", tldr: "S"),
            transcript: "**[00:01] Moi :** Bonjour",
            audioNote: nil
        )
        #expect(html.contains(#"ac:name="expand""#))
        // Le balisage markdown est retiré avant publication.
        #expect(!html.contains("**"))
        #expect(html.contains("[00:01] Moi : Bonjour"))
    }

    @Test("Une section vide n'est pas rendue")
    func skipsEmptySections() {
        let html = ConfluenceStorageRenderer.render(
            summary: MeetingSummary(title: "T", tldr: "S"),
            transcript: "",
            audioNote: nil
        )
        #expect(!html.contains("<h2>Décisions</h2>"))
        #expect(!html.contains("<h2>Action items</h2>"))
    }
}

@Suite("Configuration Atlassian")
struct AtlassianConfigurationTests {
    @Test("La publication exige site, e-mail et espace")
    func readiness() {
        var configuration = AtlassianConfiguration(
            site: "acme", email: "a@b.c", spaceKey: "", jiraProjectKey: "SEC"
        )
        #expect(!configuration.isConfluenceReady)
        configuration.spaceKey = "SMARTMEET"
        #expect(configuration.isConfluenceReady)
        #expect(configuration.isJiraReady)
    }

    @Test("L'URL de base est dérivée du site")
    func baseURL() {
        let configuration = AtlassianConfiguration(site: "acme", email: "a@b.c")
        #expect(configuration.baseURL?.absoluteString == "https://acme.atlassian.net")
    }
}
