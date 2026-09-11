import CoreAudio
import Foundation

/// Application de visioconférence identifiée comme active.
public struct ConferencingApp: Sendable, Equatable, Identifiable {
    public let bundleID: String
    public let name: String
    /// Vrai pour les applications dédiées à la visioconférence. Un navigateur qui
    /// capte le micro est un indice plus faible : ce peut être une réunion web comme
    /// un simple test de micro.
    public let isDedicated: Bool

    public var id: String { bundleID }

    public init(bundleID: String, name: String, isDedicated: Bool) {
        self.bundleID = bundleID
        self.name = name
        self.isDedicated = isDedicated
    }

    public static let known: [String: (name: String, dedicated: Bool)] = [
        "com.microsoft.teams": ("Microsoft Teams", true),
        "com.microsoft.teams2": ("Microsoft Teams", true),
        "us.zoom.xos": ("Zoom", true),
        "com.cisco.webexmeetingsapp": ("Webex", true),
        "Cisco-Systems.Spark": ("Webex", true),
        "com.tinyspeck.slackmacgap": ("Slack", true),
        "com.hnc.Discord": ("Discord", true),
        "com.apple.FaceTime": ("FaceTime", true),
        "com.google.Chrome": ("Chrome", false),
        "com.google.Chrome.beta": ("Chrome", false),
        "com.microsoft.edgemac": ("Edge", false),
        "com.apple.Safari": ("Safari", false),
        "org.mozilla.firefox": ("Firefox", false),
        "company.thebrowser.Browser": ("Arc", false),
    ]
}

/// Repère les applications de visioconférence en train de capter le micro.
///
/// Le calendrier seul ne suffit pas : une réunion peut être annulée, décalée, ou
/// tenue sans invitation. Le micro qui s'allume dans Teams est le signal le plus
/// franc qu'une réunion a réellement commencé.
public enum ConferencingDetector {
    /// Applications de visioconférence captant actuellement l'entrée audio.
    ///
    /// SmartMeet s'exclut lui-même : il capte le micro pendant un enregistrement, et
    /// se prendrait sinon pour une réunion en cours.
    public static func activeApps() -> [ConferencingApp] {
        let ownBundleID = Bundle.main.bundleIdentifier
        let detected: [ConferencingApp] = processObjectIDs().compactMap { objectID in
            guard isRunningInput(objectID),
                  let bundleID = bundleID(of: objectID),
                  bundleID != ownBundleID,
                  let known = ConferencingApp.known[bundleID]
            else { return nil }
            return ConferencingApp(
                bundleID: bundleID, name: known.name, isDedicated: known.dedicated
            )
        }
        // Une même application expose plusieurs objets audio : une entrée suffit.
        return detected.reduce(into: [ConferencingApp]()) { result, app in
            if !result.contains(where: { $0.name == app.name }) { result.append(app) }
        }
    }

    /// Tous les process captant l'entrée audio, connus ou non. Sert au diagnostic.
    public static func allInputCapturingBundleIDs() -> [String] {
        processObjectIDs()
            .filter(isRunningInput)
            .compactMap(bundleID(of:))
    }

    private static func processObjectIDs() -> [AudioObjectID] {
        var address = CoreAudioSystem.address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            CoreAudioSystem.object, &address, 0, nil, &size
        ) == noErr, size > 0 else { return [] }

        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var identifiers = [AudioObjectID](repeating: CoreAudioSystem.unknown, count: count)
        guard AudioObjectGetPropertyData(
            CoreAudioSystem.object, &address, 0, nil, &size, &identifiers
        ) == noErr else { return [] }
        return identifiers
    }

    private static func isRunningInput(_ objectID: AudioObjectID) -> Bool {
        (try? CoreAudioSystem.value(
            objectID,
            kAudioProcessPropertyIsRunningInput,
            default: UInt32(0),
            context: "lecture de l'état d'entrée du process"
        )) == 1
    }

    private static func bundleID(of objectID: AudioObjectID) -> String? {
        try? CoreAudioSystem.string(
            objectID, kAudioProcessPropertyBundleID, context: "lecture du bundle ID"
        )
    }
}
