import Foundation
import XCTest
@testable import WhisprGo

/// The latency work shared with ChatGPT Mode, applied to Pro Mode's
/// Gemini and OpenAI clients.
final class ProModeSpeedTests: XCTestCase {
    private var session: URLSession!
    private let speech = (0..<32_000).map { sin(Float($0) * 0.06) * 0.3 }

    override func setUp() {
        super.setUp()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProModeURLProtocol.self]
        session = URLSession(configuration: configuration)
    }

    override func tearDown() {
        ProModeURLProtocol.handler = nil
        session = nil
        super.tearDown()
    }

    func testADTSEncoderWritesSmallAACForGemini() throws {
        let encoded = try CompressedAudioEncoder.encodeADTS(samples: speech)
        XCTAssertEqual(encoded.contentType, "audio/aac")
        XCTAssertEqual(encoded.fileExtension, "aac")
        // ADTS frames start with a 12-bit sync word.
        XCTAssertEqual(encoded.data[0], 0xFF)
        XCTAssertEqual(encoded.data[1] & 0xF0, 0xF0)
        XCTAssertLessThan(encoded.data.count, WAVEncoder.encode(samples: speech).count / 4)
    }

    func testGeminiSendsTrimmedAACInlineInOneRequest() async throws {
        let silence = [Float](repeating: 0, count: 32_000)
        let counter = RequestCounter()
        ProModeURLProtocol.handler = { request in
            counter.increment()
            let url = try XCTUnwrap(request.url)
            XCTAssertEqual(url.path, "/v1beta/interactions")
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), "test-key")
            let body = try ProModeURLProtocol.body(for: request)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let input = try XCTUnwrap((json["input"] as? [[String: Any]])?.first)
            XCTAssertEqual(input["type"] as? String, "audio")
            XCTAssertEqual(input["mime_type"] as? String, "audio/aac")
            XCTAssertNil(input["uri"])
            let audio = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(input["data"] as? String)))
            XCTAssertEqual(audio[0], 0xFF)
            // Six seconds of WAV would be 192 kB. Trimmed AAC is far smaller.
            XCTAssertLessThan(audio.count, 20_000)
            let data = Data(#"{"status":"completed","steps":[{"type":"model_output","content":[{"type":"text","text":"Ready."}]}]}"#.utf8)
            return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
        }

        let text = try await GeminiTranscriptionClient(apiKey: "test-key", session: session)
            .transcribe(samples: silence + speech + silence, customVocabulary: [])
        XCTAssertEqual(text, "Ready.")
        XCTAssertEqual(counter.value, 1)
    }

    func testGeminiServerErrorOnInlineRequestDoesNotFallBackToUpload() async throws {
        let counter = RequestCounter()
        ProModeURLProtocol.handler = { request in
            counter.increment()
            let url = try XCTUnwrap(request.url)
            XCTAssertEqual(url.path, "/v1beta/interactions")
            let data = Data(#"{"error":{"message":"Overloaded"}}"#.utf8)
            return (HTTPURLResponse(url: url, statusCode: 503, httpVersion: nil, headerFields: nil)!, data)
        }

        do {
            _ = try await GeminiTranscriptionClient(apiKey: "test-key", session: session)
                .transcribe(samples: speech, customVocabulary: [])
            XCTFail("Expected an error")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Overloaded")
        }
        XCTAssertEqual(counter.value, 1)
    }

    func testOpenAITranscriptionUploadsM4A() async throws {
        ProModeURLProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
            let body = try ProModeURLProtocol.body(for: request)
            let text = String(decoding: body.prefix(600), as: UTF8.self)
            XCTAssertTrue(text.contains("gpt-4o-transcribe"))
            XCTAssertTrue(text.contains(#"filename="dictation.m4a""#))
            XCTAssertTrue(text.contains("Content-Type: audio/mp4"))
            XCTAssertLessThan(body.count, WAVEncoder.encode(samples: self.speech).count / 2)
            let data = Data(#"{"text":"Ready."}"#.utf8)
            return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
        }

        let text = try await RemoteTranscriptionClient(apiKey: "test-key", session: session)
            .transcribe(samples: speech, model: "gpt-4o-transcribe")
        XCTAssertEqual(text, "Ready.")
    }

    func testPrewarmSendsOneCredentialFreeHEADPerClient() async throws {
        let heads = expectation(description: "One HEAD per client")
        heads.expectedFulfillmentCount = 3
        heads.assertForOverFulfill = true
        let hosts = HostRecorder()
        ProModeURLProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            XCTAssertEqual(request.httpMethod, "HEAD")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertNil(request.value(forHTTPHeaderField: "x-goog-api-key"))
            hosts.record(url.absoluteString)
            heads.fulfill()
            return (HTTPURLResponse(url: url, statusCode: 405, httpVersion: nil, headerFields: nil)!, Data())
        }

        let gemini = GeminiTranscriptionClient(apiKey: "secret", session: session)
        let transcription = RemoteTranscriptionClient(apiKey: "secret", session: session)
        let cleanup = OpenAITextClient(apiKey: "secret", session: session)
        for _ in 0..<3 {
            // Repeated warm-ups while the connection is open are ignored.
            gemini.prewarm()
            transcription.prewarm()
            cleanup.prewarm()
        }
        await fulfillment(of: [heads], timeout: 2)
        XCTAssertEqual(hosts.values, [
            "https://api.openai.com/v1/audio/transcriptions",
            "https://api.openai.com/v1/responses",
            "https://generativelanguage.googleapis.com/v1beta/interactions",
        ])
    }
}

private final class HostRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded = [String]()

    func record(_ value: String) {
        lock.lock()
        recorded.append(value)
        lock.unlock()
    }

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recorded.sorted()
    }
}
