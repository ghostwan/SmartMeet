import Foundation
import Summarization
import Transcription

/// Stockage sur disque, un dossier par réunion :
///
///     ~/Library/Application Support/SmartMeet/Meetings/<uuid>/
///         meeting.json      métadonnées
///         segments.json     transcript structuré
///         transcript.md     transcript lisible
///         microphone.caf    piste utilisateur
///         system.caf        piste participants
///
/// Format fichier plutôt que base de données : inspectable, sauvegardable, et un
/// enregistrement interrompu reste exploitable.
public struct MeetingStore: Sendable {
    public let root: URL
    /// Types de réunion définis par l'utilisateur, nécessaires pour retrouver l'ordre
    /// de rendu d'un compte rendu déjà généré.
    public var customTemplates: [MeetingTemplate]

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    public init(root: URL? = nil, customTemplates: [MeetingTemplate] = []) {
        self.root = root ?? URL.applicationSupportDirectory
            .appending(path: "SmartMeet/Meetings")
        self.customTemplates = customTemplates
    }

    public func directory(for id: UUID) -> URL {
        root.appending(path: id.uuidString)
    }

    @discardableResult
    public func prepareDirectory(for id: UUID) throws -> URL {
        let url = directory(for: id)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    public func save(_ meeting: Meeting, segments: [TranscriptSegment]) throws {
        let directory = try prepareDirectory(for: meeting.id)
        try Self.encoder.encode(meeting)
            .write(to: directory.appending(path: "meeting.json"), options: .atomic)
        try Self.encoder.encode(segments)
            .write(to: directory.appending(path: "segments.json"), options: .atomic)
        try segments.markdown(title: meeting.title, date: meeting.startedAt)
            .write(
                to: directory.appending(path: "transcript.md"),
                atomically: true,
                encoding: .utf8
            )
        try writeSummary(meeting, to: directory)
    }

    /// Réécrit les seules métadonnées, sans toucher au transcript ni à l'audio.
    public func update(_ meeting: Meeting) throws {
        let directory = try prepareDirectory(for: meeting.id)
        try Self.encoder.encode(meeting)
            .write(to: directory.appending(path: "meeting.json"), options: .atomic)
        try writeSummary(meeting, to: directory)
    }

    /// Le markdown du compte rendu suit l'ordre de sections du type de réunion.
    private func writeSummary(_ meeting: Meeting, to directory: URL) throws {
        guard let summary = meeting.summary else { return }
        let template = MeetingTemplate.resolve(id: meeting.templateID, in: customTemplates)
        try summary.markdown(template: template).write(
            to: directory.appending(path: "summary.md"),
            atomically: true,
            encoding: .utf8
        )
    }

    public func transcriptMarkdown(for id: UUID) -> String {
        (try? String(
            contentsOf: directory(for: id).appending(path: "transcript.md"),
            encoding: .utf8
        )) ?? ""
    }

    public func loadAll() -> [Meeting] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        )) ?? []

        return contents
            .compactMap { directory -> Meeting? in
                let url = directory.appending(path: "meeting.json")
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? Self.decoder.decode(Meeting.self, from: data)
            }
            .sorted { $0.startedAt > $1.startedAt }
    }

    public func loadSegments(for id: UUID) -> [TranscriptSegment] {
        let url = directory(for: id).appending(path: "segments.json")
        guard let data = try? Data(contentsOf: url),
              let segments = try? Self.decoder.decode([TranscriptSegment].self, from: data)
        else { return [] }
        return segments
    }

    public func delete(_ id: UUID) throws {
        try FileManager.default.removeItem(at: directory(for: id))
    }
}
