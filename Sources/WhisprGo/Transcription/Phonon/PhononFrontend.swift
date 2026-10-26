import Foundation
import MLX

/// NeMo's log-mel front end as mlx-audio computes it for Parakeet: 0.97
/// pre-emphasis, a 25 ms symmetric Hann window centered in a 512-point FFT,
/// 10 ms hops, 128 Slaney mel bands, a 2^-24 log guard, and per-feature
/// normalization. Computed in fp32; long recordings overflow fp16 sums.
enum PhononFrontend {
    private static let preemphasis: Float = 0.97
    private static let logGuard = Float(pow(2.0, -24.0))

    private static let window: MLXArray = {
        let length = PhononArchitecture.windowLength
        let fft = PhononArchitecture.fftLength
        let left = (fft - length) / 2
        var values = [Float](repeating: 0, count: fft)
        for n in 0..<length {
            values[left + n] = 0.5 * (1 - cos(2 * Float.pi * Float(n) / Float(length - 1)))
        }
        return MLXArray(values)
    }()

    /// [frequency bins, mel bands]
    private static let filterbank: MLXArray = {
        let sampleRate = Float(PhononArchitecture.sampleRate)
        let bins = PhononArchitecture.fftLength / 2 + 1
        let bands = PhononArchitecture.melFeatures

        let linearSpacing: Float = 200.0 / 3
        let logStartHz: Float = 1000
        let logStartMel = logStartHz / linearSpacing
        let logStep = log(Float(6.4)) / 27

        func hzToMel(_ hz: Float) -> Float {
            hz >= logStartHz
                ? logStartMel + log(hz / logStartHz) / logStep
                : hz / linearSpacing
        }
        func melToHz(_ mel: Float) -> Float {
            mel >= logStartMel
                ? logStartHz * exp(logStep * (mel - logStartMel))
                : linearSpacing * mel
        }

        let maximumMel = hzToMel(sampleRate / 2)
        let points = (0..<(bands + 2)).map { index in
            melToHz(maximumMel * Float(index) / Float(bands + 1))
        }
        var values = [Float](repeating: 0, count: bins * bands)
        for bin in 0..<bins {
            let frequency = (sampleRate / 2) * Float(bin) / Float(bins - 1)
            for band in 0..<bands {
                let down = (frequency - points[band]) / (points[band + 1] - points[band])
                let up = (points[band + 2] - frequency) / (points[band + 2] - points[band + 1])
                let weight = max(0, min(down, up))
                values[bin * bands + band] = weight * 2 / (points[band + 2] - points[band])
            }
        }
        return MLXArray(values, [bins, bands])
    }()

    /// Number of mel frames produced for `sampleCount` samples.
    static func frameCount(sampleCount: Int) -> Int {
        sampleCount / PhononArchitecture.hopLength + 1
    }

    /// `samples`: mono 16 kHz audio → [1, frames, 128] in `dtype`.
    static func melSpectrogram(_ samples: [Float], dtype: DType) -> MLXArray {
        // The reference decoder receives its audio in the compute dtype
        // before the fp32 front end; match its rounding.
        var x = MLXArray(samples).asType(dtype).asType(.float32)
        x = concatenated([x[..<1], x[1...] - preemphasis * x[..<(x.dim(0) - 1)]], axis: 0)

        let padding = PhononArchitecture.fftLength / 2
        x = padded(x, widths: [.init((padding, padding))])
        let frames = 1 + (x.dim(0) - PhononArchitecture.fftLength) / PhononArchitecture.hopLength
        let framed = asStrided(
            x,
            [frames, PhononArchitecture.fftLength],
            strides: [PhononArchitecture.hopLength, 1]
        )
        let spectrum = MLXFFT.rfft(framed * window, axis: 1)
        let power = abs(spectrum).square()

        let mel = log(matmul(power, filterbank) + MLXArray(logGuard))
        let mean = mel.mean(axis: 0, keepDims: true)
        let denominator = Float(max(mel.dim(0) - 1, 1))
        let std = sqrt((mel - mean).square().sum(axis: 0, keepDims: true) / denominator)
        let normalized = (mel - mean) / (std + MLXArray(Float(1e-5)))
        return normalized.expandedDimensions(axis: 0).asType(dtype)
    }
}
