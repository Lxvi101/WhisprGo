import Foundation
import XCTest
@testable import WhisprGo

final class GeminiCleanupTests: XCTestCase {
    func testFinishedTextDoesNotWaitForDeletionResponse() async throws {
        try await checkDelivery(failInteraction: false)
    }

    func testFailedTranscriptionStillDeletesWithoutDelayingError() async throws {
        try await checkDelivery(failInteraction: true)
    }

    private func checkDelivery(failInteraction: Bool) async throws {
        let deletionStarted = expectation(description: "Deletion requested")
        let delivered = expectation(description: "Result delivered before deletion response")
        let server = GeminiCleanupServer(failInteraction: failInteraction) {
            deletionStarted.fulfill()
        }
        GeminiCleanupURLProtocol.server = server
        defer { GeminiCleanupURLProtocol.server = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GeminiCleanupURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let task = Task {
            defer { delivered.fulfill() }
            return try await GeminiTranscriptionClient(apiKey: "test", session: session)
                .transcribe(samples: [0.1, -0.1], customVocabulary: [])
        }
        // The mock deliberately withholds DELETE's response. This fails if
        // either finished text or the error is blocked on remote cleanup.
        await fulfillment(of: [deletionStarted, delivered], timeout: 2)
        server.finishDeletion()
        do {
            let text = try await task.value
            XCTAssertFalse(failInteraction)
            XCTAssertEqual(text, "Ready.")
        } catch {
            XCTAssertTrue(failInteraction, "Unexpected error: \(error)")
        }
    }
}

private final class GeminiCleanupServer: @unchecked Sendable {
    let failInteraction: Bool
    let onDeletion: () -> Void
    private let lock = NSLock()
    private var pendingDeletion: GeminiCleanupURLProtocol?

    init(failInteraction: Bool, onDeletion: @escaping () -> Void) {
        self.failInteraction = failInteraction
        self.onDeletion = onDeletion
    }

    func holdDeletion(_ request: GeminiCleanupURLProtocol) {
        lock.lock()
        pendingDeletion = request
        lock.unlock()
        onDeletion()
    }

    func finishDeletion() {
        lock.lock()
        let pending = pendingDeletion
        pendingDeletion = nil
        lock.unlock()
        pending?.respond("{}")
    }
}

private final class GeminiCleanupURLProtocol: URLProtocol, @unchecked Sendable {
    static var server: GeminiCleanupServer?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let server = Self.server, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        switch url.path {
        case "/upload/v1beta/files":
            respond("{}", headers: [
                "X-Goog-Upload-URL": "https://generativelanguage.googleapis.com/upload-session/test"
            ])
        case "/upload-session/test":
            respond(#"{"file":{"name":"files/test","uri":"https://generativelanguage.googleapis.com/v1beta/files/test","mimeType":"audio/wav"}}"#)
        case "/v1beta/interactions":
            if server.failInteraction {
                respond(#"{"error":{"message":"Unavailable"}}"#, status: 503)
            } else {
                respond(#"{"status":"completed","steps":[{"type":"model_output","content":[{"type":"text","text":"Ready."}]}]}"#)
            }
        case "/v1beta/files/test":
            XCTAssertEqual(request.httpMethod, "DELETE")
            server.holdDeletion(self)
        default:
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
        }
    }

    func respond(_ json: String, status: Int = 200, headers: [String: String] = [:]) {
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)
        else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
