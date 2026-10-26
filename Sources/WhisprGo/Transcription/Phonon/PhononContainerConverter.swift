import Foundation
import MLX

/// Converts a `fermion-five-value-parakeet-v1` container, as published by
/// Fermion Research, into the MLX weights `PhononNetwork` loads.
///
/// Container layout: an 8-byte little-endian header length, a JSON header
/// whose `index` lists every record (`n` name, `k` kind, `shape`, `b` bytes),
/// then the records in index order. Kinds:
/// - `five_value`: per row, base-3 codes (five per byte, little digit first;
///   0 = -1, 1 = 0, 2 = +1), then one little-endian bit per nonzero code
///   choosing the row's `hi` over its `lo` magnitude, then fp16 `lo[rows]`
///   and fp16 `hi[rows]`.
/// - `int6` / `int8`: symmetric per-row codes (int6 packs four 6-bit values,
///   offset by 32, into three bytes) followed by fp16 row scales.
/// - `fp16`: raw values.
enum PhononContainerConverter {
    static let format = "fermion-five-value-parakeet-v1"

    enum ConversionError: LocalizedError {
        case malformed(String)
        case unexpectedConfiguration(String)

        var errorDescription: String? {
            switch self {
            case let .malformed(detail):
                return "The downloaded Phonon model is damaged (\(detail))."
            case let .unexpectedConfiguration(detail):
                return "This Phonon model uses an unsupported layout (\(detail))."
            }
        }
    }

    struct Output {
        var weights: [String: MLXArray]
        var vocabulary: [String]
    }

    private struct Header: Decodable {
        struct Record: Decodable {
            let n: String
            let k: String
            let shape: [Int]
            let b: Int
        }
        let format: String
        let index: [Record]
    }

    static func convert(container: URL, configuration: URL) throws -> Output {
        let vocabulary = try validatedVocabulary(configuration: configuration)
        let data = try Data(contentsOf: container, options: .alwaysMapped)
        guard data.count > 8 else { throw ConversionError.malformed("container too short") }

        let headerLength = data.withUnsafeBytes { raw in
            Int(UInt64(littleEndian: raw.loadUnaligned(as: UInt64.self)))
        }
        guard headerLength > 0, 8 + headerLength <= data.count else {
            throw ConversionError.malformed("invalid header length")
        }
        let header = try JSONDecoder().decode(
            Header.self,
            from: data.subdata(in: 8..<(8 + headerLength))
        )
        guard header.format == format else {
            throw ConversionError.unexpectedConfiguration("container format \(header.format)")
        }

        var offset = 8 + headerLength
        var records: [(record: Header.Record, range: Range<Int>)] = []
        for record in header.index {
            guard record.b >= 0, offset + record.b <= data.count else {
                throw ConversionError.malformed("record \(record.n) is truncated")
            }
            records.append((record, offset..<(offset + record.b)))
            offset += record.b
        }
        guard offset == data.count else {
            throw ConversionError.malformed("trailing bytes after the last record")
        }

        var weights: [String: MLXArray] = [:]
        var lstmBiases: [String: MLXArray] = [:]

        // Five-value records dominate the work and decode independently.
        let packed = records.filter { $0.record.k == "five_value" }
        guard packed.count == PhononArchitecture.layerCount * 11 else {
            throw ConversionError.unexpectedConfiguration("\(packed.count) packed encoder projections")
        }
        let batchSize = 16
        for batchStart in stride(from: 0, to: packed.count, by: batchSize) {
            let batch = Array(packed[batchStart..<min(batchStart + batchSize, packed.count)])
            var decoded = [Result<PackedPlanes, Error>?](repeating: nil, count: batch.count)
            decoded.withUnsafeMutableBufferPointer { results in
                DispatchQueue.concurrentPerform(iterations: batch.count) { index in
                    let entry = batch[index]
                    results[index] = Result {
                        try data.withUnsafeBytes { raw in
                            try decodeFiveValue(
                                UnsafeRawBufferPointer(rebasing: raw[entry.range]),
                                shape: entry.record.shape,
                                name: entry.record.n
                            )
                        }
                    }
                }
            }
            for (entry, result) in zip(batch, decoded) {
                let planes = try result!.get()
                let key = try packedKey(entry.record.n)
                let rows = entry.record.shape[0]
                let words = entry.record.shape[1] / 16
                weights[key + ".base_q"] = MLXArray(planes.base, [rows, words])
                weights[key + ".residual_q"] = MLXArray(planes.residual, [rows, words])
                weights[key + ".row_lo"] = MLXArray(planes.low, [rows], dtype: .float16)
                weights[key + ".row_hi"] = MLXArray(planes.high, [rows], dtype: .float16)
            }
        }

        for (record, range) in records where record.k != "five_value" {
            if record.n.hasSuffix(".num_batches_tracked") { continue }
            let blob = data.subdata(in: range)
            let value = try denseValue(blob, kind: record.k, shape: record.shape, name: record.n)

            if record.n.hasPrefix("decoder.lstm.bias_") {
                lstmBiases[record.n] = value
                continue
            }
            let (key, transformed) = try denseKey(record.n, value: value)
            weights[key] = transformed.asType(PhononTranscriber.computeDType)
        }

        for layer in 0..<PhononArchitecture.predictionLayers {
            guard let input = lstmBiases["decoder.lstm.bias_ih_l\(layer)"],
                  let hidden = lstmBiases["decoder.lstm.bias_hh_l\(layer)"]
            else {
                throw ConversionError.unexpectedConfiguration("missing LSTM bias for layer \(layer)")
            }
            // Summed in fp32, then stored the way the reference loader does.
            weights["decoder.lstm.\(layer).bias"] = (input.asType(.float32) + hidden.asType(.float32))
                .asType(.float16)
                .asType(PhononTranscriber.computeDType)
        }

        eval(Array(weights.values))
        return Output(weights: weights, vocabulary: vocabulary)
    }

    // MARK: - Configuration

    private static func validatedVocabulary(configuration: URL) throws -> [String] {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: configuration))
        guard let config = object as? [String: Any],
              let encoder = config["encoder"] as? [String: Any],
              let decoder = config["decoder"] as? [String: Any],
              let joint = config["joint"] as? [String: Any],
              let preprocessor = config["preprocessor"] as? [String: Any],
              let decoding = config["decoding"] as? [String: Any],
              let vocabulary = joint["vocabulary"] as? [String]
        else {
            throw ConversionError.unexpectedConfiguration("configuration is missing sections")
        }

        func require<Value: Equatable>(_ actual: Any?, _ expected: Value, _ name: String) throws {
            guard let value = actual as? Value, value == expected else {
                throw ConversionError.unexpectedConfiguration("\(name) is \(actual.map { "\($0)" } ?? "missing")")
            }
        }
        try require(encoder["n_layers"], PhononArchitecture.layerCount, "encoder.n_layers")
        try require(encoder["d_model"], PhononArchitecture.modelDimension, "encoder.d_model")
        try require(encoder["n_heads"], PhononArchitecture.headCount, "encoder.n_heads")
        try require(encoder["feat_in"], PhononArchitecture.melFeatures, "encoder.feat_in")
        try require(encoder["ff_expansion_factor"], PhononArchitecture.feedForwardExpansion, "encoder.ff_expansion_factor")
        try require(encoder["conv_kernel_size"], PhononArchitecture.convolutionKernel, "encoder.conv_kernel_size")
        try require(encoder["subsampling"], "dw_striding", "encoder.subsampling")
        try require(encoder["subsampling_factor"], PhononArchitecture.subsamplingFactor, "encoder.subsampling_factor")
        try require(encoder["subsampling_conv_channels"], PhononArchitecture.subsamplingChannels, "encoder.subsampling_conv_channels")
        try require(encoder["self_attention_model"], "rel_pos", "encoder.self_attention_model")
        try require(encoder["xscaling"], false, "encoder.xscaling")
        try require(encoder["use_bias"], false, "encoder.use_bias")
        try require(decoder["vocab_size"], PhononArchitecture.vocabularySize, "decoder.vocab_size")
        let prediction = decoder["prednet"] as? [String: Any]
        try require(prediction?["pred_hidden"], PhononArchitecture.predictionHidden, "decoder.prednet.pred_hidden")
        try require(prediction?["pred_rnn_layers"], PhononArchitecture.predictionLayers, "decoder.prednet.pred_rnn_layers")
        try require(joint["num_extra_outputs"], PhononArchitecture.durations.count, "joint.num_extra_outputs")
        try require((joint["jointnet"] as? [String: Any])?["activation"], "relu", "joint.jointnet.activation")
        try require(decoding["durations"], PhononArchitecture.durations, "decoding.durations")
        try require(preprocessor["features"], PhononArchitecture.melFeatures, "preprocessor.features")
        try require(preprocessor["n_fft"], PhononArchitecture.fftLength, "preprocessor.n_fft")
        try require(preprocessor["normalize"], "per_feature", "preprocessor.normalize")
        guard vocabulary.count == PhononArchitecture.vocabularySize else {
            throw ConversionError.unexpectedConfiguration("vocabulary has \(vocabulary.count) entries")
        }
        return vocabulary
    }

    // MARK: - Names

    private static let attentionNames = [
        "q_proj": "linear_q", "k_proj": "linear_k", "v_proj": "linear_v",
        "o_proj": "linear_out", "relative_k_proj": "linear_pos",
    ]

    private static func packedKey(_ name: String) throws -> String {
        let parts = name.split(separator: ".", maxSplits: 3).map(String.init)
        guard parts.count == 4, parts[0] == "encoder", parts[1] == "layers", Int(parts[2]) != nil else {
            throw ConversionError.unexpectedConfiguration("packed record \(name)")
        }
        let prefix = "encoder.layers.\(parts[2])."
        let tail = parts[3]
        if tail.hasPrefix("self_attn."), let mapped = attentionNames[String(tail.dropFirst(10))] {
            return prefix + "self_attn." + mapped
        }
        let projections: Set<String> = [
            "feed_forward1.linear1", "feed_forward1.linear2",
            "feed_forward2.linear1", "feed_forward2.linear2",
            "conv.pointwise_conv1", "conv.pointwise_conv2",
        ]
        guard projections.contains(tail) else {
            throw ConversionError.unexpectedConfiguration("packed record \(name)")
        }
        return prefix + tail
    }

    /// Maps a dense Hugging Face tensor name to the local module path and
    /// moves convolution weights to MLX's channels-last layout.
    private static func denseKey(_ name: String, value: MLXArray) throws -> (String, MLXArray) {
        let subsampling = [
            "0": "conv0", "2": "depthwise.0", "3": "pointwise.0",
            "5": "depthwise.1", "6": "pointwise.1",
        ]
        let parts = name.split(separator: ".").map(String.init)

        if parts.count == 5, parts[0] == "encoder", parts[1] == "subsampling", parts[2] == "layers",
           let module = subsampling[parts[3]]
        {
            // [out, in, height, width] → [out, height, width, in]
            let moved = parts[4] == "weight" ? value.transposed(0, 2, 3, 1) : value
            return ("encoder.pre_encode.\(module).\(parts[4])", moved)
        }
        if parts.count == 4, parts[0] == "encoder", parts[1] == "subsampling", parts[2] == "linear" {
            return ("encoder.pre_encode.out.\(parts[3])", value)
        }
        if parts.count >= 5, parts[0] == "encoder", parts[1] == "layers", Int(parts[2]) != nil {
            let prefix = "encoder.layers.\(parts[2])."
            let tail = parts[3...].joined(separator: ".")
            switch tail {
            case "self_attn.bias_u":
                return (prefix + "self_attn.pos_bias_u", value)
            case "self_attn.bias_v":
                return (prefix + "self_attn.pos_bias_v", value)
            case "conv.depthwise_conv.weight":
                // [channels, 1, kernel] → [channels, kernel, 1]
                return (prefix + tail, value.transposed(0, 2, 1))
            case "conv.norm.weight", "conv.norm.bias", "conv.norm.running_mean", "conv.norm.running_var":
                return (prefix + "conv.batch_norm." + parts[5], value)
            default:
                let norms: Set<String> = [
                    "norm_feed_forward1", "norm_self_att", "norm_conv",
                    "norm_feed_forward2", "norm_out",
                ]
                if parts.count == 5, norms.contains(parts[3]) {
                    return (prefix + tail, value)
                }
            }
        }
        switch name {
        case "encoder_projector.weight", "encoder_projector.bias":
            return ("joint.enc." + parts[1], value)
        case "decoder.decoder_projector.weight", "decoder.decoder_projector.bias":
            return ("joint.pred." + parts[2], value)
        case "joint.head.weight", "joint.head.bias":
            return ("joint.out." + parts[2], value)
        case "decoder.embedding.weight":
            return ("decoder.embed.weight", value)
        default:
            break
        }
        if parts.count == 3, parts[0] == "decoder", parts[1] == "lstm" {
            for (prefix, key) in [("weight_ih_l", "Wx"), ("weight_hh_l", "Wh")] {
                if parts[2].hasPrefix(prefix), let layer = Int(parts[2].dropFirst(prefix.count)) {
                    return ("decoder.lstm.\(layer).\(key)", value)
                }
            }
        }
        throw ConversionError.unexpectedConfiguration("unmapped tensor \(name)")
    }

    // MARK: - Records

    private static func denseValue(_ blob: Data, kind: String, shape: [Int], name: String) throws -> MLXArray {
        let count = shape.reduce(1, *)
        switch kind {
        case "fp16":
            guard blob.count == 2 * count else {
                throw ConversionError.malformed("\(name) has \(blob.count) bytes")
            }
            return MLXArray(blob, shape, dtype: .float16)
        case "int6", "int8":
            guard let rows = shape.first, rows > 0, count % rows == 0 else {
                throw ConversionError.malformed("\(name) has shape \(shape)")
            }
            let scaleBytes = 2 * rows
            guard blob.count > scaleBytes else {
                throw ConversionError.malformed("\(name) has \(blob.count) bytes")
            }
            let body = blob.prefix(blob.count - scaleBytes)
            let codes: [Int8]
            if kind == "int8" {
                guard body.count >= count else { throw ConversionError.malformed("\(name) is short") }
                codes = body.prefix(count).map { Int8(bitPattern: $0) }
            } else {
                codes = try unpackInt6(body, count: count, name: name)
            }
            let scales = MLXArray(blob.suffix(scaleBytes), [rows, 1], dtype: .float16)
            let values = MLXArray(codes, [rows, count / rows]).asType(.float32)
                * scales.asType(.float32)
            return values.reshaped(shape)
        default:
            throw ConversionError.unexpectedConfiguration("record kind \(kind) for \(name)")
        }
    }

    private static func unpackInt6(_ body: Data, count: Int, name: String) throws -> [Int8] {
        guard body.count % 3 == 0, body.count / 3 * 4 >= count else {
            throw ConversionError.malformed("\(name) int6 body has \(body.count) bytes")
        }
        var codes = [Int8](repeating: 0, count: count)
        body.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            codes.withUnsafeMutableBufferPointer { output in
                var index = 0
                var byte = 0
                while index < count {
                    let packed = UInt32(bytes[byte])
                        | UInt32(bytes[byte + 1]) << 8
                        | UInt32(bytes[byte + 2]) << 16
                    byte += 3
                    for shift in stride(from: 0, through: 18, by: 6) where index < count {
                        output[index] = Int8(Int((packed >> UInt32(shift)) & 0x3F) - 32)
                        index += 1
                    }
                }
            }
        }
        return codes
    }

    struct PackedPlanes {
        var base: [UInt32]
        var residual: [UInt32]
        var low: Data
        var high: Data
    }

    /// Base-3 digits of every byte value below 243, five per byte.
    private static let tritTable: [UInt8] = (0..<243).flatMap { value -> [UInt8] in
        var remaining = value
        return (0..<5).map { _ in
            defer { remaining /= 3 }
            return UInt8(remaining % 3)
        }
    }

    /// Repacks one five-value record into two MLX 2-bit affine planes
    /// (sixteen codes per word, lowest bits first). With scales `lo` and
    /// `hi - lo` and biases of minus those scales, code 0 is -scale, 1 is 0
    /// and 2 is +scale, so base + residual reproduces {0, ±lo, ±hi} exactly.
    static func decodeFiveValue(
        _ blob: UnsafeRawBufferPointer,
        shape: [Int],
        name: String
    ) throws -> PackedPlanes {
        guard shape.count == 2, shape[0] > 0,
              shape[1] > 0, shape[1] % PhononArchitecture.packedGroupSize == 0
        else {
            throw ConversionError.unexpectedConfiguration("\(name) has shape \(shape)")
        }
        let rows = shape[0]
        let columns = shape[1]
        let bytesPerRow = (columns + 4) / 5
        let codeBytes = rows * bytesPerRow
        let wordsPerRow = columns / 16
        guard blob.count >= codeBytes + 4 * rows else {
            throw ConversionError.malformed("\(name) is truncated")
        }
        let bytes = blob.bindMemory(to: UInt8.self)

        // Count nonzero codes to locate the magnitude bits and the palettes.
        var nonzero = 0
        try tritTable.withUnsafeBufferPointer { table in
            for row in 0..<rows {
                let rowStart = row * bytesPerRow
                for byteIndex in 0..<bytesPerRow {
                    let value = Int(bytes[rowStart + byteIndex])
                    guard value < 243 else {
                        throw ConversionError.malformed("\(name) has an invalid code byte")
                    }
                    let digits = min(5, columns - byteIndex * 5)
                    for digit in 0..<digits where table[value * 5 + digit] != 1 {
                        nonzero += 1
                    }
                }
            }
        }
        let bitBytes = (nonzero + 7) / 8
        guard blob.count == codeBytes + bitBytes + 4 * rows else {
            throw ConversionError.malformed("\(name) has \(blob.count) bytes")
        }

        var base = [UInt32](repeating: 0, count: rows * wordsPerRow)
        var residual = [UInt32](repeating: 0, count: rows * wordsPerRow)
        tritTable.withUnsafeBufferPointer { table in
            base.withUnsafeMutableBufferPointer { basePlane in
                residual.withUnsafeMutableBufferPointer { residualPlane in
                    var bit = 0
                    for row in 0..<rows {
                        let rowStart = row * bytesPerRow
                        let wordStart = row * wordsPerRow
                        for column in 0..<columns {
                            let code = table[Int(bytes[rowStart + column / 5]) * 5 + column % 5]
                            var residualCode: UInt32 = 1
                            if code != 1 {
                                let isHigh = bytes[codeBytes + bit >> 3] >> UInt8(bit & 7) & 1 == 1
                                bit += 1
                                if isHigh { residualCode = UInt32(code) }
                            }
                            let word = wordStart + column >> 4
                            let shift = UInt32(column & 15) << 1
                            basePlane[word] |= UInt32(code) << shift
                            residualPlane[word] |= residualCode << shift
                        }
                    }
                }
            }
        }

        let paletteStart = codeBytes + bitBytes
        return PackedPlanes(
            base: base,
            residual: residual,
            low: Data(UnsafeRawBufferPointer(rebasing: blob[paletteStart..<(paletteStart + 2 * rows)])),
            high: Data(UnsafeRawBufferPointer(
                rebasing: blob[(paletteStart + 2 * rows)..<(paletteStart + 4 * rows)]
            ))
        )
    }
}
