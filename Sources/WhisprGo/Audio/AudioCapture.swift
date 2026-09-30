import Accelerate
import AudioToolbox
import Foundation

struct AudioCaptureResult: Sendable {
    let samples: [Float]
    let rms: Float
    let wasTruncated: Bool
    let sourceDuration: TimeInterval
    let conversionFailureCount: Int

    var duration: TimeInterval {
        Double(samples.count) / AudioCapture.sampleRate
    }

    var integrityIssue: String? {
        guard conversionFailureCount == 0 else {
            return "The microphone stream could not be captured reliably."
        }
        guard sourceDuration > 0 else {
            return "The microphone did not deliver any audio."
        }
        let coverage = duration / sourceDuration
        guard coverage >= 0.90, coverage <= 1.10 else {
            return "The microphone stream was incomplete (\(Int(coverage * 100))% audio coverage)."
        }
        return nil
    }
}

final class AudioCapture {
    enum CaptureError: LocalizedError {
        case queueCreationFailed(OSStatus)
        case deviceSelectionFailed(OSStatus)
        case bufferAllocationFailed(OSStatus)
        case bufferEnqueueFailed(OSStatus)
        case queueStartFailed(OSStatus)

        var errorDescription: String? {
            switch self {
            case let .queueCreationFailed(status):
                return "The microphone input queue could not be created (Core Audio error \(status))."
            case let .deviceSelectionFailed(status):
                return "The preferred microphone could not be selected (Core Audio error \(status))."
            case let .bufferAllocationFailed(status):
                return "A microphone buffer could not be allocated (Core Audio error \(status))."
            case let .bufferEnqueueFailed(status):
                return "A microphone buffer could not be prepared (Core Audio error \(status))."
            case let .queueStartFailed(status):
                return "The microphone could not start (Core Audio error \(status))."
            }
        }
    }

    static let sampleRate: Double = 16_000
    static var captureFormat: AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat
                | kAudioFormatFlagIsPacked
                | kAudioFormatFlagsNativeEndian,
            mBytesPerPacket: UInt32(MemoryLayout<Float>.size),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(MemoryLayout<Float>.size),
            mChannelsPerFrame: 1,
            mBitsPerChannel: UInt32(MemoryLayout<Float>.size * 8),
            mReserved: 0
        )
    }

    private static let queueBufferCount = 3
    private static let queueBufferFrames = 4_096
    private static let maximumSamples = Int(sampleRate * 5 * 60)
    private static let maximumRetainedSamples = Int(sampleRate * 30)

    private let lock = NSLock()
    private let levelMeter: AudioLevelMeter
    private let recordingGate = AtomicFlag()

    private var audioQueue: AudioQueueRef?
    private var isRecording = false
    private var samples = [Float]()
    private var sumOfSquares: Double = 0
    private var sampleCount = 0
    private var wasTruncated = false
    private var sourceDuration: TimeInterval = 0
    private var conversionFailureCount = 0
    private var allowedExternalMicrophoneUIDs: Set<String>
    private(set) var activeInputName: String?
    private(set) var activeInputUID: String?

    init(levelMeter: AudioLevelMeter, allowedExternalMicrophoneUIDs: Set<String>) {
        self.levelMeter = levelMeter
        self.allowedExternalMicrophoneUIDs = allowedExternalMicrophoneUIDs
    }

    func prepare() throws {
        guard audioQueue == nil else { return }
        guard let route = AudioInputRouter.preferredRoute(
            allowedExternalMicrophoneUIDs: allowedExternalMicrophoneUIDs
        ) else {
            throw AudioInputRouter.RoutingError.noSafeMicrophoneAvailable
        }

        var format = Self.captureFormat
        var createdQueue: AudioQueueRef?
        let creationStatus = AudioQueueNewInput(
            &format,
            whisprAudioQueueInputCallback,
            Unmanaged.passUnretained(self).toOpaque(),
            nil,
            nil,
            0,
            &createdQueue
        )
        guard creationStatus == noErr, let createdQueue else {
            throw CaptureError.queueCreationFailed(creationStatus)
        }

        do {
            var deviceUID: CFString = route.uid as CFString
            let selectionStatus = withUnsafePointer(to: &deviceUID) { pointer in
                AudioQueueSetProperty(
                    createdQueue,
                    kAudioQueueProperty_CurrentDevice,
                    pointer,
                    UInt32(MemoryLayout<CFString>.size)
                )
            }
            guard selectionStatus == noErr else {
                throw CaptureError.deviceSelectionFailed(selectionStatus)
            }

            let byteCapacity = UInt32(
                Self.queueBufferFrames * MemoryLayout<Float>.size
            )
            for _ in 0..<Self.queueBufferCount {
                var buffer: AudioQueueBufferRef?
                let allocationStatus = AudioQueueAllocateBuffer(
                    createdQueue,
                    byteCapacity,
                    &buffer
                )
                guard allocationStatus == noErr, let buffer else {
                    throw CaptureError.bufferAllocationFailed(allocationStatus)
                }
                let enqueueStatus = AudioQueueEnqueueBuffer(
                    createdQueue,
                    buffer,
                    0,
                    nil
                )
                guard enqueueStatus == noErr else {
                    throw CaptureError.bufferEnqueueFailed(enqueueStatus)
                }
            }
        } catch {
            AudioQueueDispose(createdQueue, true)
            throw error
        }

        audioQueue = createdQueue
        activeInputName = route.name
        activeInputUID = route.uid
    }

    /// Starts the selected input queue but leaves sample collection gated off
    /// until an actual dictation begins.
    func activate() throws {
        try prepare()
        try startQueueIfNeeded()
    }

    func start() throws {
        try prepare()

        lock.lock()
        guard !isRecording else {
            lock.unlock()
            return
        }
        samples.removeAll(keepingCapacity: true)
        samples.reserveCapacity(Int(Self.sampleRate * 15))
        sumOfSquares = 0
        sampleCount = 0
        wasTruncated = false
        sourceDuration = 0
        conversionFailureCount = 0
        isRecording = true
        lock.unlock()
        recordingGate.store(true)
        levelMeter.reset()

        do {
            try startQueueIfNeeded()
        } catch {
            recordingGate.store(false)
            lock.lock()
            isRecording = false
            lock.unlock()
            throw error
        }
    }

    func stop(keepActive: Bool) -> AudioCaptureResult {
        recordingGate.store(false)
        lock.lock()
        guard isRecording else {
            lock.unlock()
            return AudioCaptureResult(
                samples: [],
                rms: 0,
                wasTruncated: false,
                sourceDuration: 0,
                conversionFailureCount: 0
            )
        }
        isRecording = false
        lock.unlock()

        if !keepActive {
            // Privacy/default mode: release the input device while idle.
            releaseAudioQueue()
        }

        lock.lock()
        // Move the array's storage into the result. This avoids briefly holding
        // two full recordings in memory at the hand-off to transcription.
        let captured = samples
        let rms = sampleCount > 0
            ? Float((sumOfSquares / Double(sampleCount)).squareRoot())
            : 0
        let truncated = wasTruncated
        let inputDuration = sourceDuration
        let failures = conversionFailureCount
        samples = []
        lock.unlock()

        levelMeter.reset()
        return AudioCaptureResult(
            samples: captured,
            rms: rms,
            wasTruncated: truncated,
            sourceDuration: inputDuration,
            conversionFailureCount: failures
        )
    }

    /// Keeps a modest, already-allocated recording buffer for the next use.
    /// Long recordings are released so idle memory stays bounded.
    func recycle(_ buffer: [Float]) {
        guard buffer.count <= Self.maximumRetainedSamples else { return }
        lock.lock()
        if !isRecording, samples.isEmpty {
            samples = buffer
        }
        lock.unlock()
    }

    func shutdown() {
        recordingGate.store(false)
        lock.lock()
        isRecording = false
        lock.unlock()

        releaseAudioQueue()
        levelMeter.reset()
    }

    func setAllowedExternalMicrophoneUIDs(_ uids: Set<String>) {
        allowedExternalMicrophoneUIDs = uids
    }

    func preferredInputName() -> String? {
        AudioInputRouter.preferredRouteName(
            allowedExternalMicrophoneUIDs: allowedExternalMicrophoneUIDs
        )
    }

    func isUsingPreferredInput() -> Bool {
        guard let audioQueue,
              let activeInputUID,
              AudioInputRouter.preferredRoute(
                  allowedExternalMicrophoneUIDs: allowedExternalMicrophoneUIDs
              )?.uid == activeInputUID
        else { return false }

        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioQueueGetProperty(
            audioQueue,
            kAudioQueueProperty_IsRunning,
            &running,
            &size
        ) == noErr && running != 0
    }

    fileprivate func process(
        queue: AudioQueueRef,
        buffer: AudioQueueBufferRef
    ) {
        defer {
            _ = AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
        }
        guard recordingGate.load() else { return }

        let byteCount = Int(buffer.pointee.mAudioDataByteSize)
        guard byteCount > 0,
              byteCount.isMultiple(of: MemoryLayout<Float>.size)
        else {
            recordCaptureFailure()
            return
        }

        let count = byteCount / MemoryLayout<Float>.size
        let audioData = buffer.pointee.mAudioData
        let channel = UnsafeBufferPointer(
            start: audioData.assumingMemoryBound(to: Float.self),
            count: count
        )
        var blockEnergy: Float = 0
        vDSP_svesq(channel.baseAddress!, 1, &blockEnergy, vDSP_Length(count))
        let level = sqrt(blockEnergy / Float(count))
        guard level.isFinite else {
            recordCaptureFailure()
            return
        }

        lock.lock()
        guard isRecording else {
            lock.unlock()
            return
        }
        sourceDuration += Double(count) / Self.sampleRate
        let available = max(0, Self.maximumSamples - samples.count)
        let accepted = min(available, count)
        if accepted > 0 {
            samples.append(contentsOf: channel.prefix(accepted))
            var energy = blockEnergy
            if accepted != count {
                energy = 0
                vDSP_svesq(
                    channel.baseAddress!,
                    1,
                    &energy,
                    vDSP_Length(accepted)
                )
            }
            sumOfSquares += Double(energy)
            sampleCount += accepted
        }
        if accepted < count {
            wasTruncated = true
        }
        lock.unlock()
        levelMeter.store(level)
    }

    private func startQueueIfNeeded() throws {
        guard let audioQueue else {
            throw CaptureError.queueCreationFailed(kAudioQueueErr_InvalidBuffer)
        }

        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        if AudioQueueGetProperty(
            audioQueue,
            kAudioQueueProperty_IsRunning,
            &running,
            &size
        ) == noErr, running != 0 {
            return
        }

        let status = AudioQueueStart(audioQueue, nil)
        guard status == noErr else {
            throw CaptureError.queueStartFailed(status)
        }
    }

    private func releaseAudioQueue() {
        guard let audioQueue else {
            activeInputName = nil
            activeInputUID = nil
            return
        }
        self.audioQueue = nil
        AudioQueueStop(audioQueue, true)
        AudioQueueDispose(audioQueue, true)
        activeInputName = nil
        activeInputUID = nil
    }

    private func recordCaptureFailure() {
        lock.lock()
        if isRecording {
            conversionFailureCount += 1
        }
        lock.unlock()
    }
}

private func whisprAudioQueueInputCallback(
    userData: UnsafeMutableRawPointer?,
    queue: AudioQueueRef,
    buffer: AudioQueueBufferRef,
    startTime: UnsafePointer<AudioTimeStamp>,
    packetCount: UInt32,
    packetDescriptions: UnsafePointer<AudioStreamPacketDescription>?
) {
    guard let userData else { return }
    let capture = Unmanaged<AudioCapture>.fromOpaque(userData).takeUnretainedValue()
    capture.process(queue: queue, buffer: buffer)
}
