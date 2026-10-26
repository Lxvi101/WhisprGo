import Foundation
import MLX
import MLXNN

/// A loaded Phonon-2.5 model. Not thread-safe: MLX evaluation must be
/// serialized, which `TranscriptionRuntime` guarantees as an actor.
final class PhononTranscriber: @unchecked Sendable {
    static let computeDType: DType = .bfloat16

    private let network: PhononNetwork
    private let vocabulary: [String]
    private let variant: PhononVariant
    private let decodeStep: ([MLXArray]) -> [MLXArray]

    enum LoadError: LocalizedError {
        case incompleteModel(String)

        var errorDescription: String? {
            switch self {
            case let .incompleteModel(detail):
                return "The Phonon model files are incomplete (\(detail)). Remove the download and select the model again."
            }
        }
    }

    init(directory: URL, variant: PhononVariant) throws {
        PhononRuntimeEnvironment.configure()
        let files = PhononInstalledFiles(directory: directory)
        let vocabulary = try JSONDecoder().decode(
            [String].self,
            from: Data(contentsOf: files.vocabulary)
        )
        guard vocabulary.count == PhononArchitecture.vocabularySize else {
            throw LoadError.incompleteModel("vocabulary has \(vocabulary.count) entries")
        }

        let network = PhononNetwork()
        let weights = try loadArrays(url: files.weights)
        do {
            try network.update(
                parameters: ModuleParameters.unflattened(weights),
                verify: .all
            )
        } catch {
            throw LoadError.incompleteModel(String(describing: error))
        }
        for layer in network.packedLayers {
            layer.materialize()
        }
        eval(network)

        self.network = network
        self.vocabulary = vocabulary
        self.variant = variant
        // Only the predictor and joint feed a step; listing the whole network
        // would gather every encoder parameter on each call.
        decodeStep = compile(
            inputs: [network.predictor, network.joint],
            outputs: [],
            network.decodeStep
        )
    }

    /// Runs a short silent clip so Metal kernels compile before the first
    /// dictation rather than during it.
    func warmUp() {
        _ = transcribeWindow([Float](repeating: 0, count: PhononArchitecture.sampleRate))
        Memory.clearCache()
    }

    func transcribe(_ samples: [Float]) -> String {
        defer { Memory.clearCache() }
        guard !Self.isSilent(samples) else { return "" }
        let texts = PhononWindowPlanner.plan(samples).compactMap { window -> String? in
            guard !Task.isCancelled else { return nil }
            let text = transcribeWindow(Array(samples[window]))
            return text.isEmpty ? nil : text
        }
        var text = texts.joined(separator: " ")
        if variant.writesFinalSigma {
            text = Self.applyFinalSigma(text)
        }
        return text
    }

    private func transcribeWindow(_ window: [Float]) -> String {
        let leadPad = Int(variant.leadPadSeconds * Double(PhononArchitecture.sampleRate))
        let audio = [Float](repeating: 0, count: leadPad) + window
        // Shorter clips leave the subsampling stack without a frame.
        guard audio.count >= 2 * PhononArchitecture.hopLength else { return "" }

        let mel = PhononFrontend.melSpectrogram(audio, dtype: Self.computeDType)
        let encoded = network.encoder(mel)
        let frames = network.joint.encoderProjection(encoded)[0]
        eval(frames)

        let tokens = greedyDecode(frames: frames)
        return Self.detokenize(tokens, vocabulary: vocabulary)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Greedy TDT decoding. Steps are queued in blocks and read back once
    /// per block; a host round trip per step would dominate decoding time.
    private func greedyDecode(frames: MLXArray) -> [Int] {
        let blockSize = 16
        let frameCount = frames.dim(0)
        let stateShape = [PhononArchitecture.predictionLayers, 1, PhononArchitecture.predictionHidden]

        var state = [
            MLXArray(Int32(0)),
            MLXArray([Int32(PhononArchitecture.blankToken)]),
            MLXArray.zeros(stateShape, dtype: Self.computeDType),
            MLXArray.zeros(stateShape, dtype: Self.computeDType),
            MLXArray(Int32(0)),
        ]
        var tokens: [Int] = []
        // Every step consumes a frame or emits a token, and at most
        // maxSymbolsPerStep tokens fit in one frame.
        let stepLimit = frameCount * (PhononArchitecture.maxSymbolsPerStep + 1)
        var steps = 0

        while steps < stepLimit, !Task.isCancelled {
            var emitted: [MLXArray] = []
            for _ in 0..<blockSize {
                let outputs = decodeStep([frames] + state)
                state = Array(outputs[0..<5])
                emitted.append(outputs[5])
            }
            steps += blockSize
            let block = MLX.stacked(emitted)
            eval(block, state[0], state[1], state[2], state[3], state[4])
            tokens += block.asArray(Int32.self).filter { $0 >= 0 }.map(Int.init)
            if state[0].item(Int32.self) >= frameCount { break }
        }
        return tokens
    }

    static func detokenize(_ tokens: [Int], vocabulary: [String]) -> String {
        tokens.compactMap { token -> String? in
            guard vocabulary.indices.contains(token) else { return nil }
            let piece = vocabulary[token]
            if (piece.hasPrefix("<|") && piece.hasSuffix("|>"))
                || piece == "<unk>" || piece == "<pad>"
            {
                return nil
            }
            return piece.replacingOccurrences(of: "\u{2581}", with: " ")
        }
        .joined()
    }

    /// The multilingual model emits the medial sigma at word ends.
    static func applyFinalSigma(_ text: String) -> String {
        guard text.contains("σ") else { return text }
        return text.replacingOccurrences(
            of: "σ(?![\\p{L}\\p{N}])",
            with: "ς",
            options: .regularExpression
        )
    }

    static func isSilent(_ samples: [Float]) -> Bool {
        !samples.contains { abs($0) >= 1e-4 }
    }
}

/// Fermion's long-audio rule: decode up to 35 s in one pass; cut longer
/// recordings into 25-35 s windows that end in the longest pause.
enum PhononWindowPlanner {
    static let singleShotSeconds = 35.0
    static let bandStartSeconds = 25.0
    static let bandEndSeconds = 35.0
    static let targetSeconds = 30.0
    static let blockSeconds = 0.05
    static let noiseFloor: Float = 0.004
    static let gateRatio: Float = 0.18

    static func plan(_ samples: [Float], sampleRate: Int = PhononArchitecture.sampleRate) -> [Range<Int>] {
        let count = samples.count
        let single = Int(singleShotSeconds * Double(sampleRate))
        guard count > single else { return [0..<count] }

        let block = Int(blockSeconds * Double(sampleRate))
        let blockCount = (count + block - 1) / block
        let rms: [Float] = (0..<blockCount).map { index in
            let start = index * block
            let end = min(start + block, count)
            var sum: Float = 0
            for sample in samples[start..<end] {
                sum += sample * sample
            }
            return (sum / Float(block)).squareRoot()
        }

        var windows: [Range<Int>] = []
        var start = 0
        while count - start > single {
            let low = start + Int(bandStartSeconds * Double(sampleRate))
            let high = start + Int(bandEndSeconds * Double(sampleRate))
            let target = start + Int(targetSeconds * Double(sampleRate))
            let firstBlock = (low + block - 1) / block
            let endBlock = min(high / block, blockCount)
            let peak = rms[(start / block)..<max(start / block, endBlock)].max() ?? 0
            let gate = max(noiseFloor, gateRatio * peak)

            var cut = target
            var best: (length: Int, distance: Int, middle: Int)?
            var index = firstBlock
            while index < endBlock {
                guard rms[index] <= gate else {
                    index += 1
                    continue
                }
                var end = index
                while end < endBlock, rms[end] <= gate {
                    end += 1
                }
                let middle = (index + end) * block / 2
                let candidate = (length: end - index, distance: -abs(middle - target), middle: middle)
                if let current = best {
                    if (candidate.length, candidate.distance, candidate.middle)
                        > (current.length, current.distance, current.middle)
                    {
                        best = candidate
                    }
                } else {
                    best = candidate
                }
                index = end
            }
            if let best {
                cut = best.middle
            }
            cut = max(low, min(high, cut, count))
            windows.append(start..<cut)
            start = cut
        }
        windows.append(start..<count)
        return windows
    }
}

/// Process-wide MLX settings for a resident menu-bar app.
enum PhononRuntimeEnvironment {
    private static let once: Void = {
        // Keep freed GPU buffers from accumulating between dictations.
        Memory.cacheLimit = 128 * 1_024 * 1_024
    }()

    static func configure() {
        _ = once
    }
}
