import Foundation

/// Converts the markdown produced by `MeetingSummary.markdown(template:language:)`
/// into Notion blocks (the format expected by `POST /v1/pages` and `PATCH
/// .../children`).
///
/// This is not a general-purpose markdown parser: only the subset actually
/// produced by `MeetingSummary` is covered (headings `#`/`##`/`###`, bullets
/// `- `, emphasis `**bold**`, `_italic:_` lines, paragraphs). Sufficient here,
/// insufficient for arbitrary markdown.
enum MarkdownToNotionBlocks {
    /// Notion limits a call to 100 child blocks; beyond that, they must be
    /// added over several `PATCH` requests. See `NotionClient.createPage`.
    static let maxBlocksPerRequest = 100

    static func blocks(from markdown: String) -> [[String: Any]] {
        var blocks: [[String: Any]] = []
        var isFirstLine = true

        for rawLine in markdown.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            // The first line (`# Title`) would duplicate the Notion page title,
            // already set via the page's properties: it's ignored here.
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

    /// A native Notion toggle: its children stay collapsed until the reader
    /// opens it, matching Confluence's `expand` macro.
    static func toggle(title: String, children: [[String: Any]]) -> [String: Any] {
        [
            "object": "block",
            "type": "toggle",
            "toggle": [
                "rich_text": richText(from: title),
                "children": children,
            ],
        ]
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

    /// Splits `**bold**` into alternating plain text / bold text segments.
    /// Handles neither nesting nor other emphasis styles: what
    /// `MeetingSummary` produces never needs them.
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
