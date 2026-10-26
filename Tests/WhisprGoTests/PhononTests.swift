import Foundation
import MLX
import XCTest
@testable import WhisprGo

final class PhononTests: XCTestCase {
    func testFiveValueRecordRepacksIntoExactTwoBitPlanes() throws {
        // Two rows of 128 columns covering every code with both magnitudes.
        let rows = 2
        let columns = 128
        var codes = [[UInt8]](repeating: [], count: rows)
        var isHigh = [[Bool]](repeating: [], count: rows)
        for row in 0..<rows {
            for column in 0..<columns {
                codes[row].append(UInt8((column + row) % 3))
                isHigh[row].append((column / 3 + row) % 2 == 0)
            }
        }
        let low: [Float] = [0.25, 0.5]
        let high: [Float] = [1.5, 3.0]

        var blob = [UInt8]()
        let bytesPerRow = (columns + 4) / 5
        for row in 0..<rows {
            for byteIndex in 0..<bytesPerRow {
                var value = 0
                var place = 1
                for digit in 0..<5 {
                    let column = byteIndex * 5 + digit
                    value += Int(column < columns ? codes[row][column] : 1) * place
                    place *= 3
                }
                blob.append(UInt8(value))
            }
        }
        var bits = [Bool]()
        for row in 0..<rows {
            for column in 0..<columns where codes[row][column] != 1 {
                bits.append(isHigh[row][column])
            }
        }
        var bitBytes = [UInt8](repeating: 0, count: (bits.count + 7) / 8)
        for (index, bit) in bits.enumerated() where bit {
            bitBytes[index / 8] |= 1 << UInt8(index % 8)
        }
        blob += bitBytes
        for value in low + high {
            withUnsafeBytes(of: Float16(value).bitPattern.littleEndian) { blob += $0 }
        }

        let planes = try blob.withUnsafeBytes { raw in
            try PhononContainerConverter.decodeFiveValue(raw, shape: [rows, columns], name: "test")
        }

        try Device.withDefaultDevice(.cpu) {
            let lo = MLXArray(planes.low, [rows], dtype: .float16).asType(.float32)
            let delta = MLXArray(planes.high, [rows], dtype: .float16).asType(.float32) - lo
            let groups = columns / PhononArchitecture.packedGroupSize
            let baseScales = broadcast(lo.expandedDimensions(axis: 1), to: [rows, groups])
            let residualScales = broadcast(delta.expandedDimensions(axis: 1), to: [rows, groups])
            let dense = dequantized(
                MLXArray(planes.base, [rows, columns / 16]),
                scales: baseScales, biases: -baseScales,
                groupSize: PhononArchitecture.packedGroupSize, bits: 2
            ) + dequantized(
                MLXArray(planes.residual, [rows, columns / 16]),
                scales: residualScales, biases: -residualScales,
                groupSize: PhononArchitecture.packedGroupSize, bits: 2
            )
            let values = dense.asArray(Float.self)
            for row in 0..<rows {
                for column in 0..<columns {
                    let sign = Float(Int(codes[row][column]) - 1)
                    let expected = sign * (isHigh[row][column] ? high[row] : low[row])
                    XCTAssertEqual(values[row * columns + column], expected, accuracy: 1e-6)
                }
            }
        }
    }

    func testFiveValueRecordRejectsWrongLength() {
        let blob = [UInt8](repeating: 121, count: 26 + 8 + 1)
        XCTAssertThrowsError(try blob.withUnsafeBytes { raw in
            try PhononContainerConverter.decodeFiveValue(raw, shape: [1, 128], name: "test")
        })
    }

    func testWindowPlannerKeepsShortAudioWholeAndCutsLongAudioInPauses() {
        let rate = PhononArchitecture.sampleRate
        let short = [Float](repeating: 0.1, count: 30 * rate)
        XCTAssertEqual(PhononWindowPlanner.plan(short), [0..<short.count])

        // Loud speech with a one-second pause starting at 27 s.
        var long = [Float](repeating: 0.2, count: 50 * rate)
        for index in (27 * rate)..<(28 * rate) {
            long[index] = 0
        }
        let windows = PhononWindowPlanner.plan(long)
        XCTAssertEqual(windows.count, 2)
        XCTAssertEqual(windows.first?.lowerBound, 0)
        XCTAssertEqual(windows.last?.upperBound, long.count)
        let cut = try? XCTUnwrap(windows.first?.upperBound)
        XCTAssertEqual(Double(cut ?? 0) / Double(rate), 27.5, accuracy: 0.05)
    }

    func testFinalSigmaOnlyChangesWordEndings() {
        XCTAssertEqual(
            PhononTranscriber.applyFinalSigma("Καλημέρα σασ. Ο κόσμοσ, σήμερα"),
            "Καλημέρα σας. Ο κόσμος, σήμερα"
        )
        XCTAssertEqual(PhononTranscriber.applyFinalSigma("plain text"), "plain text")
    }

    func testDetokenizeJoinsPiecesAndDropsSpecialTokens() {
        let vocabulary = ["<unk>", "<|nospeech|>", "\u{2581}Hello", ",", "\u{2581}wor", "ld"]
        XCTAssertEqual(
            PhononTranscriber.detokenize([1, 2, 3, 4, 5, 0, 99], vocabulary: vocabulary),
            " Hello, world"
        )
    }

    func testPhononVariantsArePinnedToExactRevisions() {
        for variant in [PhononVariant.multilingual, .english] {
            XCTAssertEqual(variant.revision.count, 40)
            XCTAssertEqual(variant.archiveSHA256.count, 64)
            XCTAssertTrue(variant.archiveURL.absoluteString.hasPrefix("https://huggingface.co/FermionResearch/"))
            XCTAssertTrue(variant.archiveURL.absoluteString.contains(variant.revision))
        }
    }

    /// End-to-end check against transcripts from Fermion's own runtime.
    /// Set PHONON_TEST_ARCHIVES to a folder holding the published
    /// `.bps.tar.zst` files and PHONON_TEST_AUDIO to a folder with WAV files
    /// and a `reference.json`, and put `mlx.metallib` next to the test binary.
    func testTranscriptsMatchFermionReferenceRuntime() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let archives = environment["PHONON_TEST_ARCHIVES"],
              let audio = environment["PHONON_TEST_AUDIO"]
        else {
            throw XCTSkip("Set PHONON_TEST_ARCHIVES and PHONON_TEST_AUDIO to run.")
        }
        let audioDirectory = URL(fileURLWithPath: audio, isDirectory: true)
        let reference = try JSONDecoder().decode(
            [String: String].self,
            from: Data(contentsOf: audioDirectory.appendingPathComponent("reference.json"))
        )

        for (profile, variant) in [("five-value-25", PhononVariant.multilingual), ("five-value-25-en", .english)] {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("phonon-test-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }

            let archive = URL(fileURLWithPath: archives).appendingPathComponent(variant.archiveName)
            XCTAssertEqual(try PhononInstaller.sha256(of: archive), variant.archiveSHA256)

            var started = Date()
            let extracted = root.appendingPathComponent("extracted")
            let digests = try PhononInstaller.extract(
                archive: archive,
                files: ["config.json", "model.fermion"],
                into: extracted
            )
            XCTAssertEqual(digests["model.fermion"], variant.containerSHA256)
            let converted = try PhononContainerConverter.convert(
                container: extracted.appendingPathComponent("model.fermion"),
                configuration: extracted.appendingPathComponent("config.json")
            )
            let directory = root.appendingPathComponent("model")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let files = PhononInstalledFiles(directory: directory)
            try save(arrays: converted.weights, url: files.weights)
            try JSONEncoder().encode(converted.vocabulary).write(to: files.vocabulary)
            print("[\(profile)] unpack + convert: \(String(format: "%.2f", Date().timeIntervalSince(started))) s")

            started = Date()
            let transcriber = try PhononTranscriber(directory: directory, variant: variant)
            transcriber.warmUp()
            print("[\(profile)] load + warm-up: \(String(format: "%.2f", Date().timeIntervalSince(started))) s")

            let names = try FileManager.default.contentsOfDirectory(atPath: audio)
                .filter { $0.hasSuffix(".wav") }
                .sorted()
            for name in names {
                guard let expected = reference["\(profile):\(name)"] else { continue }
                let samples = try Self.readMonoWAV(audioDirectory.appendingPathComponent(name))
                started = Date()
                let text = transcriber.transcribe(samples)
                let elapsed = Date().timeIntervalSince(started)
                print("[\(profile)] \(name) (\(samples.count / 16_000) s audio, \(String(format: "%.3f", elapsed)) s): \(text)")
                // GPU reductions can flip a borderline punctuation token, so
                // words must match exactly and punctuation differences are logged.
                if text != expected {
                    print("[\(profile)] \(name) differs from reference: \(expected)")
                }
                XCTAssertEqual(Self.words(text), Self.words(expected), "\(profile) \(name)")
            }
        }
    }

    private static func words(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    private static func readMonoWAV(_ url: URL) throws -> [Float] {
        let data = try Data(contentsOf: url)
        var offset = 12
        while offset + 8 <= data.count {
            let id = String(decoding: data[offset..<(offset + 4)], as: UTF8.self)
            let size = data[(offset + 4)..<(offset + 8)].withUnsafeBytes {
                Int(UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)))
            }
            if id == "data" {
                return data[(offset + 8)..<(offset + 8 + size)].withUnsafeBytes { raw in
                    raw.bindMemory(to: Int16.self).map { Float(Int16(littleEndian: $0)) / 32_768 }
                }
            }
            offset += 8 + size + (size & 1)
        }
        throw CocoaError(.fileReadCorruptFile)
    }
}
