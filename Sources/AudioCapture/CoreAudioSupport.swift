import CoreAudio
import Foundation

/// Erreur Core Audio avec son code à quatre caractères, bien plus lisible que l'entier brut.
public struct CoreAudioError: LocalizedError {
    public let status: OSStatus
    public let context: String

    public init(status: OSStatus, context: String) {
        self.status = status
        self.context = context
    }

    public var errorDescription: String? {
        let code = withUnsafeBytes(of: status.bigEndian) { raw -> String in
            let text = String(raw.map { Character(UnicodeScalar($0)) })
            return text.allSatisfy { $0.isLetter || $0.isNumber || $0 == " " } ? "'\(text)'" : "\(status)"
        }
        return "\(context) a échoué (\(code))"
    }
}

enum CoreAudioSystem {
    static let object = AudioObjectID(kAudioObjectSystemObject)
    static let unknown = AudioObjectID(kAudioObjectUnknown)

    static func check(_ status: OSStatus, _ context: String) throws {
        guard status == noErr else { throw CoreAudioError(status: status, context: context) }
    }

    static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    static func value<T>(
        _ objectID: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        default defaultValue: T,
        context: String
    ) throws -> T {
        var propertyAddress = address(selector)
        var size = UInt32(MemoryLayout<T>.size)
        var value = defaultValue
        try check(
            AudioObjectGetPropertyData(objectID, &propertyAddress, 0, nil, &size, &value),
            context
        )
        return value
    }

    static func string(
        _ objectID: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        context: String
    ) throws -> String {
        var propertyAddress = address(selector)
        var size = UInt32(MemoryLayout<CFString?>.size)
        // Core Audio dépose une CFStringRef possédée par l'appelant : on passe par
        // Unmanaged pour en reprendre la propriété sans fuite.
        var cfValue: Unmanaged<CFString>?
        try check(
            withUnsafeMutablePointer(to: &cfValue) { pointer in
                AudioObjectGetPropertyData(objectID, &propertyAddress, 0, nil, &size, pointer)
            },
            context
        )
        guard let value = cfValue?.takeRetainedValue() else {
            throw CoreAudioError(status: kAudio_ParamError, context: context)
        }
        return value as String
    }

    /// Périphérique de sortie courant, qui sert d'horloge au périphérique agrégé.
    static func defaultOutputDevice() throws -> (id: AudioObjectID, uid: String) {
        let deviceID: AudioObjectID = try value(
            object,
            kAudioHardwarePropertyDefaultOutputDevice,
            default: unknown,
            context: "lecture du périphérique de sortie par défaut"
        )
        let uid = try string(deviceID, kAudioDevicePropertyDeviceUID, context: "lecture de l'UID de sortie")
        return (deviceID, uid)
    }

    /// AudioObjectID du process courant, pour l'exclure du tap et éviter un larsen.
    static func currentProcessObjectID() throws -> AudioObjectID {
        var pid = getpid()
        var propertyAddress = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var objectID = unknown
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        try check(
            AudioObjectGetPropertyData(
                object,
                &propertyAddress,
                UInt32(MemoryLayout<pid_t>.size),
                &pid,
                &size,
                &objectID
            ),
            "traduction PID → AudioObject"
        )
        return objectID
    }
}
