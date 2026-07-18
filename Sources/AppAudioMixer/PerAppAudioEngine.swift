import Foundation
import CoreAudio
import AudioToolbox
import Accelerate

enum EngineError: LocalizedError {
    case tapCreationFailed(OSStatus)
    case aggregateCreationFailed(OSStatus)
    case ioProcFailed(OSStatus)
    case noDefaultOutput

    var errorDescription: String? {
        switch self {
        case .tapCreationFailed(let s):
            return "Couldn't tap the app's audio (status \(s)). Check System Settings > Privacy & Security > Screen & System Audio Recording."
        case .aggregateCreationFailed(let s):
            return "Couldn't create routing device (status \(s))."
        case .ioProcFailed(let s):
            return "Couldn't start audio processing (status \(s))."
        case .noDefaultOutput:
            return "No default output device found."
        }
    }
}

/// Controls the volume of a single process.
///
/// How it works:
/// 1. A Core Audio *process tap* is created on the target process with
///    `.mutedWhenTapped`, which silences the app's normal output while we
///    are tapping it.
/// 2. A private *aggregate device* is created that contains the tap (as its
///    input side) and the current default output device (as its output side).
/// 3. An IOProc on that aggregate copies tap input -> hardware output every
///    audio cycle, multiplying samples by the current gain. Gain 1.0 is
///    transparent pass-through; 0.0 is mute; up to 2.0 is boost.
final class PerAppAudioEngine {
    let processObjectID: AudioObjectID

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private let ioQueue = DispatchQueue(label: "AppAudioMixer.io", qos: .userInteractive)

    // Written from the UI thread, read on the audio thread. A raw pointer
    // avoids Swift exclusivity checks; a torn read of a Float is harmless
    // here (worst case: one buffer at a slightly stale gain).
    private let gainPtr: UnsafeMutablePointer<Float>
    private var stopped = false

    var volume: Float {
        get { gainPtr.pointee }
        set { gainPtr.pointee = max(0.0, min(newValue, 2.0)) }
    }

    init(processObjectID: AudioObjectID, initialVolume: Float = 1.0) throws {
        self.processObjectID = processObjectID
        gainPtr = .allocate(capacity: 1)
        gainPtr.initialize(to: max(0.0, min(initialVolume, 2.0)))
        do {
            try setUp()
        } catch {
            stop()
            throw error
        }
    }

    deinit {
        stop()
        gainPtr.deallocate()
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        if let proc = ioProcID, aggregateID != AudioObjectID(kAudioObjectUnknown) {
            AudioDeviceStop(aggregateID, proc)
            AudioDeviceDestroyIOProcID(aggregateID, proc)
        }
        ioProcID = nil
        if aggregateID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    // MARK: - Setup

    private func setUp() throws {
        // 1. Tap the process; mute its direct output while tapped.
        let description = CATapDescription(stereoMixdownOfProcesses: [processObjectID])
        description.name = "AppAudioMixer tap (\(processObjectID))"
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped

        var tap = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &tap)
        guard status == noErr, tap != AudioObjectID(kAudioObjectUnknown) else {
            throw EngineError.tapCreationFailed(status)
        }
        tapID = tap

        // 2. Private aggregate: tap on the input side, default output on the
        //    output side, clocked by the hardware device.
        let outputUID = try Self.defaultOutputDeviceUID()
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "AppAudioMixer \(processObjectID)",
            kAudioAggregateDeviceUIDKey: "AppAudioMixer-\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: description.uuid.uuidString
                ]
            ]
        ]

        var aggregate = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregate)
        guard status == noErr, aggregate != AudioObjectID(kAudioObjectUnknown) else {
            throw EngineError.aggregateCreationFailed(status)
        }
        aggregateID = aggregate

        // 3. IOProc: copy tap input to hardware output with gain applied.
        let gain = gainPtr
        status = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, ioQueue) {
            _, inInputData, _, outOutputData, _ in
            Self.render(input: inInputData, output: outOutputData, gain: gain.pointee)
        }
        guard status == noErr, ioProcID != nil else {
            throw EngineError.ioProcFailed(status)
        }

        status = AudioDeviceStart(aggregateID, ioProcID)
        guard status == noErr else {
            throw EngineError.ioProcFailed(status)
        }
    }

    // MARK: - Audio render

    private static func render(
        input: UnsafePointer<AudioBufferList>,
        output: UnsafeMutablePointer<AudioBufferList>,
        gain: Float
    ) {
        let inputList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outputList = UnsafeMutableAudioBufferListPointer(output)

        for (index, outBuffer) in outputList.enumerated() {
            guard let outData = outBuffer.mData else { continue }

            if index < inputList.count, let inData = inputList[index].mData {
                let bytes = Int(min(inputList[index].mDataByteSize, outBuffer.mDataByteSize))
                let sampleCount = bytes / MemoryLayout<Float32>.size
                var g = gain
                vDSP_vsmul(
                    inData.assumingMemoryBound(to: Float32.self), 1,
                    &g,
                    outData.assumingMemoryBound(to: Float32.self), 1,
                    vDSP_Length(sampleCount)
                )
                let remaining = Int(outBuffer.mDataByteSize) - bytes
                if remaining > 0 {
                    memset(outData.advanced(by: bytes), 0, remaining)
                }
            } else {
                memset(outData, 0, Int(outBuffer.mDataByteSize))
            }
        }
    }

    // MARK: - Device helpers

    static func defaultOutputDeviceUID() throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        )
        guard status == noErr, deviceID != AudioObjectID(kAudioObjectUnknown) else {
            throw EngineError.noDefaultOutput
        }

        address.mSelector = kAudioDevicePropertyDeviceUID
        var uid: CFString = "" as CFString
        size = UInt32(MemoryLayout<CFString>.size)
        status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &uid)
        guard status == noErr else { throw EngineError.noDefaultOutput }
        return uid as String
    }
}
