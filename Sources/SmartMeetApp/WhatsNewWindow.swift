import SwiftUI

/// One dated version entry in `CHANGELOG.md`.
struct ChangelogRelease: Identifiable {
    var id: String { version }
    let version: String
    let date: String
    let body: String
}

/// A rendering unit inside one release's body: `CHANGELOG.md` only ever uses
/// `###` subsection headings, `-` bullets (possibly wrapped across several
/// lines) and the occasional bare paragraph (e.g. "Initial public
/// release.") — no nested lists, tables or images to worry about.
enum ChangelogBlock: Identifiable {
    case heading(String)
    case bullet(String)
    case paragraph(String)

    var id: String {
        switch self {
        case .heading(let text): "h:" + text
        case .bullet(let text): "b:" + text
        case .paragraph(let text): "p:" + text
        }
    }
}

/// Minimal, purpose-built parser for `CHANGELOG.md` — not a general-purpose
/// Markdown engine: it only needs to understand the handful of constructs
/// `Scripts/release.sh` and this file's own header ever produce.
enum ChangelogParser {
    /// Splits the whole file into dated releases, most recent first (as
    /// written), skipping the leading HTML comment.
    static func parse(_ text: String) -> [ChangelogRelease] {
        var content = text
        if let range = content.range(of: "-->") {
            content = String(content[range.upperBound...])
        }

        var releases: [ChangelogRelease] = []
        var header: String?
        var body: [String] = []

        func flush() {
            guard let header else { return }
            let parts = header.components(separatedBy: "—").map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            releases.append(ChangelogRelease(
                version: parts.first ?? header,
                date: parts.count > 1 ? parts[1] : "",
                body: body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            ))
        }

        for line in content.components(separatedBy: "\n") {
            if line.hasPrefix("## ") {
                flush()
                header = String(line.dropFirst(3))
                body = []
            } else if header != nil {
                body.append(line)
            }
        }
        flush()
        return releases
    }

    /// Groups a release's raw lines into headings/bullets/paragraphs,
    /// joining a bullet's wrapped continuation lines into a single string —
    /// `CHANGELOG.md` wraps long bullets at a fixed column, which would
    /// otherwise show up as several short, oddly-broken lines.
    static func blocks(from body: String) -> [ChangelogBlock] {
        var blocks: [ChangelogBlock] = []
        var bulletLines: [String] = []
        var paragraphLines: [String] = []

        func flushBullet() {
            guard !bulletLines.isEmpty else { return }
            blocks.append(.bullet(bulletLines.joined(separator: " ")))
            bulletLines = []
        }
        func flushParagraph() {
            guard !paragraphLines.isEmpty else { return }
            blocks.append(.paragraph(paragraphLines.joined(separator: " ")))
            paragraphLines = []
        }

        for rawLine in body.components(separatedBy: "\n") {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if rawLine.hasPrefix("### ") {
                flushBullet(); flushParagraph()
                blocks.append(.heading(String(rawLine.dropFirst(4))))
            } else if rawLine.hasPrefix("- ") {
                flushBullet(); flushParagraph()
                bulletLines = [String(rawLine.dropFirst(2))]
            } else if trimmed.isEmpty {
                flushBullet(); flushParagraph()
            } else if !bulletLines.isEmpty {
                bulletLines.append(trimmed)
            } else {
                paragraphLines.append(trimmed)
            }
        }
        flushBullet(); flushParagraph()
        return blocks
    }
}

/// Shows the bundled `CHANGELOG.md`, most recent release first. Deliberately
/// entirely in English — including every string literal in this file —
/// regardless of the app's own localized UI: the notes themselves are only
/// ever written in English (see AGENTS.md), so translating the chrome
/// around them but not their content would be more confusing than helpful.
struct WhatsNewWindow: View {
    @Environment(\.dismiss) private var dismiss
    @State private var releases: [ChangelogRelease] = []

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("What's New in SmartMeet").font(.headline)
                Spacer()
                Text("v\(AppVersion.current)").font(.caption).foregroundStyle(.secondary)
                Button("Close") { dismiss() }
            }
            .padding()
            Divider()

            if releases.isEmpty {
                ContentUnavailableView(
                    "No changelog available",
                    systemImage: "doc.text",
                    description: Text("CHANGELOG.md wasn't found in this build.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        ForEach(releases) { release in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text(release.version).font(.title3.weight(.bold))
                                    if !release.date.isEmpty {
                                        Text(release.date).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                VStack(alignment: .leading, spacing: 6) {
                                    ForEach(ChangelogParser.blocks(from: release.body)) { block in
                                        blockView(block)
                                    }
                                }
                            }
                            if release.id != releases.last?.id {
                                Divider()
                            }
                        }
                    }
                    .padding()
                }
            }
        }
        .frame(minWidth: 520, minHeight: 460)
        .onAppear { releases = ChangelogParser.parse(Self.loadChangelog()) }
    }

    @ViewBuilder
    private func blockView(_ block: ChangelogBlock) -> some View {
        switch block {
        case .heading(let text):
            Text(text)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 4)
        case .bullet(let text):
            HStack(alignment: .top, spacing: 6) {
                Text("•")
                markdownText(text)
            }
        case .paragraph(let text):
            markdownText(text)
        }
    }

    /// Renders inline emphasis (`**bold**`, `` `code` ``…) when the text
    /// parses as Markdown, falling back to the raw string otherwise — a
    /// malformed inline span shouldn't take down the whole window.
    private func markdownText(_ text: String) -> Text {
        if let attributed = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return Text(attributed)
        }
        return Text(text)
    }

    private static func loadChangelog() -> String {
        guard let url = Bundle.main.url(forResource: "CHANGELOG", withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return "" }
        return text
    }
}
