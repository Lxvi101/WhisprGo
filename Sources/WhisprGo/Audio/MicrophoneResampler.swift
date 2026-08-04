import AVFoundation
import Foundation

/// Stateful, allocation-free conversion for microphone packets. macOS treats
/// an audio tap's requested buffer size as a hint, so the output capacity must
/// cover the largest packet the device can actually deliver.
final class MicrophoneResampler {
    enum ResamplingError: LocalizedError {
        case inputPacketTooLarge(actual: Int, maximum: Int)
        case conversionFailed(String)
        case missingOutput

        var errorDescription: String? {
            switch self {
            case let .inputPacketTooLarge(actual, maximum):
                return "The microphone delivered \(actual) frames; the capture buffer supports \(maximum)."
            case let .conversionFailed(message):
                return "Microphone conversion failed: \(message)"
            case .missingOutput:
                return "Microphone conversion produced an invalid audio buffer."
            }
        }
    }

    static let maximumInputFrames: AVAudioFrameCount = 16_384

    let targetFormat: AVAudioFormat
    private let converter: AVAudioConverter
    private let outputBuffer: AVAudioPCMBuffer

    init(inputFormat: AVAudioFormat, targetSampleRate: Double) throws {
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: inputFormat, to: targetFormat)
        else {
            throw AudioCapture.CaptureError.converterCreationFailed
        }

        let ratio = targetFormat.sampleRate / inputFormat.sampleRate
        let estimatedFrames = ceil(Double(Self.maximumInputFrames) * ratio)
        let capacity = AVAudioFrameCount(max(1_024, estimatedFrames + 256))
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: capacity
        ) else {
            throw AudioCapture.CaptureError.outputBufferCreationFailed
        }

        self.targetFormat = targetFormat
        self.converter = converter
        self.outputBuffer = outputBuffer
    }

    /// The pointer is valid only for the duration of `body` and never escapes
    /// the real-time callback.
    func withConvertedSamples(
        from input: AVAudioPCMBuffer,
        _ body: (UnsafeBufferPointer<Float>) -> Void
    ) throws {
        guard input.frameLength <= Self.maximumInputFrames else {
            throw ResamplingError.inputPacketTooLarge(
                actual: Int(input.frameLength),
                maximum: Int(Self.maximumInputFrames)
            )
        }

        outputBuffer.frameLength = 0
        var suppliedInput = false
        let inputBlock: AVAudioConverterInputBlock = { _, status in
            if suppliedInput {
                status.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            status.pointee = .haveData
            return input
        }

        var conversionError: NSError?
        let status = converter.convert(
            to: outputBuffer,
            error: &conversionError,
            withInputFrom: inputBlock
        )
        guard status != .error else {
            throw ResamplingError.conversionFailed(
                conversionError?.localizedDescription ?? "unknown converter error"
            )
        }

        let count = Int(outputBuffer.frameLength)
        guard count == 0 || outputBuffer.floatChannelData?[0] != nil else {
            throw ResamplingError.missingOutput
        }
        guard count > 0, let channel = outputBuffer.floatChannelData?[0] else { return }
        body(UnsafeBufferPointer(start: channel, count: count))
    }
}
