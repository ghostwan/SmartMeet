// Spike 1 — Prouver la capture double piste :
//   piste A : audio système (Core Audio process tap, macOS 14.2+)
//   piste B : micro (AVAudioEngine)
// Critère de succès : deux .caf audibles et alignés temporellement.

import AVFoundation
import CoreAudio
import Foundation

// MARK: - Helpers Core Audio

struct CAError: Error, CustomStringConvertible {
    let status: OSStatus
    let context: String
    var description: String {
        let code = withUnsafeBytes(of: status.bigEndian) { raw -> String in
            let chars = raw.map { Character(UnicodeScalar($0)) }
            let s = String(chars)
            return s.allSatisfy { $0.isLetter || $0.isNumber || $0 == " " } ? "'\(s)'" : "\(status)"
        }
        return "\(context) a échoué : \(code)"
    }
}

let systemObject = AudioObjectID(kAudioObjectSystemObject)
let unknownObject = AudioObjectID(kAudioObjectUnknown)

func check(_ status: OSStatus, _ context: String) throws {
    guard status == noErr else { throw CAError(status: status, context: context) }
}

func address(_ selector: AudioObjectPropertySelector,
             _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal)
    -> AudioObjectPropertyAddress
{
    AudioObjectPropertyAddress(mSelector: selector,
                               mScope: scope,
                               mElement: kAudioObjectPropertyElementMain)
}

func readProperty<T>(_ objectID: AudioObjectID,
                     _ selector: AudioObjectPropertySelector,
                     scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                     default defaultValue: T,
                     context: String) throws -> T
{
    var addr = address(selector, scope)
    var size = UInt32(MemoryLayout<T>.size)
    var value = defaultValue
    try check(AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, &value), context)
    return value
}

func readStringProperty(_ objectID: AudioObjectID,
                        _ selector: AudioObjectPropertySelector,
                        context: String) throws -> String
{
    var addr = address(selector)
    var size = UInt32(MemoryLayout<CFString?>.size)
    var value: CFString? = nil
    try check(AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, &value), context)
    guard let value else { throw CAError(status: -1, context: context) }
    return value as String
}

/// AudioObjectID du process courant, pour l'exclure du tap (sinon larsen).
func currentProcessAudioObjectID() throws -> AudioObjectID {
    var pid = getpid()
    var addr = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
    var objectID = unknownObject
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    try check(AudioObjectGetPropertyData(systemObject,
                                         &addr,
                                         UInt32(MemoryLayout<pid_t>.size),
                                         &pid,
                                         &size,
                                         &objectID),
              "traduction PID → AudioObject")
    return objectID
}

// MARK: - Capture audio système

final class SystemAudioTap {
    private var tapID = unknownObject
    private var aggregateID = unknownObject
    private var ioProcID: AudioDeviceIOProcID?
    private var file: AVAudioFile?
    private var format: AVAudioFormat?
    private(set) var framesWritten: AVAudioFramePosition = 0

    func start(writingTo url: URL) throws {
        // 1. Périphérique de sortie par défaut : sert d'horloge à l'agrégat.
        let outputDeviceID: AudioObjectID = try readProperty(
            systemObject,
            kAudioHardwarePropertyDefaultOutputDevice,
            default: unknownObject,
            context: "lecture du périphérique de sortie par défaut")
        let outputUID = try readStringProperty(outputDeviceID,
                                               kAudioDevicePropertyDeviceUID,
                                               context: "lecture de l'UID de sortie")
        print("  périphérique de sortie : \(outputUID)")

        // 2. Tap global de tous les process sauf nous-mêmes.
        let selfID = try currentProcessAudioObjectID()
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [selfID])
        description.name = "SmartMeet Spike Tap"
        description.isPrivate = true          // invisible des autres apps
        description.muteBehavior = .unmuted   // on continue d'entendre la réunion
        try check(AudioHardwareCreateProcessTap(description, &tapID), "création du process tap")
        print("  tap créé : id=\(tapID)")

        let tapUID = try readStringProperty(tapID, kAudioTapPropertyUID, context: "lecture de l'UID du tap")

        // 3. Format natif du tap.
        var asbd = AudioStreamBasicDescription()
        var asbdSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var asbdAddr = address(kAudioTapPropertyFormat)
        try check(AudioObjectGetPropertyData(tapID, &asbdAddr, 0, nil, &asbdSize, &asbd),
                  "lecture du format du tap")
        guard let format = AVAudioFormat(streamDescription: &asbd) else {
            throw CAError(status: -1, context: "conversion du format du tap")
        }
        self.format = format
        print("  format du tap : \(Int(format.sampleRate)) Hz, \(format.channelCount) canaux")

        // 4. Périphérique agrégé privé contenant le tap.
        let aggregateUID = UUID().uuidString
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "SmartMeet Spike Aggregate",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: tapUID,
            ]],
        ]
        try check(AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregateID),
                  "création du périphérique agrégé")
        print("  agrégat créé : id=\(aggregateID)")

        // 5. Fichier de sortie au format natif du tap.
        let audioFile = try AVAudioFile(forWriting: url,
                                        settings: format.settings,
                                        commonFormat: .pcmFormatFloat32,
                                        interleaved: format.isInterleaved)
        self.file = audioFile

        // 6. IOProc : recopie les buffers d'entrée dans le fichier.
        let queue = DispatchQueue(label: "com.smartmeet.spike.systemtap")
        var procID: AudioDeviceIOProcID?
        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) {
            [weak self] _, inputData, _, _, _ in
            guard let self, let format = self.format, let file = self.file else { return }
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                                bufferListNoCopy: inputData,
                                                deallocator: nil) else { return }
            do {
                try file.write(from: buffer)
                self.framesWritten += AVAudioFramePosition(buffer.frameLength)
            } catch {
                print("  ⚠️ écriture piste système : \(error)")
            }
        }, "création de l'IOProc")
        ioProcID = procID

        try check(AudioDeviceStart(aggregateID, procID), "démarrage de l'agrégat")
    }

    func stop() {
        if let ioProcID {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        if aggregateID != unknownObject {
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != unknownObject {
            AudioHardwareDestroyProcessTap(tapID)
        }
        file = nil
    }
}

// MARK: - Capture micro

final class MicRecorder {
    private let engine = AVAudioEngine()
    private var file: AVAudioFile?
    private(set) var framesWritten: AVAudioFramePosition = 0

    func start(writingTo url: URL) throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        print("  format du micro : \(Int(format.sampleRate)) Hz, \(format.channelCount) canaux")

        let audioFile = try AVAudioFile(forWriting: url,
                                        settings: format.settings,
                                        commonFormat: .pcmFormatFloat32,
                                        interleaved: format.isInterleaved)
        file = audioFile

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            do {
                try audioFile.write(from: buffer)
                self.framesWritten += AVAudioFramePosition(buffer.frameLength)
            } catch {
                print("  ⚠️ écriture piste micro : \(error)")
            }
        }
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        file = nil
    }
}

// MARK: - Main

func requestMicrophoneAccess() async -> Bool {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized: return true
    case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
    default: return false
    }
}

// Usage : SpikeTap [durée] [dossier de sortie]
// Le dossier est explicite car lancé via `open`, le répertoire courant est « / ».
let arguments = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-psn_") }
let duration = arguments.first.flatMap(Double.init) ?? 10
let outputDirectory = arguments.dropFirst().first.map { URL(filePath: $0) }
    ?? URL.currentDirectory().appending(path: "spike-output")
try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

let systemURL = outputDirectory.appending(path: "system.caf")
let micURL = outputDirectory.appending(path: "mic.caf")
let reportURL = outputDirectory.appending(path: "report.txt")
for url in [systemURL, micURL, reportURL] {
    try? FileManager.default.removeItem(at: url)
}

/// Lancé via `open`, stdout part dans le vide : tout doit atterrir dans report.txt.
func emit(_ lines: [String]) {
    lines.forEach { print($0) }
    let existing = (try? String(contentsOf: reportURL, encoding: .utf8)) ?? ""
    try? (existing + lines.joined(separator: "\n") + "\n")
        .write(to: reportURL, atomically: true, encoding: .utf8)
}

emit(["Spike 1 — capture double piste (\(Int(duration)) s) — \(Date().formatted())"])

guard await requestMicrophoneAccess() else {
    emit(["❌ accès micro refusé — Réglages › Confidentialité › Microphone"])
    exit(1)
}
emit(["✅ accès micro accordé"])

let systemTap = SystemAudioTap()
let mic = MicRecorder()

do {
    emit(["[piste système]"])
    try systemTap.start(writingTo: systemURL)
    emit(["[piste micro]"])
    try mic.start(writingTo: micURL)
} catch {
    emit(["❌ \(error)"])
    systemTap.stop()
    mic.stop()
    exit(1)
}

print("\n▶︎ Enregistrement… fais jouer du son (réunion, vidéo) ET parle dans le micro.")
try await Task.sleep(for: .seconds(duration))

systemTap.stop()
mic.stop()

var results: [String] = ["— Résultat —"]
for (label, url, frames) in [("système", systemURL, systemTap.framesWritten),
                             ("micro", micURL, mic.framesWritten)] {
    let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    let status = frames > 0 ? "✅" : "❌ aucune frame capturée"
    results.append("\(status) piste \(label) : \(frames) frames, \(size / 1024) Ko → \(url.path)")
}
emit(results)
