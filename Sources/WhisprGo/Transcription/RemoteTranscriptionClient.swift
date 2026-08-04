import Foundation

final class RemoteTranscriptionClient {
    private let endpoint = URL(string: "https://api.openai.com/v1/audio/transcriptions")!
    private let apiKey: String
    private let session: URLSession

    init(apiKey: String) {
        self.apiKey = apiKey

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 45
        configuration.timeoutIntervalForResource = 90
        configuration.waitsForConnectivity = false
        configuration.httpMaximumConnectionsPerHost = 1
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: configuration)
    }

    func transcribe(samples: [Float], model: String) async throws -> String {
        let boundary = "WhisprGo-\(UUID().uuidString)"
        let body = multipartBody(
            boundary: boundary,
            model: model,
            wav: WAVEncoder.encode(samples: samples)
        )

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type"
        )
        request.httpBody = body

        let (data, response) = try await session.data(for: request)
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

    private func multipartBody(boundary: String, model: String, wav: Data) -> Data {
        var body = Data()
        body.reserveCapacity(wav.count + 512)

        appendField(name: "model", value: model, boundary: boundary, to: &body)
        appendField(name: "response_format", value: "json", boundary: boundary, to: &body)
        body.append(contentsOf: "--\(boundary)\r\n".utf8)
        body.append(
            contentsOf: "Content-Disposition: form-data; name=\"file\"; filename=\"dictation.wav\"\r\n".utf8
        )
        body.append(contentsOf: "Content-Type: audio/wav\r\n\r\n".utf8)
        body.append(wav)
        body.append(contentsOf: "\r\n--\(boundary)--\r\n".utf8)
        return body
    }

    private func appendField(
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
