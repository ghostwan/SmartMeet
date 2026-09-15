import CoreAudio
import Foundation

/// Video conferencing application detected as currently active.
public struct ConferencingApp: Sendable, Equatable, Identifiable {
    public let bundleID: String
    public let name: String
    /// True for applications dedicated to video conferencing. A browser that
    /// captures the microphone is a weaker signal: it could be a web meeting as
    /// much as a simple mic test.
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

/// Detects video conferencing applications currently capturing the microphone.
///
/// The calendar alone isn't enough: a meeting can be cancelled, rescheduled, or
/// held without an invite. The microphone lighting up in Teams is the most
/// straightforward signal that a meeting has actually started.
public enum ConferencingDetector {
    /// Video conferencing applications currently capturing audio input.
    ///
    /// SmartMeet excludes itself: it captures the microphone during a recording,
    /// and would otherwise mistake itself for an ongoing meeting.
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
        // The same application can expose several audio objects: one match is enough.
        return detected.reduce(into: [ConferencingApp]()) { result, app in
            if !result.contains(where: { $0.name == app.name }) { result.append(app) }
        }
    }

    /// All processes capturing audio input, known or not. Used for diagnostics.
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
