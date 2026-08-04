import AVFoundation
import CoreGraphics
import XCTest
@testable import WhisprGo

final class WhisprGoTests: XCTestCase {
    func testModelCatalogHasUniqueIDsAndValidDefault() {
        XCTAssertEqual(Set(ModelCatalog.all.map(\.id)).count, ModelCatalog.all.count)
        XCTAssertEqual(ModelCatalog.model(id: ModelCatalog.defaultModelID).id, "local.parakeet.v3")
        XCTAssertEqual(ModelCatalog.model(id: ModelCatalog.defaultModelID).name, "Parakeet TDT 0.6B v3")
        XCTAssertTrue(ModelCatalog.all.contains(where: { !$0.isLocal }))
    }

    func testSanitizerRemovesNonSpeechTokensAndWhitespace() {
        let value = "  Hello   [BLANK_AUDIO]  world. (music)  "
        XCTAssertEqual(TextSanitizer.sanitize(value), "Hello world.")
    }

    func testWAVHeaderAndLength() {
        let data = WAVEncoder.encode(samples: [0, 0.5, -0.5, 1])
        XCTAssertEqual(data.count, 44 + 8)
        XCTAssertEqual(String(data: data[0..<4], encoding: .utf8), "RIFF")
        XCTAssertEqual(String(data: data[8..<12], encoding: .utf8), "WAVE")
        XCTAssertEqual(String(data: data[36..<40], encoding: .utf8), "data")
    }

    func testAudioLevelMeterKeepsNewestValue() {
        let meter = AudioLevelMeter()
        meter.store(0.125)
        meter.store(0.75)
        XCTAssertEqual(meter.load(), 0.75)
        meter.reset()
        XCTAssertEqual(meter.load(), 0)
    }

    func testAudioCallbackGateChangesImmediately() {
        let gate = AtomicFlag()
        XCTAssertFalse(gate.load())
        gate.store(true)
        XCTAssertTrue(gate.load())
        gate.store(false)
        XCTAssertFalse(gate.load())
    }

    func testMicrophoneResamplerPreservesVariablePacketDuration() throws {
        let sourceRate = 48_000.0
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sourceRate,
            channels: 1,
            interleaved: false
        ))
        let resampler = try MicrophoneResampler(
            inputFormat: format,
            targetSampleRate: AudioCapture.sampleRate
        )

        let packetPattern = [257, 1_024, 4_800, 97, 10_000, 333]
        var sourceOffset = 0
        var packetIndex = 0
        var converted = [Float]()
        while sourceOffset < Int(sourceRate) {
            let requested = packetPattern[packetIndex % packetPattern.count]
            let count = min(requested, Int(sourceRate) - sourceOffset)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(count)
            ))
            buffer.frameLength = AVAudioFrameCount(count)
            let channel = try XCTUnwrap(buffer.floatChannelData?[0])
            for index in 0..<count {
                let phase = 2 * Double.pi * 440 * Double(sourceOffset + index) / sourceRate
                channel[index] = Float(sin(phase) * 0.5)
            }
            try resampler.withConvertedSamples(from: buffer) { samples in
                converted.append(contentsOf: samples)
            }
            sourceOffset += count
            packetIndex += 1
        }

        let convertedDuration = Double(converted.count) / AudioCapture.sampleRate
        XCTAssertEqual(convertedDuration, 1, accuracy: 0.03)
        XCTAssertTrue(converted.allSatisfy(\.isFinite))
        XCTAssertGreaterThan(converted.map(abs).max() ?? 0, 0.25)
    }

    func testFunctionKeySchedulesAndEndsPushToTalk() {
        var state = HotkeyGestureState()
        XCTAssertEqual(
            state.consume(flags: [.maskSecondaryFn], pushToTalkIsActive: false),
            [.schedulePushToTalk]
        )
        XCTAssertEqual(
            state.consume(flags: [], pushToTalkIsActive: true),
            [.cancelPendingPushToTalk, .endPushToTalk]
        )
    }

    func testChordCancelsPendingPushToTalkAndTogglesOnce() {
        var state = HotkeyGestureState()
        _ = state.consume(flags: [.maskSecondaryFn], pushToTalkIsActive: false)
        XCTAssertEqual(
            state.consume(
                flags: [.maskSecondaryFn, .maskShift],
                pushToTalkIsActive: false
            ),
            [.cancelPendingPushToTalk, .toggle]
        )
        XCTAssertEqual(
            state.consume(
                flags: [.maskSecondaryFn, .maskShift],
                pushToTalkIsActive: false
            ),
            []
        )
    }
}
