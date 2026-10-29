import AVFoundation
import CoreAudio
import RingCore

struct MeetingSystemAudioError: LocalizedError {
    let stage: String
    let status: OSStatus
    var errorDescription: String? {
        "System audio could not start (\(stage), code \(status)). Allow The One Ring Planner in System Settings → Privacy & Security → Screen & System Audio Recording, then try again. Captured audio is preserved."
    }
}

enum MeetingSystemAudioPCM {
    /// HAL owns its input buffers only for the duration of the callback.
    static func copy(_ list: UnsafePointer<AudioBufferList>, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        let bytesPerFrame = format.streamDescription.pointee.mBytesPerFrame
        guard bytesPerFrame > 0, let first = source.first, first.mDataByteSize > 0 else { return nil }
        let frames = first.mDataByteSize / bytesPerFrame
        guard frames > 0, let result = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        result.frameLength = frames
        let target = UnsafeMutableAudioBufferListPointer(result.mutableAudioBufferList)
        guard source.count == target.count else { return nil }
        for i in source.indices {
            guard let src = source[i].mData, let dst = target[i].mData, source[i].mDataByteSize >= target[i].mDataByteSize else { return nil }
            memcpy(dst, src, Int(target[i].mDataByteSize))
        }
        return result
    }
}

/// A private, unmuted global HAL tap: no app/window selection and no video capture.
final class MeetingSystemAudioCapture {
    private var tap = AudioObjectID(kAudioObjectUnknown)
    private var device = AudioObjectID(kAudioObjectUnknown)
    private var io: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "com.t1a.planner.system-audio", qos: .userInitiated)
    @available(macOS 14.2, *)
    func start(sink: MeetingAudioSink) throws {
        do {
            var ownProcess = AudioObjectID(kAudioObjectUnknown), pid = ProcessInfo.processInfo.processIdentifier
            var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var size = UInt32(MemoryLayout<AudioObjectID>.size)
            let translated = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &ownProcess)
            let excluded = translated == noErr && ownProcess != kAudioObjectUnknown ? [ownProcess] : []
            let description = CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
            description.name = "The One Ring Planner · System audio"; description.isPrivate = true; description.muteBehavior = .unmuted
            if #available(macOS 26, *), let bundleID = Bundle.main.bundleIdentifier { description.bundleIDs = [bundleID] }
            try check(AudioHardwareCreateProcessTap(description, &tap), "create audio tap")
            var asbd = AudioStreamBasicDescription()
            address.mSelector = kAudioTapPropertyFormat; size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try check(AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &asbd), "read tap format")
            guard let format = AVAudioFormat(streamDescription: &asbd), format.sampleRate > 0 else { throw MeetingSystemAudioError(stage: "audio format", status: kAudioHardwareUnsupportedOperationError) }
            let composition: [String: Any] = [kAudioAggregateDeviceNameKey: "The One Ring Planner Recording",
                kAudioAggregateDeviceUIDKey: "com.t1a.recording." + UUID().uuidString,
                kAudioAggregateDeviceIsPrivateKey: true, kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]]]
            try check(AudioHardwareCreateAggregateDevice(composition as CFDictionary, &device), "create recording device")
            try check(AudioDeviceCreateIOProcIDWithBlock(&io, device, queue) { _, data, time, _, _ in
                guard let buffer = MeetingSystemAudioPCM.copy(data, format: format) else { return }
                let timestamp = time.pointee
                let seconds = timestamp.mFlags.contains(.hostTimeValid) ? AVAudioTime.seconds(forHostTime: timestamp.mHostTime) : CMClockGetTime(CMClockGetHostTimeClock()).seconds
                sink.systemAudio(buffer, at: seconds)
            }, "attach recording input")
            try check(AudioDeviceStart(device, io), "start system recording")
        } catch { stop(); throw error }
    }
    func stop() {
        if let io { AudioDeviceStop(device, io); AudioDeviceDestroyIOProcID(device, io) }; io = nil
        if device != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(device) }; device = AudioObjectID(kAudioObjectUnknown)
        if #available(macOS 14.2, *), tap != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tap) }; tap = AudioObjectID(kAudioObjectUnknown)
    }
    private func check(_ status: OSStatus, _ stage: String) throws { if status != noErr { throw MeetingSystemAudioError(stage: stage, status: status) } }
    deinit { stop() }
}
