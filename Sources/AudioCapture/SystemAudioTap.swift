import AVFoundation
import CoreAudio

/// Captures the audio of every process except our own, via a Core Audio process tap
/// (macOS 14.2+). No virtual driver like BlackHole.
///
/// Hard requirement: the executable must live in a signed `.app` bundle and be
/// launched by LaunchServices. Otherwise TCC won't grant `kTCCServiceAudioCapture`
/// and the tap returns **silence with no error** — verified during phase 0.
public final class SystemAudioTap: @unchecked Sendable {
    private var tapID = CoreAudioSystem.unknown
    private var aggregateID = CoreAudioSystem.unknown
    private var ioProcID: AudioDeviceIOProcID?
    private var continuation: AsyncStream<TimedAudioBuffer>.Continuation?

    public private(set) var format: AVAudioFormat?

    public init() {}

    public func start() throws -> AsyncStream<TimedAudioBuffer> {
        let output = try CoreAudioSystem.defaultOutputDevice()
        let selfID = try CoreAudioSystem.currentProcessObjectID()

        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [selfID])
        description.name = "SmartMeet"
        description.isPrivate = true        // invisible to other applications
        description.muteBehavior = .unmuted // the user keeps hearing the meeting
        try CoreAudioSystem.check(
            AudioHardwareCreateProcessTap(description, &tapID),
            "création du process tap"
        )

        let tapUID = try CoreAudioSystem.string(
            tapID, kAudioTapPropertyUID, context: "lecture de l'UID du tap"
        )

        var streamDescription = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var formatAddress = CoreAudioSystem.address(kAudioTapPropertyFormat)
        try CoreAudioSystem.check(
            AudioObjectGetPropertyData(tapID, &formatAddress, 0, nil, &size, &streamDescription),
            "lecture du format du tap"
        )
        guard let tapFormat = AVAudioFormat(streamDescription: &streamDescription) else {
            throw CoreAudioError(status: kAudio_ParamError, context: "conversion du format du tap")
        }
        format = tapFormat

        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "SmartMeet Aggregate",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: output.uid,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: output.uid]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: tapUID,
            ]],
        ]
        try CoreAudioSystem.check(
            AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregateID),
            "création du périphérique agrégé"
        )

        let (stream, continuation) = AsyncStream<TimedAudioBuffer>.makeStream(
            bufferingPolicy: .bufferingNewest(512)
        )
        self.continuation = continuation

        let queue = DispatchQueue(label: "com.smartmeet.audio.system", qos: .userInitiated)
        var procID: AudioDeviceIOProcID?
        try CoreAudioSystem.check(
            AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) {
                _, inputData, inputTime, _, _ in
                guard let source = AVAudioPCMBuffer(
                    pcmFormat: tapFormat, bufferListNoCopy: inputData, deallocator: nil
                ) else { return }
                // The IOProc reuses its buffers: we copy before returning from the callback.
                guard let copy = source.copied() else { return }
                continuation.yield(
                    TimedAudioBuffer(buffer: copy, hostTime: inputTime.pointee.mHostTime)
                )
            },
            "création de l'IOProc"
        )
        ioProcID = procID

        try CoreAudioSystem.check(
            AudioDeviceStart(aggregateID, procID),
            "démarrage du périphérique agrégé"
        )
        return stream
    }

    public func stop() {
        continuation?.finish()
        continuation = nil

        if let ioProcID {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            self.ioProcID = nil
        }
        if aggregateID != CoreAudioSystem.unknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = CoreAudioSystem.unknown
        }
        if tapID != CoreAudioSystem.unknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = CoreAudioSystem.unknown
        }
    }

    deinit { stop() }
}

extension AVAudioPCMBuffer {
    /// Deep copy: required before letting a buffer escape a real-time callback,
    /// which reuses its memory on the next cycle.
    func copied() -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength) else {
            return nil
        }
        copy.frameLength = frameLength
        let channels = Int(format.channelCount)
        let frames = Int(frameLength)

        if let source = floatChannelData, let destination = copy.floatChannelData {
            for channel in 0..<channels {
                destination[channel].update(from: source[channel], count: frames)
            }
        } else if let source = int16ChannelData, let destination = copy.int16ChannelData {
            for channel in 0..<channels {
                destination[channel].update(from: source[channel], count: frames)
            }
        } else if let source = int32ChannelData, let destination = copy.int32ChannelData {
            for channel in 0..<channels {
                destination[channel].update(from: source[channel], count: frames)
            }
        } else {
            return nil
        }
        return copy
    }
}
