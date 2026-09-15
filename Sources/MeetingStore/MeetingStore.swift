import AudioCapture
import Foundation
import Summarization
import Transcription

/// On-disk storage, one folder per meeting:
///
///     ~/Library/Application Support/SmartMeet/Meetings/<uuid>/
///         meeting.json      metadata
///         segments.json     structured transcript
///         transcript.md     readable transcript
///         microphone.caf    user track
///         system.caf        participants track
///
/// File-based format rather than a database: inspectable, backupable, and an
/// interrupted recording remains usable.
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

    /// Rewrites the metadata only, without touching the transcript or the audio.
    /// `customTemplates` is taken at call time, not memorized, so that modifying a
    /// meeting type is reflected in already-saved summaries.
    public func update(_ meeting: Meeting, customTemplates: [MeetingTemplate] = []) throws {
        let directory = try prepareDirectory(for: meeting.id)
        try Self.encoder.encode(meeting)
            .write(to: directory.appending(path: "meeting.json"), options: .atomic)
        try writeSummary(meeting, customTemplates: customTemplates, to: directory)
    }

    /// The summary's markdown follows the meeting type's section order.
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

    /// Rewrites the transcript (structured segments + readable markdown) without
    /// touching the metadata or the audio. Used to retroactively apply the
    /// experimental microphone-track diarization to an already-recorded meeting.
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

    /// True if the raw audio (at least one of the two tracks) is still present.
    public func hasRawRecording(for id: UUID) -> Bool {
        let directory = directory(for: id)
        return AudioTrack.allCases.contains {
            FileManager.default.fileExists(atPath: directory.appending(path: $0.fileName).path)
        }
    }

    /// Deletes the audio and transcript of a meeting, keeping the metadata and
    /// the already-generated summary (`meeting.json`, `summary.md`). Intended for
    /// a user who has reviewed their summary, found it faithful, and no longer
    /// wants to keep the raw recording — for disk space or privacy reasons.
    ///
    /// Irreversible: without the audio, no further re-analysis (diarization) or
    /// new summary generation is possible for this meeting.
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
