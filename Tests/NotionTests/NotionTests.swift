import Foundation
import Testing

@testable import Notion

@Suite("Extraction de l'identifiant de page Notion")
struct NotionConfigurationTests {
    @Test("Un identifiant nu avec tirets est accepté")
    func plainDashedID() {
        let id = "2ac1f5c4-a1b3-4e6c-9a9d-8f6f6f6f6f6f"
        #expect(NotionConfiguration.extractPageID(from: id) == id)
    }

    @Test("Un identifiant nu sans tirets est reformaté")
    func plainUndashedID() {
        let id = "2ac1f5c4a1b34e6c9a9d8f6f6f6f6f6f"
        #expect(NotionConfiguration.extractPageID(from: id) == "2ac1f5c4-a1b3-4e6c-9a9d-8f6f6f6f6f6f")
    }

    @Test("Une URL Notion moderne est reconnue")
    func modernURL() {
        let url = "https://www.notion.so/monworkspace/Sprint-42-2ac1f5c4a1b34e6c9a9d8f6f6f6f6f6f"
        #expect(NotionConfiguration.extractPageID(from: url) == "2ac1f5c4-a1b3-4e6c-9a9d-8f6f6f6f6f6f")
    }

    @Test("Une saisie non exploitable est rejetée")
    func rejectsGarbage() {
        #expect(NotionConfiguration.extractPageID(from: "") == nil)
        #expect(NotionConfiguration.extractPageID(from: "pas un identifiant") == nil)
        #expect(NotionConfiguration.extractPageID(from: "https://example.com/rien") == nil)
    }
}

@Suite("Conversion markdown vers blocs Notion")
struct MarkdownToNotionBlocksTests {
    @Test("Le titre de premier niveau est retiré, il double celui de la page")
    func dropsLeadingTitle() {
        let blocks = MarkdownToNotionBlocks.blocks(from: "# Mon compte rendu\n\nSuite du texte.")
        #expect(blocks.count == 1)
        #expect(blocks[0]["type"] as? String == "paragraph")
    }

    @Test("Les niveaux de titre sont reconnus")
    func recognizesHeadings() {
        let blocks = MarkdownToNotionBlocks.blocks(from: "## Section\n### Sous-section")
        #expect(blocks[0]["type"] as? String == "heading_2")
        #expect(blocks[1]["type"] as? String == "heading_3")
    }

    @Test("Une puce devient un bulleted_list_item")
    func recognizesBullets() {
        let blocks = MarkdownToNotionBlocks.blocks(from: "- Premier point\n- Second point")
        #expect(blocks.count == 2)
        #expect(blocks[0]["type"] as? String == "bulleted_list_item")
    }

    @Test("Le gras est extrait en annotation, pas en astérisques littéraux")
    func extractsBoldAnnotation() throws {
        let blocks = MarkdownToNotionBlocks.blocks(from: "- **Alice** — a fini la tâche")
        let block = try #require(blocks.first)
        let bulleted = try #require(block["bulleted_list_item"] as? [String: Any])
        let richText = try #require(bulleted["rich_text"] as? [[String: Any]])
        #expect(richText.count == 2)
        let firstAnnotations = try #require(richText[0]["annotations"] as? [String: Bool])
        #expect(firstAnnotations["bold"] == true)
        let firstText = try #require(richText[0]["text"] as? [String: String])
        #expect(firstText["content"] == "Alice")
    }

    @Test("Les lignes vides ne produisent aucun bloc")
    func skipsEmptyLines() {
        let blocks = MarkdownToNotionBlocks.blocks(from: "## Titre\n\n\n- Point")
        #expect(blocks.count == 2)
    }

    @Test("Plus de 100 blocs restent découpables en lots pour l'ajout ultérieur")
    func manyBlocksExceedSingleRequestLimit() {
        let markdown = (1...150).map { "- Point \($0)" }.joined(separator: "\n")
        let blocks = MarkdownToNotionBlocks.blocks(from: markdown)
        #expect(blocks.count == 150)
        #expect(blocks.count > MarkdownToNotionBlocks.maxBlocksPerRequest)
    }
}
