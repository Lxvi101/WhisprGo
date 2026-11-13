import AVFoundation
import Foundation

/// Encodes 16 kHz mono dictation as AAC for upload. Speech at 32 kbps is
/// about 7.5× smaller than 16-bit WAV, which removes most of the upload time
/// from long cloud dictations. Encoding a 30-second recording takes a few tens
/// of milliseconds on Apple silicon.
///
/// Two containers are offered because services accept different ones:
/// M4A (`audio/mp4`) for OpenAI and ChatGPT, and raw ADTS (`audio/aac`) for
/// Gemini. ADTS has no index atoms, so short clips are also much smaller.
enum CompressedAudioEncoder {
    struct Encoded: Sendable {
        let data: Data
        let fileExtension: String
        let contentType: String
    }

    static let bitRate = 32_000

    static func encodeM4A(samples: [Float], sampleRate: Int = WAVEncoder.sampleRate) throws -> Encoded {
        try encode(samples: samples, sampleRate: sampleRate, fileExtension: "m4a", contentType: "audio/mp4")
    }

    static func encodeADTS(samples: [Float], sampleRate: Int = WAVEncoder.sampleRate) throws -> Encoded {
        try encode(samples: samples, sampleRate: sampleRate, fileExtension: "aac", contentType: "audio/aac")
    }

    /// `AVAudioFile` picks the container from the file extension.
    private static func encode(
        samples: [Float],
        sampleRate: Int,
        fileExtension: String,
        contentType: String
    ) throws -> Encoded {
        guard !samples.isEmpty,
              let format = AVAudioFormat(
                  commonFormat: .pcmFormatFloat32,
                  sampleRate: Double(sampleRate),
                  channels: 1,
                  interleaved: false
              ),
              let buffer = AVAudioPCMBuffer(
                  pcmFormat: format,
                  frameCapacity: AVAudioFrameCount(samples.count)
              ),
              let channel = buffer.floatChannelData?[0]
        else { throw EncodingError.unsupportedInput }

        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            channel.update(from: source.baseAddress!, count: samples.count)
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisprGo-\(UUID().uuidString).\(fileExtension)")
        defer { try? FileManager.default.removeItem(at: url) }

        try write(buffer, to: url, sampleRate: sampleRate)
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else { throw EncodingError.emptyOutput }
        return Encoded(data: data, fileExtension: fileExtension, contentType: contentType)
    }

    static func wav(samples: [Float]) -> Encoded {
        Encoded(
            data: WAVEncoder.encode(samples: samples),
            fileExtension: "wav",
            contentType: "audio/wav"
        )
    }

    /// The file is finalized when `AVAudioFile` is released at the end of
    /// this function, before the caller reads it back.
    private static func write(_ buffer: AVAudioPCMBuffer, to url: URL, sampleRate: Int) throws {
        let file = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: Double(sampleRate),
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: bitRate,
            ],
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        try file.write(from: buffer)
        if #available(macOS 15.0, *) {
            file.close()
        }
    }

    enum EncodingError: Error {
        case unsupportedInput
        case emptyOutput
    }
}

/// Removes leading and trailing silence before a cloud upload. Generous
/// padding keeps soft consonants and breaths at the edges of speech.
enum SpeechTrimmer {
    static let frameLength = 320 // 20 ms at 16 kHz
    static let leadingPadding = 0.3
    static let trailingPadding = 0.45

    static func trim(_ samples: [Float], sampleRate: Int = WAVEncoder.sampleRate) -> [Float] {
        let frameCount = samples.count / frameLength
        guard frameCount > 10 else { return samples }

        var energies = [Float](repeating: 0, count: frameCount)
        samples.withUnsafeBufferPointer { buffer in
            for frame in 0..<frameCount {
                var sum: Float = 0
                let start = frame * frameLength
                for index in start..<(start + frameLength) {
                    sum += buffer[index] * buffer[index]
                }
                energies[frame] = (sum / Float(frameLength)).squareRoot()
            }
        }

        let sorted = energies.sorted()
        let noiseFloor = sorted[sorted.count / 10]
        let peak = sorted[sorted.count - 1]
        // Speech must clearly exceed the room noise, but the bar stays low
        // relative to the loudest frame so quiet words are never dropped.
        let threshold = max(0.0015, min(noiseFloor * 3, peak * 0.08))
        guard let first = energies.firstIndex(where: { $0 > threshold }),
              let last = energies.lastIndex(where: { $0 > threshold })
        else { return samples }

        let start = max(0, first * frameLength - Int(leadingPadding * Double(sampleRate)))
        let end = min(samples.count, (last + 1) * frameLength + Int(trailingPadding * Double(sampleRate)))
        // Only trim when it removes something meaningful.
        guard end - start < samples.count - sampleRate / 5 else { return samples }
        return Array(samples[start..<end])
    }
}
