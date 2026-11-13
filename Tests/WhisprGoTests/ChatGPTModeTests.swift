import CoreGraphics
import Foundation
import XCTest
@testable import WhisprGo

final class ChatGPTModeTests: XCTestCase {
    override func tearDown() {
        ChatGPTStubProtocol.handler = nil
        super.tearDown()
    }

    // MARK: Credentials

    func testCredentialsReadAccountEmailPlanAndExpiryFromTokens() throws {
        let expiry = Date(timeIntervalSince1970: 2_000_000_000)
        let access = jwt([
            "exp": expiry.timeIntervalSince1970,
            ChatGPTJWT.authClaim: ["chatgpt_account_id": "acct-access", "chatgpt_plan_type": "plus"],
        ])
        let id = jwt([
            "email": "levi@example.com",
            ChatGPTJWT.authClaim: ["chatgpt_account_id": "acct-id"],
        ])

        let credentials = try XCTUnwrap(ChatGPTCredentials.make(
            accessToken: access,
            refreshToken: "refresh",
            idToken: id
        ))

        XCTAssertEqual(credentials.accountID, "acct-id")
        XCTAssertEqual(credentials.email, "levi@example.com")
        XCTAssertEqual(credentials.planType, "plus")
        XCTAssertEqual(credentials.expiresAt, expiry)
        XCTAssertEqual(ChatGPTAccountSummary(credentials).planTitle, "Plus")
        XCTAssertTrue(credentials.expires(within: 60, now: expiry.addingTimeInterval(-30)))
        XCTAssertFalse(credentials.expires(within: 60, now: expiry.addingTimeInterval(-600)))
    }

    func testRefreshResponseKeepsPreviousRefreshTokenWhenNotRotated() throws {
        let previous = try XCTUnwrap(ChatGPTCredentials.make(
            accessToken: jwt([ChatGPTJWT.authClaim: ["chatgpt_account_id": "acct"]]),
            refreshToken: "original",
            idToken: jwt(["email": "a@b.c"])
        ))
        let renewed = try XCTUnwrap(ChatGPTCredentials.make(
            accessToken: jwt(["exp": 1.0]),
            refreshToken: nil,
            idToken: nil,
            previous: previous
        ))
        XCTAssertEqual(renewed.refreshToken, "original")
        XCTAssertEqual(renewed.accountID, "acct")
        XCTAssertEqual(renewed.email, "a@b.c")
    }

    func testCredentialsWithoutAnAccountAreRejected() {
        XCTAssertNil(ChatGPTCredentials.make(accessToken: jwt([:]), refreshToken: "r", idToken: nil))
        XCTAssertNil(ChatGPTCredentials.make(accessToken: "not-a-jwt", refreshToken: "r", idToken: nil))
    }

    // MARK: OAuth

    func testPKCEChallengeMatchesRFC7636Example() {
        let pkce = ChatGPTOAuth.PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        XCTAssertEqual(pkce.challenge, "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        XCTAssertGreaterThanOrEqual(ChatGPTOAuth.PKCE().verifier.count, 43)
    }

    func testAuthorizeURLCarriesPKCEStateAndLoopbackRedirect() throws {
        let pkce = ChatGPTOAuth.PKCE(verifier: "verifier-verifier-verifier-verifier-verifier")
        let url = ChatGPTOAuth.authorizeURL(pkce: pkce, state: "state-1")
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })

        XCTAssertEqual(components.host, "auth.openai.com")
        XCTAssertEqual(components.path, "/oauth/authorize")
        XCTAssertEqual(items["client_id"], ChatGPTOAuth.clientID)
        XCTAssertEqual(items["redirect_uri"], "http://localhost:1455/auth/callback")
        XCTAssertEqual(items["code_challenge"], pkce.challenge)
        XCTAssertEqual(items["code_challenge_method"], "S256")
        XCTAssertEqual(items["state"], "state-1")
        XCTAssertTrue(items["scope"]?.contains("offline_access") == true)
    }

    func testFormEncodingEscapesReservedCharacters() {
        let body = String(decoding: ChatGPTOAuth.formEncoded([
            "redirect_uri": "http://localhost:1455/auth/callback",
            "code": "a+b&c=d",
        ]), as: UTF8.self)
        XCTAssertEqual(body, "code=a%2Bb%26c%3Dd&redirect_uri=http%3A%2F%2Flocalhost%3A1455%2Fauth%2Fcallback")
    }

    func testLoopbackServerDeliversCallbackAndAnswersBrowser() async throws {
        XCTAssertEqual(ChatGPTLoopbackServer.requestTarget("GET /auth/callback?code=x HTTP/1.1"), "/auth/callback?code=x")
        XCTAssertNil(ChatGPTLoopbackServer.requestTarget("POST /auth/callback HTTP/1.1"))

        let port = UInt16.random(in: 40_000...49_000)
        let server = ChatGPTLoopbackServer(port: port, path: "/auth/callback")
        try await server.start()
        defer { server.stop() }

        let browser = Task {
            try await URLSession(configuration: .ephemeral).data(
                from: URL(string: "http://127.0.0.1:\(port)/auth/callback?code=abc&state=xyz")!
            )
        }
        let callback = try await server.nextCallback()
        XCTAssertEqual(callback.parameters["code"], "abc")
        XCTAssertEqual(callback.parameters["state"], "xyz")
        callback.respond(.success)

        let (data, response) = try await browser.value
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("Signed in to WhisprGo"))
    }

    // MARK: Auth renewal

    func testConcurrentRenewalsShareOneRefreshRequest() async throws {
        let store = MemoryCredentialStore(try expiringCredentials())
        let counter = RequestCounter()
        ChatGPTStubProtocol.handler = { request in
            XCTAssertEqual(request.url, ChatGPTOAuth.tokenEndpoint)
            counter.increment()
            Thread.sleep(forTimeInterval: 0.05)
            return Self.json(200, [
                "access_token": self.jwt([
                    "exp": Date().addingTimeInterval(3_600).timeIntervalSince1970,
                    ChatGPTJWT.authClaim: ["chatgpt_account_id": "acct"],
                ]),
                "refresh_token": "rotated",
            ])
        }
        let auth = ChatGPTAuth(store: store, session: stubSession())

        async let first = auth.validCredentials()
        async let second = auth.validCredentials()
        let results = try await [first, second]

        XCTAssertEqual(counter.value, 1)
        XCTAssertEqual(results.map(\.refreshToken), ["rotated", "rotated"])
        XCTAssertEqual(store.saved?.refreshToken, "rotated")
    }

    func testRejectedRefreshSignsOut() async throws {
        let store = MemoryCredentialStore(try expiringCredentials())
        ChatGPTStubProtocol.handler = { _ in Self.json(401, ["error": "refresh_token_reused"]) }
        let auth = ChatGPTAuth(store: store, session: stubSession())

        do {
            _ = try await auth.validCredentials()
            XCTFail("Expected the expired session to require sign-in")
        } catch let error as ChatGPTError {
            XCTAssertEqual(error, .sessionExpired)
        }
        XCTAssertTrue(store.deleted)
        let account = await auth.account
        XCTAssertNil(account)
    }

    // MARK: Transcription

    func testTranscriptionUploadsCompressedAudioWithAccountHeaders() async throws {
        let credentials = try freshCredentials()
        let auth = ChatGPTAuth(store: MemoryCredentialStore(credentials), session: stubSession())
        var captured: URLRequest?
        var body = Data()
        ChatGPTStubProtocol.handler = { request in
            captured = request
            body = try ProModeURLProtocol.body(for: request)
            return Self.json(200, ["text": "  Ship it on Friday.  "])
        }
        let client = ChatGPTTranscriptionClient(auth: auth, configuration: stubConfiguration())

        let text = try await client.transcribe(samples: speechSamples(seconds: 2))

        XCTAssertEqual(text, "Ship it on Friday.")
        let request = try XCTUnwrap(captured)
        XCTAssertEqual(request.url, ChatGPTTranscriptionClient.endpoint)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(credentials.accessToken)")
        XCTAssertEqual(request.value(forHTTPHeaderField: "ChatGPT-Account-Id"), "acct")
        let prefix = String(decoding: body.prefix(400), as: UTF8.self)
        XCTAssertTrue(prefix.contains("filename=\"dictation.m4a\""))
        XCTAssertTrue(prefix.contains("Content-Type: audio/mp4"))
        XCTAssertLessThan(body.count, 2 * WAVEncoder.sampleRate * 2 / 2, "AAC should be far smaller than WAV")
    }

    func testRejectedTokenIsRenewedAndTheUploadRetriedOnce() async throws {
        let auth = ChatGPTAuth(store: MemoryCredentialStore(try freshCredentials()), session: stubSession())
        let uploads = RequestCounter()
        ChatGPTStubProtocol.handler = { request in
            if request.url == ChatGPTOAuth.tokenEndpoint {
                return Self.json(200, [
                    "access_token": self.jwt([ChatGPTJWT.authClaim: ["chatgpt_account_id": "acct"], "n": 2]),
                    "refresh_token": "rotated",
                ])
            }
            uploads.increment()
            return uploads.value == 1
                ? Self.json(401, [:])
                : Self.json(200, ["text": "Retried."])
        }
        let client = ChatGPTTranscriptionClient(auth: auth, configuration: stubConfiguration())

        let text = try await client.transcribe(samples: speechSamples(seconds: 1))

        XCTAssertEqual(text, "Retried.")
        XCTAssertEqual(uploads.value, 2)
    }

    func testRateLimitIsReportedClearly() async throws {
        let auth = ChatGPTAuth(store: MemoryCredentialStore(try freshCredentials()), session: stubSession())
        ChatGPTStubProtocol.handler = { _ in Self.json(429, [:]) }
        let client = ChatGPTTranscriptionClient(auth: auth, configuration: stubConfiguration())

        do {
            _ = try await client.transcribe(samples: speechSamples(seconds: 1))
            XCTFail("Expected a rate-limit error")
        } catch let error as ChatGPTError {
            XCTAssertEqual(error, .service(429))
            XCTAssertTrue(error.localizedDescription.contains("limit"))
        }
    }

    func testSignedOutTranscriptionAsksForSignIn() async {
        let auth = ChatGPTAuth(store: MemoryCredentialStore(nil), session: stubSession())
        let client = ChatGPTTranscriptionClient(auth: auth, configuration: stubConfiguration())
        do {
            _ = try await client.transcribe(samples: speechSamples(seconds: 1))
            XCTFail("Expected sign-in to be required")
        } catch {
            XCTAssertEqual(error as? ChatGPTError, .signInRequired)
        }
    }

    // MARK: Audio

    func testAACEncodingProducesSmallM4A() throws {
        let samples = speechSamples(seconds: 5)
        let encoded = try CompressedAudioEncoder.encodeM4A(samples: samples)
        XCTAssertEqual(encoded.fileExtension, "m4a")
        XCTAssertEqual(String(decoding: encoded.data[4..<8], as: UTF8.self), "ftyp")
        XCTAssertLessThan(encoded.data.count, WAVEncoder.encode(samples: samples).count / 4)
    }

    func testSilenceIsTrimmedAroundSpeechWithPadding() {
        let rate = WAVEncoder.sampleRate
        let silence = [Float](repeating: 0.0002, count: rate * 2)
        let speech = speechSamples(seconds: 1)
        let trimmed = SpeechTrimmer.trim(silence + speech + silence)

        let expectedMinimum = speech.count
        let expectedMaximum = speech.count + Int(Double(rate) * (SpeechTrimmer.leadingPadding + SpeechTrimmer.trailingPadding)) + SpeechTrimmer.frameLength * 2
        XCTAssertGreaterThanOrEqual(trimmed.count, expectedMinimum)
        XCTAssertLessThanOrEqual(trimmed.count, expectedMaximum)
    }

    func testTrimmingKeepsRecordingsWithoutClearSilence() {
        let speech = speechSamples(seconds: 1)
        XCTAssertEqual(SpeechTrimmer.trim(speech).count, speech.count)
        let silent = [Float](repeating: 0, count: WAVEncoder.sampleRate)
        XCTAssertEqual(SpeechTrimmer.trim(silent).count, silent.count)
    }

    // MARK: Delivery

    @MainActor
    func testPasteOnlyGoesToTheAppStillInFront() {
        XCTAssertNil(TextInjector.pasteDecision(targetProcess: 42, frontmostProcess: 42))
        XCTAssertEqual(TextInjector.pasteDecision(targetProcess: 42, frontmostProcess: 7), .targetChanged)
        XCTAssertEqual(TextInjector.pasteDecision(targetProcess: 42, frontmostProcess: nil), .targetChanged)
    }

    @MainActor
    func testEveryDeliveryOutcomeTellsTheUserWhereTheTextWent() {
        XCTAssertEqual(TextInjector.Result.inserted(appName: "Notes").notice, "Inserted into Notes")
        XCTAssertEqual(TextInjector.Result.pasted(appName: "Slack").notice, "Pasted into Slack")
        XCTAssertEqual(TextInjector.Result.pasted(appName: nil).notice, "Pasted")
        for reason in [TextInjector.CopyReason.accessibilityMissing, .noTarget, .targetChanged, .pasteFailed] {
            let result = TextInjector.Result.copied(reason)
            XCTAssertTrue(result.isManualPaste)
            XCTAssertTrue(result.notice?.hasPrefix("Copied") == true)
            XCTAssertNil(result.errorMessage)
        }
        XCTAssertNil(TextInjector.Result.ignored.notice)
    }

    // MARK: Mode shortcut

    func testModifierOnlyModeSwitchRequiresDoubleTap() {
        let configuration = HotkeyConfiguration.default
        XCTAssertTrue(HotkeyAction.toggleMode.requiresDoubleTap(configuration.toggleMode))
        XCTAssertFalse(HotkeyAction.toggleMode.requiresDoubleTap(.key(46, modifiers: [.control, .option])))
        XCTAssertFalse(HotkeyAction.cycleProfile.requiresDoubleTap(configuration.cycleProfile))
        XCTAssertFalse(HotkeyAction.pushToTalk.requiresDoubleTap(configuration.pushToTalk))
    }

    func testDoubleTapGateFiresOnlyOnASecondQuickTap() {
        var gate = DoubleTapGate()
        XCTAssertFalse(gate.registerTap(at: 10.0))
        XCTAssertTrue(gate.registerTap(at: 10.3))
        // The pair was consumed; the next tap starts over.
        XCTAssertFalse(gate.registerTap(at: 10.5))
        // Too slow: the late tap re-arms instead of firing.
        XCTAssertFalse(gate.registerTap(at: 11.5))
        XCTAssertTrue(gate.registerTap(at: 11.8))
        // Typing between taps resets.
        XCTAssertFalse(gate.registerTap(at: 20.0))
        gate.reset()
        XCTAssertFalse(gate.registerTap(at: 20.2))
    }

    // MARK: Helpers

    private func jwt(_ payload: [String: Any]) -> String {
        let header = ChatGPTOAuth.base64URL(Data(#"{"alg":"none"}"#.utf8))
        let body = ChatGPTOAuth.base64URL(try! JSONSerialization.data(withJSONObject: payload))
        return "\(header).\(body).signature"
    }

    private func freshCredentials() throws -> ChatGPTCredentials {
        try XCTUnwrap(ChatGPTCredentials.make(
            accessToken: jwt([
                "exp": Date().addingTimeInterval(86_400).timeIntervalSince1970,
                ChatGPTJWT.authClaim: ["chatgpt_account_id": "acct"],
            ]),
            refreshToken: "refresh",
            idToken: nil
        ))
    }

    private func expiringCredentials() throws -> ChatGPTCredentials {
        try XCTUnwrap(ChatGPTCredentials.make(
            accessToken: jwt([
                "exp": Date().addingTimeInterval(30).timeIntervalSince1970,
                ChatGPTJWT.authClaim: ["chatgpt_account_id": "acct"],
            ]),
            refreshToken: "refresh",
            idToken: nil
        ))
    }

    private func speechSamples(seconds: Double) -> [Float] {
        let rate = Double(WAVEncoder.sampleRate)
        return (0..<Int(seconds * rate)).map { index in
            let time = Double(index) / rate
            let envelope = 0.5 + 0.5 * sin(2 * .pi * 3 * time)
            return Float(0.3 * envelope * (sin(2 * .pi * 220 * time) + 0.5 * sin(2 * .pi * 440 * time)))
        }
    }

    private func stubConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ChatGPTStubProtocol.self]
        return configuration
    }

    private func stubSession() -> URLSession {
        URLSession(configuration: stubConfiguration())
    }

    private static func json(_ status: Int, _ object: [String: Any]) -> (HTTPURLResponse, Data) {
        (
            HTTPURLResponse(url: ChatGPTTranscriptionClient.endpoint, statusCode: status, httpVersion: nil, headerFields: nil)!,
            try! JSONSerialization.data(withJSONObject: object)
        )
    }
}

private final class MemoryCredentialStore: ChatGPTCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: ChatGPTCredentials?
    private(set) var saved: ChatGPTCredentials?
    private(set) var deleted = false

    init(_ value: ChatGPTCredentials?) { self.value = value }

    func load() -> ChatGPTCredentials? { lock.withLock { value } }

    func save(_ credentials: ChatGPTCredentials) throws {
        lock.withLock {
            value = credentials
            saved = credentials
        }
    }

    func delete() throws {
        lock.withLock {
            value = nil
            deleted = true
        }
    }
}

final class RequestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }

    func increment() { lock.withLock { count += 1 } }
}

final class ChatGPTStubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw URLError(.badServerResponse) }
            if request.httpMethod == "HEAD" {
                let response = HTTPURLResponse(url: request.url!, statusCode: 405, httpVersion: nil, headerFields: nil)!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocolDidFinishLoading(self)
                return
            }
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
