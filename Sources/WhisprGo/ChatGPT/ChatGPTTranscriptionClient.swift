import Foundation

/// Transcribes dictation with the signed-in ChatGPT account.
///
/// Latency work, in order of impact:
/// - Audio is uploaded as 32 kbps AAC instead of WAV (about 7.5× smaller).
/// - Silence before and after speech is trimmed before encoding.
/// - `prewarm()` opens the TLS connection while the user is still speaking,
///   and the same session reuses it for the upload.
/// - Tokens stay in memory and are renewed ahead of expiry, never inline
///   unless the server rejects one.
final class ChatGPTTranscriptionClient: @unchecked Sendable {
    static let endpoint = URL(string: "https://chatgpt.com/backend-api/transcribe")!
    static let modelIdentifier = "chatgpt.transcribe"
    static let displayName = "ChatGPT Transcribe"

    private let session: URLSession
    private let auth: ChatGPTAuth
    private let warmer: ConnectionWarmer

    init(auth: ChatGPTAuth = .shared, configuration: URLSessionConfiguration? = nil) {
        self.auth = auth
        let configuration = configuration ?? {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 60
            configuration.timeoutIntervalForResource = 120
            configuration.httpShouldSetCookies = false
            configuration.httpCookieAcceptPolicy = .never
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.waitsForConnectivity = false
            configuration.httpMaximumConnectionsPerHost = 2
            return configuration
        }()
        session = URLSession(
            configuration: configuration,
            delegate: ChatGPTNoRedirectDelegate(),
            delegateQueue: nil
        )
        warmer = ConnectionWarmer(url: Self.endpoint, session: session)
    }

    /// Opens the HTTPS connection ahead of the upload (the server answers the
    /// credential-free HEAD with 405).
    func prewarm() {
        warmer.warm()
    }

    func transcribe(samples: [Float]) async throws -> String {
        let speech = SpeechTrimmer.trim(samples)
        let audio = (try? CompressedAudioEncoder.encodeM4A(samples: speech))
            ?? CompressedAudioEncoder.wav(samples: speech)
        try Task.checkCancellation()
        let body = Self.multipartBody(audio: audio, boundary: Self.boundary)

        let credentials = try await auth.validCredentials()
        do {
            return try await send(body, credentials: credentials)
        } catch ChatGPTError.service(401) {
            try Task.checkCancellation()
            let renewed = try await auth.credentials(afterRejecting: credentials.accessToken)
            return try await send(body, credentials: renewed)
        }
    }

    private func send(_ body: Data, credentials: ChatGPTCredentials) async throws -> String {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(credentials.accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        request.setValue(
            "multipart/form-data; boundary=\(Self.boundary)",
            forHTTPHeaderField: "Content-Type"
        )
        request.setValue("WhisprGo", forHTTPHeaderField: "User-Agent")
        request.setValue("codex_dictation", forHTTPHeaderField: "originator")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.upload(for: request, from: body)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw ChatGPTError.unreachable
        }

        guard let http = response as? HTTPURLResponse else { throw ChatGPTError.invalidResponse }
        guard http.statusCode == 200 else { throw ChatGPTError.service(http.statusCode) }
        guard let payload = try? JSONDecoder().decode(Response.self, from: data) else {
            throw ChatGPTError.invalidResponse
        }
        return TextSanitizer.sanitize(payload.text)
    }

    static let boundary = "WhisprGo-ChatGPT-\(UUID().uuidString)"

    static func multipartBody(
        audio: CompressedAudioEncoder.Encoded,
        boundary: String
    ) -> Data {
        var body = Data()
        body.reserveCapacity(audio.data.count + 256)
        body.append(contentsOf: "--\(boundary)\r\n".utf8)
        body.append(contentsOf: "Content-Disposition: form-data; name=\"file\"; filename=\"dictation.\(audio.fileExtension)\"\r\n".utf8)
        body.append(contentsOf: "Content-Type: \(audio.contentType)\r\n\r\n".utf8)
        body.append(audio.data)
        body.append(contentsOf: "\r\n--\(boundary)--\r\n".utf8)
        return body
    }

    private struct Response: Decodable {
        let text: String
    }
}

/// Bearer tokens must never follow a redirect to another host.
private final class ChatGPTNoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
