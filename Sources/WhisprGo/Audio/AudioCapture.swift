import Accelerate
import AVFoundation
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
            return "The microphone stream could not be converted reliably."
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
        case invalidInputFormat
        case converterCreationFailed
        case outputBufferCreationFailed
        case engineStartFailed(Error)

        var errorDescription: String? {
            switch self {
            case .invalidInputFormat:
                return "The selected microphone does not expose a usable audio format."
            case .converterCreationFailed:
                return "WhisprGo could not create the microphone format converter."
            case .outputBufferCreationFailed:
                return "WhisprGo could not allocate its audio buffer."
            case let .engineStartFailed(error):
                return "The microphone could not start: \(error.localizedDescription)"
            }
        }
    }

    static let sampleRate: Double = 16_000
    private static let tapFrameCount: AVAudioFrameCount = 1_024
    private static let maximumSamples = Int(sampleRate * 5 * 60)
    private static let maximumRetainedSamples = Int(sampleRate * 30)

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private let levelMeter: AudioLevelMeter
    private let recordingGate = AtomicFlag()

    private var resampler: MicrophoneResampler?
    private var isPrepared = false
    private var isRecording = false
    private var samples = [Float]()
    private var sumOfSquares: Double = 0
    private var sampleCount = 0
    private var wasTruncated = false
    private var sourceDuration: TimeInterval = 0
    private var conversionFailureCount = 0
    private var preferBuiltInMicrophone: Bool
    private(set) var activeInputName: String?

    init(levelMeter: AudioLevelMeter, preferBuiltInMicrophone: Bool) {
        self.levelMeter = levelMeter
        self.preferBuiltInMicrophone = preferBuiltInMicrophone
    }

    func prepare() throws {
        guard !isPrepared else { return }

        let input = engine.inputNode
        let route = try AudioInputRouter.configure(
            inputNode: input,
            preferBuiltInMicrophone: preferBuiltInMicrophone
        )
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw CaptureError.invalidInputFormat
        }
        resampler = try MicrophoneResampler(
            inputFormat: inputFormat,
            targetSampleRate: Self.sampleRate
        )

        input.installTap(
            onBus: 0,
            bufferSize: Self.tapFrameCount,
            format: inputFormat
        ) { [weak self] buffer, _ in
            self?.process(buffer)
        }
        engine.prepare()
        activeInputName = route?.name
        isPrepared = true
    }

    /// Starts the input device but leaves the real-time conversion path gated
    /// off until an actual dictation begins.
    func activate() throws {
        try prepare()
        guard !engine.isRunning else { return }
        do {
            try engine.start()
        } catch {
            throw CaptureError.engineStartFailed(error)
        }
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

        if !engine.isRunning {
            do {
                try engine.start()
            } catch {
                recordingGate.store(false)
                lock.lock()
                isRecording = false
                lock.unlock()
                throw CaptureError.engineStartFailed(error)
            }
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
            // Privacy/default mode: release the input graph so Bluetooth audio
            // can return to its high-quality playback route while idle.
            releaseAudioGraph()
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

        releaseAudioGraph()
        levelMeter.reset()
    }

    func setPreferBuiltInMicrophone(_ enabled: Bool) {
        preferBuiltInMicrophone = enabled
    }

    func preferredInputName() -> String? {
        AudioInputRouter.preferredRouteName(
            preferBuiltInMicrophone: preferBuiltInMicrophone
        )
    }

    private func releaseAudioGraph() {
        engine.stop()
        if isPrepared {
            engine.inputNode.removeTap(onBus: 0)
        }
        resampler = nil
        activeInputName = nil
        isPrepared = false
    }

    private func process(_ input: AVAudioPCMBuffer) {
        // In always-active mode callbacks keep arriving 24/7. Exit before
        // conversion, metering, locks, and allocations while no dictation is active.
        guard recordingGate.load() else { return }
        guard let resampler else { return }
        let packetDuration = Double(input.frameLength) / input.format.sampleRate

        do {
            try resampler.withConvertedSamples(from: input) { channel in
                let count = channel.count
                var blockEnergy: Float = 0
                vDSP_svesq(channel.baseAddress!, 1, &blockEnergy, vDSP_Length(count))
                let level = sqrt(blockEnergy / Float(count))
                guard level.isFinite else { return }

                lock.lock()
                guard isRecording else {
                    lock.unlock()
                    return
                }
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

            lock.lock()
            if isRecording {
                // A converter may buffer a packet while priming; comparing
                // source and output durations at stop catches actual loss.
                sourceDuration += packetDuration
            }
            lock.unlock()
        } catch {
            lock.lock()
            if isRecording {
                sourceDuration += packetDuration
                conversionFailureCount += 1
            }
            lock.unlock()
        }
    }
}
