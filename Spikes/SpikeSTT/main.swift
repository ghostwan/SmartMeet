// Spike 2 — Prouver la transcription on-device et la diarisation par piste.
//   entrée  : les deux .caf du spike 1
//   sortie  : un transcript markdown fusionné, segments [Moi] / [Participants]
// Critère de succès : texte FR lisible, segments horodatés, ordre chronologique correct.

import AVFoundation
import Foundation
import Speech

// MARK: - Modèle

struct Segment {
    let speaker: String
    let start: TimeInterval
    let end: TimeInterval
    let text: String
}

func timecode(_ seconds: TimeInterval) -> String {
    let total = Int(seconds.rounded())
    return String(format: "%02d:%02d", total / 60, total % 60)
}

/// Le bloc d'AVAudioConverter doit rendre le buffer une seule fois ; un `var` capturé
/// déclenche un diagnostic de concurrence Swift 6.
final class InputBox: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?
    init(buffer: AVAudioPCMBuffer) { self.buffer = buffer }
    func take() -> AVAudioPCMBuffer? {
        defer { buffer = nil }
        return buffer
    }
}

// MARK: - Sortie

let arguments = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-psn_") }
let outputDirectory = arguments.first.map { URL(filePath: $0) }
    ?? URL.currentDirectory().appending(path: "spike-output")
let localeIdentifier = arguments.dropFirst().first ?? "fr-FR"
let reportURL = outputDirectory.appending(path: "transcript-report.txt")
try? FileManager.default.removeItem(at: reportURL)

func emit(_ lines: String...) {
    lines.forEach { print($0) }
    let existing = (try? String(contentsOf: reportURL, encoding: .utf8)) ?? ""
    try? (existing + lines.joined(separator: "\n") + "\n")
        .write(to: reportURL, atomically: true, encoding: .utf8)
}

// Termes métier injectés dans l'analyseur : ils ne sont pas dans le lexique général.
let vocabulary = ["Crowdin", "ACME", "Confluence", "Jira", "ACME", "SmartMeet"]

// MARK: - Assets de locale

func ensureAssets(for transcriber: SpeechTranscriber, locale: Locale) async throws {
    let status = await AssetInventory.status(forModules: [transcriber])
    emit("  assets \(locale.identifier(.bcp47)) : \(status)")
    guard status != .installed else { return }

    guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else {
        emit("  ⚠️ aucune installation disponible pour cette locale")
        return
    }
    emit("  téléchargement des assets…")
    let started = Date()
    try await request.downloadAndInstall()
    emit("  assets installés en \(Int(Date().timeIntervalSince(started))) s")
}

// MARK: - Transcription d'un fichier

func transcribe(fileAt url: URL, speaker: String, locale: Locale) async throws -> ([Segment], Int, Int) {
    let transcriber = SpeechTranscriber(locale: locale, preset: .timeIndexedProgressiveTranscription)

    guard SpeechTranscriber.isAvailable else {
        throw NSError(domain: "spike", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "SpeechTranscriber indisponible"])
    }
    try await ensureAssets(for: transcriber, locale: locale)

    let analyzer = SpeechAnalyzer(modules: [transcriber])
    let file = try AVAudioFile(forReading: url)

    // Le transcriber impose son propre format : on convertit depuis celui du fichier.
    guard let analysisFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
        compatibleWith: [transcriber], considering: file.processingFormat)
    else {
        throw NSError(domain: "spike", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "aucun format d'analyse compatible"])
    }
    guard let converter = AVAudioConverter(from: file.processingFormat, to: analysisFormat) else {
        throw NSError(domain: "spike", code: 3,
                      userInfo: [NSLocalizedDescriptionKey: "conversion \(file.processingFormat) → \(analysisFormat)"])
    }

    // Collecte des résultats finalisés, en parallèle de l'alimentation en audio.
    // Le preset progressif émet aussi des résultats volatils (le texte en cours de
    // construction, utile pour l'affichage live) : on ne garde que les finaux.
    let collector = Task { () -> ([Segment], Int, Int) in
        var segments: [Segment] = []
        var volatileCount = 0
        var finalCount = 0
        for try await result in transcriber.results {
            if result.isFinal { finalCount += 1 } else { volatileCount += 1 }
            guard result.isFinal else { continue }
            let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            segments.append(Segment(speaker: speaker,
                                    start: result.range.start.seconds,
                                    end: result.range.end.seconds,
                                    text: text))
        }
        return (segments, volatileCount, finalCount)
    }

    // Vocabulaire métier : sans ça « Crowdin » devient « négociationale ».
    let context = AnalysisContext()
    context.contextualStrings = [.general: vocabulary]
    try await analyzer.setContext(context)

    // Lecture intégrale puis conversion en une seule passe. La conversion par blocs
    // perdait la moitié des frames : à chaque bloc le convertisseur terminait en
    // `inputRanDry` et jetait l'état interne du rééchantillonneur.
    guard let fileBuffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                            frameCapacity: AVAudioFrameCount(file.length)) else {
        throw NSError(domain: "spike", code: 4,
                      userInfo: [NSLocalizedDescriptionKey: "allocation du buffer de lecture"])
    }
    try file.read(into: fileBuffer)

    let ratio = analysisFormat.sampleRate / file.processingFormat.sampleRate
    let capacity = AVAudioFrameCount(Double(fileBuffer.frameLength) * ratio) + 4096
    guard let converted = AVAudioPCMBuffer(pcmFormat: analysisFormat, frameCapacity: capacity) else {
        throw NSError(domain: "spike", code: 5,
                      userInfo: [NSLocalizedDescriptionKey: "allocation du buffer d'analyse"])
    }

    let box = InputBox(buffer: fileBuffer)
    var conversionError: NSError?
    converter.convert(to: converted, error: &conversionError) { _, status in
        guard let pending = box.take() else { status.pointee = .endOfStream; return nil }
        status.pointee = .haveData
        return pending
    }
    if let conversionError { throw conversionError }
    emit("  \(file.length) frames lues → \(converted.frameLength) frames à \(Int(analysisFormat.sampleRate)) Hz "
        + "(attendu ~\(Int(Double(file.length) * ratio)))")

    let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()

    // Alimentation en tâche de fond : `analyzeSequence` consomme le flux et ne rend
    // la main qu'une fois tout l'audio analysé. C'est l'API batch — `start()` seul
    // rendait la main avant que l'analyseur ait tout digéré, d'où des transcripts
    // tronqués de façon non déterministe.
    let feeder = Task {
        defer { continuation.finish() }
        // Découpage du buffer converti en tranches, pour rester proche du
        // fonctionnement temps réel de l'app.
        // Découpage en tranches, pour rester proche du fonctionnement temps réel.
        let chunkSize: AVAudioFrameCount = 16384
        var offset: AVAudioFrameCount = 0
        while offset < converted.frameLength {
            let length = min(chunkSize, converted.frameLength - offset)
            guard let slice = AVAudioPCMBuffer(pcmFormat: analysisFormat, frameCapacity: length),
                  let source = converted.int16ChannelData,
                  let destination = slice.int16ChannelData else { break }
            for channel in 0..<Int(analysisFormat.channelCount) {
                destination[channel].update(from: source[channel] + Int(offset), count: Int(length))
            }
            slice.frameLength = length
            // Pas de bufferStartTime : l'analyseur maintient sa propre horloge, qui
            // démarre à zéro — soit exactement le début de la piste.
            continuation.yield(AnalyzerInput(buffer: slice))
            offset += length
        }
        return AVAudioFramePosition(offset)
    }

    _ = try await analyzer.analyzeSequence(stream)
    let position = try await feeder.value
    try await analyzer.finalizeAndFinishThroughEndOfInput()

    emit("  \(position) frames envoyées, format d'analyse \(Int(analysisFormat.sampleRate)) Hz / \(analysisFormat.channelCount) canaux")
    continuation.finish()
    try await analyzer.finalizeAndFinishThroughEndOfInput()
    return try await collector.value
}

// MARK: - Main

let locale = Locale(identifier: localeIdentifier)
emit("Spike 2 — transcription \(localeIdentifier) — \(Date().formatted())")

let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale)
emit("  locale supportée : \(supported?.identifier(.bcp47) ?? "non — repli sur le défaut")")
let effectiveLocale = supported ?? locale

let tracks = [
    ("Moi", outputDirectory.appending(path: "mic.caf")),
    ("Participants", outputDirectory.appending(path: "system.caf")),
]

var allSegments: [Segment] = []
for (speaker, url) in tracks {
    guard FileManager.default.fileExists(atPath: url.path) else {
        emit("❌ piste manquante : \(url.lastPathComponent) — lance d'abord le spike 1")
        exit(1)
    }
    emit("", "[piste \(speaker)] \(url.lastPathComponent)")
    let started = Date()
    do {
        let (segments, volatileCount, finalCount) = try await transcribe(fileAt: url, speaker: speaker, locale: effectiveLocale)
        let elapsed = Date().timeIntervalSince(started)
        emit("  \(finalCount) résultats finaux, \(volatileCount) volatils → \(segments.count) segments en \(String(format: "%.1f", elapsed)) s")
        allSegments.append(contentsOf: segments)
    } catch {
        emit("  ❌ \(error.localizedDescription)")
    }
}

// Fusion chronologique des deux pistes : la diarisation « gratuite ».
allSegments.sort { $0.start < $1.start }

var markdown = "# Transcript\n\n"
for segment in allSegments {
    markdown += "**[\(timecode(segment.start))] \(segment.speaker) :** \(segment.text)\n\n"
}
let markdownURL = outputDirectory.appending(path: "transcript.md")
try? markdown.write(to: markdownURL, atomically: true, encoding: .utf8)

emit("", "— Résultat —")
emit(allSegments.isEmpty ? "❌ aucun segment transcrit" : "✅ \(allSegments.count) segments fusionnés → \(markdownURL.path)")
for segment in allSegments.prefix(20) {
    emit("  [\(timecode(segment.start))] \(segment.speaker) : \(segment.text)")
}
