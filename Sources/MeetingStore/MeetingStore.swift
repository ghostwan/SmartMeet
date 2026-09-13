import AudioCapture
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

    public init(root: URL? = nil) {
        self.root = root ?? URL.applicationSupportDirectory
            .appending(path: "SmartMeet/Meetings")
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

    public func save(
        _ meeting: Meeting, segments: [TranscriptSegment], customTemplates: [MeetingTemplate] = []
    ) throws {
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
        try writeSummary(meeting, customTemplates: customTemplates, to: directory)
    }

    /// Réécrit les seules métadonnées, sans toucher au transcript ni à l'audio.
    /// `customTemplates` est pris au moment de l'appel, pas mémorisé, pour que la
    /// modification d'un type de réunion se répercute sur les comptes rendus déjà
    /// enregistrés.
    public func update(_ meeting: Meeting, customTemplates: [MeetingTemplate] = []) throws {
        let directory = try prepareDirectory(for: meeting.id)
        try Self.encoder.encode(meeting)
            .write(to: directory.appending(path: "meeting.json"), options: .atomic)
        try writeSummary(meeting, customTemplates: customTemplates, to: directory)
    }

    /// Le markdown du compte rendu suit l'ordre de sections du type de réunion.
    private func writeSummary(
        _ meeting: Meeting, customTemplates: [MeetingTemplate], to directory: URL
    ) throws {
        guard let summary = meeting.summary else { return }
        let template = MeetingTemplate.resolve(id: meeting.templateID, in: customTemplates)
        try summary.markdown(template: template, language: meeting.outputLanguage).write(
            to: directory.appending(path: "summary.md"),
            atomically: true,
            encoding: .utf8
        )
    }

    /// Réécrit le transcript (segments structurés + markdown lisible) sans toucher
    /// aux métadonnées ni à l'audio. Utilisé pour appliquer a posteriori la
    /// diarisation expérimentale de la piste micro sur une réunion déjà enregistrée.
    public func updateSegments(
        _ segments: [TranscriptSegment], for id: UUID, title: String, date: Date
    ) throws {
        let directory = try prepareDirectory(for: id)
        try Self.encoder.encode(segments)
            .write(to: directory.appending(path: "segments.json"), options: .atomic)
        try segments.markdown(title: title, date: date)
            .write(
                to: directory.appending(path: "transcript.md"),
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

    /// Vrai si l'audio brut (au moins une des deux pistes) est encore présent.
    public func hasRawRecording(for id: UUID) -> Bool {
        let directory = directory(for: id)
        return AudioTrack.allCases.contains {
            FileManager.default.fileExists(atPath: directory.appending(path: $0.fileName).path)
        }
    }

    /// Supprime l'audio et le transcript d'une réunion, en conservant les métadonnées
    /// et le compte rendu déjà généré (`meeting.json`, `summary.md`). Pensé pour
    /// l'utilisateur qui a relu son compte rendu, l'a jugé fidèle, et ne veut plus
    /// conserver l'enregistrement brut — pour l'espace disque ou la confidentialité.
    ///
    /// Irréversible : sans l'audio, plus de réanalyse (diarisation) ni de nouvelle
    /// génération de compte rendu possible pour cette réunion.
    public func deleteRawRecording(for id: UUID) throws {
        let directory = directory(for: id)
        let names = AudioTrack.allCases.map(\.fileName) + ["segments.json", "transcript.md"]
        for name in names {
            let url = directory.appending(path: name)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            try FileManager.default.removeItem(at: url)
        }
    }
}
