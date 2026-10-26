// The Parakeet TDT graph below is adapted from mlx-audio-swift
// (https://github.com/Blaizzy/mlx-audio-swift), Copyright (c) 2025 Prince
// Canuma, MIT License, and mirrors the mlx-audio graph Fermion Research runs
// Phonon-2.5 on. The packed layer follows fermion-research's
// PackedFiveValueLinear, Copyright 2026 Fermion Research, Apache-2.0.

import Foundation
import MLX
import MLXNN

/// Architecture of the Parakeet TDT 0.6B v3 network Phonon-2.5 retrains.
/// The converter checks the downloaded configuration against these values.
enum PhononArchitecture {
    static let sampleRate = 16_000
    static let melFeatures = 128
    static let fftLength = 512
    static let windowLength = 400
    static let hopLength = 160
    static let subsamplingFactor = 8
    static let subsamplingChannels = 256
    static let modelDimension = 1024
    static let layerCount = 24
    static let headCount = 8
    static let feedForwardExpansion = 4
    static let convolutionKernel = 9
    static let predictionHidden = 640
    static let predictionLayers = 2
    static let jointHidden = 640
    static let vocabularySize = 8192
    static let durations = [0, 1, 2, 3, 4]
    static let maxSymbolsPerStep = 10
    static let packedGroupSize = 128

    static var blankToken: Int { vocabularySize }
    static var feedForwardDimension: Int { modelDimension * feedForwardExpansion }
    static var jointOutputs: Int { vocabularySize + 1 + durations.count }
    /// Seconds of audio covered by one encoder frame.
    static var frameSeconds: Double {
        Double(subsamplingFactor * hopLength) / Double(sampleRate)
    }
}

/// One Phonon encoder projection. Each weight is one of five values per row,
/// {0, ±lo, ±hi}, stored as two 2-bit affine planes so the projection runs as
/// two native MLX quantized matmuls and keeps the learned values exactly.
final class PhononPackedLinear: Module, UnaryLayer {
    @ParameterInfo(key: "base_q") var baseQ: MLXArray
    @ParameterInfo(key: "residual_q") var residualQ: MLXArray
    @ParameterInfo(key: "row_lo") var rowLo: MLXArray
    @ParameterInfo(key: "row_hi") var rowHi: MLXArray

    let inputDimensions: Int
    let outputDimensions: Int

    private var _baseScales: MLXArray?
    private var _residualScales: MLXArray?

    init(inputDimensions: Int, outputDimensions: Int) {
        precondition(inputDimensions % PhononArchitecture.packedGroupSize == 0)
        self.inputDimensions = inputDimensions
        self.outputDimensions = outputDimensions
        let words = inputDimensions / 16
        _baseQ.wrappedValue = MLXArray.zeros([outputDimensions, words], dtype: .uint32)
        _residualQ.wrappedValue = MLXArray.zeros([outputDimensions, words], dtype: .uint32)
        _rowLo.wrappedValue = MLXArray.zeros([outputDimensions], dtype: .float16)
        _rowHi.wrappedValue = MLXArray.zeros([outputDimensions], dtype: .float16)
    }

    /// Expands the per-row palette into per-group quantization scales. Run
    /// once after the weights load.
    func materialize() {
        let shape = [outputDimensions, inputDimensions / PhononArchitecture.packedGroupSize]
        // Subtract in fp32: rounding hi - lo to fp16 would change the weights.
        let lo = rowLo.asType(.float32)
        let delta = rowHi.asType(.float32) - lo
        let baseScales = contiguous(broadcast(lo.expandedDimensions(axis: 1), to: shape))
        let residualScales = contiguous(broadcast(delta.expandedDimensions(axis: 1), to: shape))
        eval(baseScales, residualScales)
        _baseScales = baseScales
        _residualScales = residualScales
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        guard let baseScales = _baseScales, let residualScales = _residualScales else {
            preconditionFailure("Materialize packed scales after loading weights")
        }
        let input = x.asType(.float32)
        let base = quantizedMM(
            input, baseQ, scales: baseScales, biases: -baseScales,
            transpose: true, groupSize: PhononArchitecture.packedGroupSize, bits: 2
        )
        let residual = quantizedMM(
            input, residualQ, scales: residualScales, biases: -residualScales,
            transpose: true, groupSize: PhononArchitecture.packedGroupSize, bits: 2
        )
        return (base + residual).asType(x.dtype)
    }
}

final class PhononFeedForward: Module {
    @ModuleInfo(key: "linear1") var linear1: PhononPackedLinear
    @ModuleInfo(key: "linear2") var linear2: PhononPackedLinear

    override init() {
        let d = PhononArchitecture.modelDimension
        let ff = PhononArchitecture.feedForwardDimension
        _linear1.wrappedValue = PhononPackedLinear(inputDimensions: d, outputDimensions: ff)
        _linear2.wrappedValue = PhononPackedLinear(inputDimensions: ff, outputDimensions: d)
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        linear2(silu(linear1(x)))
    }
}

/// Inference-only batch normalization over the channel (last) axis.
final class PhononBatchNorm: Module {
    var weight: MLXArray
    var bias: MLXArray
    @ParameterInfo(key: "running_mean") var runningMean: MLXArray
    @ParameterInfo(key: "running_var") var runningVar: MLXArray

    init(channels: Int) {
        weight = MLXArray.ones([channels])
        bias = MLXArray.zeros([channels])
        _runningMean.wrappedValue = MLXArray.zeros([channels])
        _runningVar.wrappedValue = MLXArray.ones([channels])
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        let scale = weight * rsqrt(runningVar + MLXArray(Float(1e-5)).asType(runningVar.dtype))
        return (x - runningMean) * scale + bias
    }
}

final class PhononConvolution: Module {
    @ModuleInfo(key: "pointwise_conv1") var pointwiseConv1: PhononPackedLinear
    @ModuleInfo(key: "depthwise_conv") var depthwiseConv: Conv1d
    @ModuleInfo(key: "batch_norm") var batchNorm: PhononBatchNorm
    @ModuleInfo(key: "pointwise_conv2") var pointwiseConv2: PhononPackedLinear

    override init() {
        let d = PhononArchitecture.modelDimension
        let kernel = PhononArchitecture.convolutionKernel
        _pointwiseConv1.wrappedValue = PhononPackedLinear(inputDimensions: d, outputDimensions: 2 * d)
        _depthwiseConv.wrappedValue = Conv1d(
            inputChannels: d,
            outputChannels: d,
            kernelSize: kernel,
            stride: 1,
            padding: (kernel - 1) / 2,
            groups: d,
            bias: false
        )
        _batchNorm.wrappedValue = PhononBatchNorm(channels: d)
        _pointwiseConv2.wrappedValue = PhononPackedLinear(inputDimensions: d, outputDimensions: d)
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        // Kernel-1 convolutions over channels-last input are linears.
        let halves = pointwiseConv1(x).split(parts: 2, axis: 2)
        let gated = halves[0] * sigmoid(halves[1])
        return pointwiseConv2(silu(batchNorm(depthwiseConv(gated))))
    }
}

final class PhononRelativeAttention: Module {
    let headCount = PhononArchitecture.headCount
    let headDimension = PhononArchitecture.modelDimension / PhononArchitecture.headCount
    let scale: Float

    @ModuleInfo(key: "linear_q") var linearQ: PhononPackedLinear
    @ModuleInfo(key: "linear_k") var linearK: PhononPackedLinear
    @ModuleInfo(key: "linear_v") var linearV: PhononPackedLinear
    @ModuleInfo(key: "linear_out") var linearOut: PhononPackedLinear
    @ModuleInfo(key: "linear_pos") var linearPos: PhononPackedLinear
    @ParameterInfo(key: "pos_bias_u") var posBiasU: MLXArray
    @ParameterInfo(key: "pos_bias_v") var posBiasV: MLXArray

    override init() {
        let d = PhononArchitecture.modelDimension
        scale = pow(Float(headDimension), -0.5)
        _linearQ.wrappedValue = PhononPackedLinear(inputDimensions: d, outputDimensions: d)
        _linearK.wrappedValue = PhononPackedLinear(inputDimensions: d, outputDimensions: d)
        _linearV.wrappedValue = PhononPackedLinear(inputDimensions: d, outputDimensions: d)
        _linearOut.wrappedValue = PhononPackedLinear(inputDimensions: d, outputDimensions: d)
        _linearPos.wrappedValue = PhononPackedLinear(inputDimensions: d, outputDimensions: d)
        _posBiasU.wrappedValue = MLXArray.zeros([headCount, headDimension])
        _posBiasV.wrappedValue = MLXArray.zeros([headCount, headDimension])
    }

    func callAsFunction(_ x: MLXArray, positions: MLXArray) -> MLXArray {
        let batch = x.dim(0)
        let length = x.dim(1)
        let positionCount = positions.dim(1)

        let q = linearQ(x).reshaped(batch, length, headCount, headDimension)
        let k = linearK(x).reshaped(batch, length, headCount, headDimension).transposed(0, 2, 1, 3)
        let v = linearV(x).reshaped(batch, length, headCount, headDimension).transposed(0, 2, 1, 3)
        let p = linearPos(positions)
            .reshaped(1, positionCount, headCount, headDimension)
            .transposed(0, 2, 1, 3)

        let qU = (q + posBiasU.asType(q.dtype)).transposed(0, 2, 1, 3)
        let qV = (q + posBiasV.asType(q.dtype)).transposed(0, 2, 1, 3)

        // Relative-position scores, shifted so row i holds offsets i - j.
        var positional = matmul(qV, p.swappedAxes(-2, -1))
        positional = MLX.padded(
            positional,
            widths: [.init(0), .init(0), .init(0), .init((1, 0))]
        )
        positional = positional.reshaped(batch, headCount, positionCount + 1, length)
        positional = positional[0..., 0..., 1..., 0...]
            .reshaped(batch, headCount, length, positionCount)
        positional = positional[0..., 0..., 0..., ..<length]
            * MLXArray(scale).asType(positional.dtype)

        let attended = MLXFast.scaledDotProductAttention(
            queries: qU,
            keys: k,
            values: v,
            scale: scale,
            mask: .array(positional)
        )
        return linearOut(attended.transposed(0, 2, 1, 3).reshaped(batch, length, -1))
    }
}

final class PhononConformerBlock: Module {
    @ModuleInfo(key: "norm_feed_forward1") var normFeedForward1: LayerNorm
    @ModuleInfo(key: "feed_forward1") var feedForward1: PhononFeedForward
    @ModuleInfo(key: "norm_self_att") var normSelfAttention: LayerNorm
    @ModuleInfo(key: "self_attn") var selfAttention: PhononRelativeAttention
    @ModuleInfo(key: "norm_conv") var normConvolution: LayerNorm
    @ModuleInfo(key: "conv") var convolution: PhononConvolution
    @ModuleInfo(key: "norm_feed_forward2") var normFeedForward2: LayerNorm
    @ModuleInfo(key: "feed_forward2") var feedForward2: PhononFeedForward
    @ModuleInfo(key: "norm_out") var normOut: LayerNorm

    override init() {
        let d = PhononArchitecture.modelDimension
        _normFeedForward1.wrappedValue = LayerNorm(dimensions: d)
        _feedForward1.wrappedValue = PhononFeedForward()
        _normSelfAttention.wrappedValue = LayerNorm(dimensions: d)
        _selfAttention.wrappedValue = PhononRelativeAttention()
        _normConvolution.wrappedValue = LayerNorm(dimensions: d)
        _convolution.wrappedValue = PhononConvolution()
        _normFeedForward2.wrappedValue = LayerNorm(dimensions: d)
        _feedForward2.wrappedValue = PhononFeedForward()
        _normOut.wrappedValue = LayerNorm(dimensions: d)
    }

    func callAsFunction(_ x: MLXArray, positions: MLXArray) -> MLXArray {
        let half = MLXArray(Float(0.5)).asType(x.dtype)
        var y = x + half * feedForward1(normFeedForward1(x))
        y = y + selfAttention(normSelfAttention(y), positions: positions)
        y = y + convolution(normConvolution(y))
        y = y + half * feedForward2(normFeedForward2(y))
        return normOut(y)
    }
}

/// Three stride-2 stages (one full convolution, then two depthwise-separable
/// ones) reduce 10 ms mel frames to 80 ms encoder frames.
final class PhononSubsampling: Module {
    @ModuleInfo(key: "conv0") var conv0: Conv2d
    @ModuleInfo(key: "depthwise") var depthwise: [Conv2d]
    @ModuleInfo(key: "pointwise") var pointwise: [Conv2d]
    @ModuleInfo(key: "out") var out: Linear

    override init() {
        let channels = PhononArchitecture.subsamplingChannels
        let stages = Int(log2(Double(PhononArchitecture.subsamplingFactor)))
        var frequencies = PhononArchitecture.melFeatures
        for _ in 0..<stages {
            frequencies = (frequencies + 2 - 3) / 2 + 1
        }
        _conv0.wrappedValue = Conv2d(
            inputChannels: 1, outputChannels: channels,
            kernelSize: 3, stride: 2, padding: 1
        )
        _depthwise.wrappedValue = (1..<stages).map { _ in
            Conv2d(
                inputChannels: channels, outputChannels: channels,
                kernelSize: 3, stride: 2, padding: 1, groups: channels
            )
        }
        _pointwise.wrappedValue = (1..<stages).map { _ in
            Conv2d(inputChannels: channels, outputChannels: channels, kernelSize: 1)
        }
        _out.wrappedValue = Linear(channels * frequencies, PhononArchitecture.modelDimension)
    }

    /// `mel`: [batch, frames, features] → [batch, frames / 8, model].
    func callAsFunction(_ mel: MLXArray) -> MLXArray {
        var y = relu(conv0(mel.expandedDimensions(axis: 3)))
        for index in depthwise.indices {
            y = relu(pointwise[index](depthwise[index](y)))
        }
        let batch = y.dim(0)
        let frames = y.dim(1)
        // Channels before frequency, matching the PyTorch flatten order.
        y = y.transposed(0, 1, 3, 2).reshaped(batch, frames, -1)
        return out(y)
    }

    static func outputLength(forMelFrames frames: Int) -> Int {
        var length = frames
        for _ in 0..<Int(log2(Double(PhononArchitecture.subsamplingFactor))) {
            length = Int(floor(Double(length - 1) / 2)) + 1
        }
        return length
    }
}

final class PhononEncoder: Module {
    @ModuleInfo(key: "pre_encode") var preEncode: PhononSubsampling
    @ModuleInfo(key: "layers") var layers: [PhononConformerBlock]

    override init() {
        _preEncode.wrappedValue = PhononSubsampling()
        _layers.wrappedValue = (0..<PhononArchitecture.layerCount).map { _ in
            PhononConformerBlock()
        }
    }

    func callAsFunction(_ mel: MLXArray) -> MLXArray {
        var h = preEncode(mel)
        let positions = Self.relativePositions(length: h.dim(1)).asType(h.dtype)
        for layer in layers {
            h = layer(h, positions: positions)
        }
        return h
    }

    /// Sinusoidal embeddings for offsets length - 1 down to -(length - 1).
    static func relativePositions(length: Int) -> MLXArray {
        let d = PhononArchitecture.modelDimension
        let offsets = MLXArray(
            stride(from: Float(length - 1), through: Float(-(length - 1)), by: -1).map { $0 }
        ).expandedDimensions(axis: 1)
        let frequencies = exp(
            MLXArray(stride(from: 0, to: d, by: 2).map(Float.init))
                * MLXArray(-Float(log(10_000.0)) / Float(d))
        ).expandedDimensions(axis: 0)
        let angles = offsets * frequencies
        // Interleave sin/cos: even columns sine, odd columns cosine.
        let interleaved = MLX.stacked([sin(angles), cos(angles)], axis: 2)
        return interleaved.reshaped(1, 2 * length - 1, d)
    }
}

final class PhononLSTMLayer: Module {
    @ParameterInfo(key: "Wx") var inputWeight: MLXArray
    @ParameterInfo(key: "Wh") var hiddenWeight: MLXArray
    var bias: MLXArray

    init(inputSize: Int, hiddenSize: Int) {
        _inputWeight.wrappedValue = MLXArray.zeros([4 * hiddenSize, inputSize])
        _hiddenWeight.wrappedValue = MLXArray.zeros([4 * hiddenSize, hiddenSize])
        bias = MLXArray.zeros([4 * hiddenSize])
    }

    /// One time step. Gate order is input, forget, cell, output.
    func step(_ x: MLXArray, hidden: MLXArray, cell: MLXArray) -> (MLXArray, MLXArray) {
        let gates = addMM(addMM(bias, x, inputWeight.T), hidden, hiddenWeight.T)
        let pieces = gates.split(parts: 4, axis: -1)
        let nextCell = sigmoid(pieces[1]) * cell + sigmoid(pieces[0]) * tanh(pieces[2])
        let nextHidden = sigmoid(pieces[3]) * tanh(nextCell)
        return (nextHidden, nextCell)
    }
}

final class PhononPredictor: Module {
    @ModuleInfo(key: "embed") var embed: Embedding
    @ModuleInfo(key: "lstm") var lstm: [PhononLSTMLayer]

    override init() {
        let hidden = PhononArchitecture.predictionHidden
        _embed.wrappedValue = Embedding(
            embeddingCount: PhononArchitecture.vocabularySize + 1,
            dimensions: hidden
        )
        _lstm.wrappedValue = (0..<PhononArchitecture.predictionLayers).map { _ in
            PhononLSTMLayer(inputSize: hidden, hiddenSize: hidden)
        }
    }
}

final class PhononJoint: Module {
    @ModuleInfo(key: "enc") var encoderProjection: Linear
    @ModuleInfo(key: "pred") var predictorProjection: Linear
    @ModuleInfo(key: "out") var output: Linear

    override init() {
        _encoderProjection.wrappedValue = Linear(
            PhononArchitecture.modelDimension, PhononArchitecture.jointHidden
        )
        _predictorProjection.wrappedValue = Linear(
            PhononArchitecture.predictionHidden, PhononArchitecture.jointHidden
        )
        _output.wrappedValue = Linear(
            PhononArchitecture.jointHidden, PhononArchitecture.jointOutputs
        )
    }
}

final class PhononNetwork: Module {
    @ModuleInfo(key: "encoder") var encoder: PhononEncoder
    @ModuleInfo(key: "decoder") var predictor: PhononPredictor
    @ModuleInfo(key: "joint") var joint: PhononJoint

    override init() {
        _encoder.wrappedValue = PhononEncoder()
        _predictor.wrappedValue = PhononPredictor()
        _joint.wrappedValue = PhononJoint()
    }

    var packedLayers: [PhononPackedLinear] {
        encoder.layers.flatMap { layer in
            [
                layer.feedForward1.linear1, layer.feedForward1.linear2,
                layer.selfAttention.linearQ, layer.selfAttention.linearK,
                layer.selfAttention.linearV, layer.selfAttention.linearOut,
                layer.selfAttention.linearPos,
                layer.convolution.pointwiseConv1, layer.convolution.pointwiseConv2,
                layer.feedForward2.linear1, layer.feedForward2.linear2,
            ]
        }
    }

    /// One greedy TDT step with the whole decoder state on the GPU, so many
    /// steps can be queued before the host reads anything back.
    ///
    /// Inputs: projected encoder frames [frames, joint], time [], last token
    /// [1], LSTM hidden and cell [layers, 1, hidden], and the symbols emitted
    /// at the current frame []. Returns the next time, token, hidden, cell
    /// and symbol count, plus the emitted token or -1. Once time passes the
    /// last frame the step leaves the state unchanged.
    func decodeStep(_ inputs: [MLXArray]) -> [MLXArray] {
        let frames = inputs[0]
        let time = inputs[1]
        let token = inputs[2]
        let hidden = inputs[3]
        let cell = inputs[4]
        let symbols = inputs[5]

        let blank = MLXArray(Int32(PhononArchitecture.blankToken))
        let lastFrame = MLXArray(Int32(frames.dim(0) - 1))
        let active = time .<= lastFrame
        let frame = frames.take(minimum(time, lastFrame).reshaped([1]), axis: 0)

        // The prediction network sees silence for the initial blank.
        var x = predictor.embed(token)
        x = MLX.where((token .== blank).expandedDimensions(axis: -1), MLXArray.zeros(like: x), x)
        var nextHidden: [MLXArray] = []
        var nextCell: [MLXArray] = []
        for (index, layer) in predictor.lstm.enumerated() {
            let (h, c) = layer.step(x, hidden: hidden[index], cell: cell[index])
            nextHidden.append(h)
            nextCell.append(c)
            x = h
        }

        let combined = relu(frame + joint.predictorProjection(x.asType(frame.dtype)))
        let logits = joint.output(combined)[0]
        let predicted = logits[..<(PhononArchitecture.blankToken + 1)].argMax(axis: -1).asType(.int32)
        let durationIndex = logits[(PhononArchitecture.blankToken + 1)...].argMax(axis: -1)
        let duration = MLXArray(PhononArchitecture.durations.map(Int32.init)).take(durationIndex)

        // The predictor only advances when a token is emitted.
        let emitted = active .&& (predicted .!= blank)
        let nextToken = MLX.where(emitted, predicted.reshaped([1]), token)
        let keptHidden = MLX.where(emitted, MLX.stacked(nextHidden), hidden)
        let keptCell = MLX.where(emitted, MLX.stacked(nextCell), cell)

        // Advance by the predicted duration; after max_symbols emissions at
        // one frame, force a step forward.
        let count = symbols + 1
        let advanced = time + duration
        let stays = duration .== MLXArray(Int32(0))
        let overflow = stays .&& (count .>= MLXArray(Int32(PhononArchitecture.maxSymbolsPerStep)))
        let nextTime = MLX.where(overflow, advanced + 1, advanced)
        let nextSymbols = MLX.where(stays .&& logicalNot(overflow), count, MLXArray(Int32(0)))

        return [
            MLX.where(active, nextTime, time),
            nextToken,
            keptHidden,
            keptCell,
            MLX.where(active, nextSymbols, symbols),
            MLX.where(emitted, predicted, MLXArray(Int32(-1))),
        ]
    }
}
