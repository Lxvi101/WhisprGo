import Foundation

/// OpenAI's transcription API, used by the cloud Fast models (on their own
/// and under Instruct Pro). Audio is trimmed, sent as 32 kbps AAC in M4A, and
/// the connection is opened while the user speaks.
final class RemoteTranscriptionClient: @unchecked Sendable {
    static let endpoint = URL(string: "https://api.openai.com/v1/audio/transcriptions")!

    private let apiKey: String
    private let session: URLSession
    private let warmer: ConnectionWarmer

    init(apiKey: String, session: URLSession? = nil) {
        self.apiKey = apiKey
        let session = session ?? {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 45
            configuration.timeoutIntervalForResource = 90
            configuration.waitsForConnectivity = false
            configuration.httpMaximumConnectionsPerHost = 1
            configuration.httpShouldSetCookies = false
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            return URLSession(configuration: configuration)
        }()
        self.session = session
        warmer = ConnectionWarmer(url: Self.endpoint, session: session)
    }

    /// Opens the HTTPS connection ahead of the upload. The HEAD carries no
    /// API key.
    func prewarm() {
        warmer.warm()
    }

    func transcribe(samples: [Float], model: String) async throws -> String {
        let speech = SpeechTrimmer.trim(samples)
        let audio = (try? CompressedAudioEncoder.encodeM4A(samples: speech))
            ?? CompressedAudioEncoder.wav(samples: speech)
        try Task.checkCancellation()
        let boundary = "WhisprGo-\(UUID().uuidString)"
        let body = Self.multipartBody(boundary: boundary, model: model, audio: audio)

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type"
        )

        let (data, response) = try await session.upload(for: request, from: body)
        guard let http = response as? HTTPURLResponse else {
            throw TranscriptionError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(APIErrorEnvelope.self, from: data))?
                .error.message
            throw TranscriptionError.remote(
                message ?? "OpenAI returned HTTP \(http.statusCode)."
            )
        }

        let decoded = try JSONDecoder().decode(TranscriptionResponse.self, from: data)
        return TextSanitizer.sanitize(decoded.text)
    }

    static func multipartBody(
        boundary: String,
        model: String,
        audio: CompressedAudioEncoder.Encoded
    ) -> Data {
        var body = Data()
        body.reserveCapacity(audio.data.count + 512)

        appendField(name: "model", value: model, boundary: boundary, to: &body)
        appendField(name: "response_format", value: "json", boundary: boundary, to: &body)
        body.append(contentsOf: "--\(boundary)\r\n".utf8)
        body.append(
            contentsOf: "Content-Disposition: form-data; name=\"file\"; filename=\"dictation.\(audio.fileExtension)\"\r\n".utf8
        )
        body.append(contentsOf: "Content-Type: \(audio.contentType)\r\n\r\n".utf8)
        body.append(audio.data)
        body.append(contentsOf: "\r\n--\(boundary)--\r\n".utf8)
        return body
    }

    private static func appendField(
        name: String,
        value: String,
        boundary: String,
        to body: inout Data
    ) {
        body.append(contentsOf: "--\(boundary)\r\n".utf8)
        body.append(
            contentsOf: "Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8
        )
        body.append(contentsOf: "\(value)\r\n".utf8)
    }
}

private struct TranscriptionResponse: Decodable {
    let text: String
}

private struct APIErrorEnvelope: Decodable {
    struct APIError: Decodable {
        let message: String
    }

    let error: APIError
}

enum TranscriptionError: LocalizedError {
    case invalidResponse
    case missingAPIKey
    case modelNotReady
    case remote(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "The transcription service returned an invalid response."
        case .missingAPIKey:
            return "Add an OpenAI API key in Settings first."
        case .modelNotReady:
            return "The selected model is not ready yet."
        case let .remote(message):
            return message
        }
    }
}
