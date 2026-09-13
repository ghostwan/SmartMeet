import Foundation

/// Convertit le markdown produit par `MeetingSummary.markdown(template:language:)` en
/// blocs Notion (format attendu par `POST /v1/pages` et `PATCH .../children`).
///
/// Ce n'est pas un parseur markdown généraliste : seul le sous-ensemble
/// effectivement produit par `MeetingSummary` est couvert (titres `#`/`##`/`###`,
/// puces `- `, emphase `**gras**`, lignes `_italique :_`, paragraphes). Suffisant
/// ici, insuffisant pour du markdown arbitraire.
enum MarkdownToNotionBlocks {
    /// Notion limite un appel à 100 blocs enfants ; au-delà, il faut les ajouter en
    /// plusieurs requêtes `PATCH`. Voir `NotionClient.createPage`.
    static let maxBlocksPerRequest = 100

    static func blocks(from markdown: String) -> [[String: Any]] {
        var blocks: [[String: Any]] = []
        var isFirstLine = true

        for rawLine in markdown.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            // La première ligne (`# Titre`) redouble le titre de la page Notion,
            // déjà posé via les propriétés de la page : on l'ignore ici.
            if isFirstLine {
                isFirstLine = false
                if line.hasPrefix("# ") { continue }
            }

            if line.isEmpty { continue }

            if line.hasPrefix("### ") {
                blocks.append(heading(3, String(line.dropFirst(4))))
            } else if line.hasPrefix("## ") {
                blocks.append(heading(2, String(line.dropFirst(3))))
            } else if line.hasPrefix("# ") {
                blocks.append(heading(1, String(line.dropFirst(2))))
            } else if line.hasPrefix("- ") {
                blocks.append(bulletedListItem(String(line.dropFirst(2))))
            } else if line.hasPrefix("_"), line.hasSuffix("_"), line.count > 1 {
                blocks.append(paragraph(String(line.dropFirst().dropLast()), italic: true))
            } else {
                blocks.append(paragraph(line))
            }
        }
        return blocks
    }

    private static func heading(_ level: Int, _ text: String) -> [String: Any] {
        ["object": "block", "type": "heading_\(level)",
         "heading_\(level)": ["rich_text": richText(from: text)]]
    }

    private static func bulletedListItem(_ text: String) -> [String: Any] {
        ["object": "block", "type": "bulleted_list_item",
         "bulleted_list_item": ["rich_text": richText(from: text)]]
    }

    private static func paragraph(_ text: String, italic: Bool = false) -> [String: Any] {
        ["object": "block", "type": "paragraph",
         "paragraph": ["rich_text": richText(from: text, italic: italic)]]
    }

    /// Découpe `**gras**` en segments alternés texte simple / texte en gras. Ne gère
    /// ni l'imbrication ni les autres emphases : ce que produit `MeetingSummary`
    /// n'en a jamais besoin.
    private static func richText(from text: String, italic: Bool = false) -> [[String: Any]] {
        let parts = text.components(separatedBy: "**")
        guard parts.count > 1 else {
            return [textSpan(text, bold: false, italic: italic)]
        }
        return parts.enumerated().compactMap { index, part in
            guard !part.isEmpty else { return nil }
            return textSpan(part, bold: index % 2 == 1, italic: italic)
        }
    }

    private static func textSpan(_ content: String, bold: Bool, italic: Bool) -> [String: Any] {
        [
            "type": "text",
            "text": ["content": content],
            "annotations": ["bold": bold, "italic": italic],
        ]
    }
}
