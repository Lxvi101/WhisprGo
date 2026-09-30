import Foundation

final class GeminiTranscriptionClient {
    static let model = "gemini-3.5-transcribe"

    private let uploadEndpoint = URL(
        string: "https://generativelanguage.googleapis.com/upload/v1beta/files"
    )!
    private let interactionEndpoint = URL(
        string: "https://generativelanguage.googleapis.com/v1beta/interactions"
    )!
    private let filesEndpoint = URL(
        string: "https://generativelanguage.googleapis.com/v1beta/"
    )!
    private let apiKey: String
    private let session: URLSession

    init(apiKey: String, session: URLSession? = nil) {
        self.apiKey = apiKey
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 60
            configuration.timeoutIntervalForResource = 120
            configuration.waitsForConnectivity = false
            configuration.httpMaximumConnectionsPerHost = 1
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(configuration: configuration)
        }
    }

    func transcribe(
        samples: [Float],
        customVocabulary: [String]
    ) async throws -> String {
        let wav = WAVEncoder.encode(samples: samples)
        let file = try await upload(wav)

        do {
            let output = try await createInteraction(
                file: file,
                customVocabulary: Array(customVocabulary.prefix(100))
            )
            await delete(file)
            return output
        } catch {
            await delete(file)
            throw error
        }
    }

    private func upload(_ data: Data) async throws -> GeminiFile {
        var start = URLRequest(url: uploadEndpoint)
        start.httpMethod = "POST"
        start.timeoutInterval = 30
        start.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        start.setValue("resumable", forHTTPHeaderField: "X-Goog-Upload-Protocol")
        start.setValue("start", forHTTPHeaderField: "X-Goog-Upload-Command")
        start.setValue(String(data.count), forHTTPHeaderField: "X-Goog-Upload-Header-Content-Length")
        start.setValue("audio/wav", forHTTPHeaderField: "X-Goog-Upload-Header-Content-Type")
        start.setValue("application/json", forHTTPHeaderField: "Content-Type")
        start.httpBody = try JSONEncoder().encode(
            UploadMetadata(file: .init(displayName: "WhisprGo dictation"))
        )

        let (startData, startResponse) = try await session.data(for: start)
        let startHTTP = try validHTTPResponse(startResponse, data: startData)
        guard let value = startHTTP.value(forHTTPHeaderField: "X-Goog-Upload-URL"),
              let uploadURL = URL(string: value),
              uploadURL.scheme == "https",
              let uploadHost = uploadURL.host,
              uploadHost == "googleapis.com" || uploadHost.hasSuffix(".googleapis.com")
        else {
            throw GeminiTranscriptionError.invalidUploadResponse
        }

        var upload = URLRequest(url: uploadURL)
        upload.httpMethod = "POST"
        upload.timeoutInterval = 60
        upload.setValue(String(data.count), forHTTPHeaderField: "Content-Length")
        upload.setValue("0", forHTTPHeaderField: "X-Goog-Upload-Offset")
        upload.setValue("upload, finalize", forHTTPHeaderField: "X-Goog-Upload-Command")
        upload.httpBody = data

        let (uploadData, uploadResponse) = try await session.data(for: upload)
        _ = try validHTTPResponse(uploadResponse, data: uploadData)
        guard let file = try? JSONDecoder().decode(UploadEnvelope.self, from: uploadData).file,
              !file.name.isEmpty,
              !file.uri.isEmpty
        else {
            throw GeminiTranscriptionError.invalidUploadResponse
        }
        return file
    }

    private func createInteraction(
        file: GeminiFile,
        customVocabulary: [String]
    ) async throws -> String {
        var request = URLRequest(url: interactionEndpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(InteractionRequest(
            model: Self.model,
            input: [.init(type: "audio", uri: file.uri, mimeType: file.mimeType)],
            generationConfig: .init(
                transcriptionConfig: .init(
                    customVocabulary: customVocabulary.isEmpty ? nil : customVocabulary,
                    mode: "smart"
                )
            )
        ))

        let (data, response) = try await session.data(for: request)
        _ = try validHTTPResponse(response, data: data)
        guard let decoded = try? JSONDecoder().decode(InteractionResponse.self, from: data)
        else {
            throw GeminiTranscriptionError.invalidResponse
        }
        if decoded.status == "failed" || decoded.status == "cancelled" {
            throw GeminiTranscriptionError.remote("Google could not complete the transcription.")
        }

        let output = decoded.steps
            .filter { $0.type == "model_output" }
            .flatMap { $0.content ?? [] }
            .filter { $0.type == "text" }
            .compactMap(\.text)
            .joined()
        let cleaned = TextSanitizer.sanitize(output)
        guard !cleaned.isEmpty else {
            throw GeminiTranscriptionError.emptyOutput
        }
        return cleaned
    }

    private func delete(_ file: GeminiFile) async {
        guard !file.name.contains(".."),
              let url = URL(string: file.name, relativeTo: filesEndpoint)?.absoluteURL,
              url.host == filesEndpoint.host
        else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.timeoutInterval = 15
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        _ = try? await session.data(for: request)
    }

    private func validHTTPResponse(_ response: URLResponse, data: Data) throws -> HTTPURLResponse {
        guard let http = response as? HTTPURLResponse else {
            throw GeminiTranscriptionError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(GoogleErrorEnvelope.self, from: data))?
                .error.message
            throw GeminiTranscriptionError.remote(
                message ?? "Google returned HTTP \(http.statusCode)."
            )
        }
        return http
    }
}

enum GeminiVocabulary {
    static func terms(
        profileText: String,
        context: AccessibilityContextSnapshot?
    ) -> [String] {
        var result = [String]()
        var seen = Set<String>()

        func append(_ candidate: String) {
            let value = candidate
                .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            guard (2...100).contains(value.count) else { return }
            let key = value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            guard seen.insert(key).inserted else { return }
            result.append(value)
        }

        profileText
            .components(separatedBy: CharacterSet.newlines.union(CharacterSet(charactersIn: ",;")))
            .forEach(append)

        guard let context, result.count < 100 else {
            return Array(result.prefix(100))
        }

        append(context.applicationName)
        append(context.windowTitle ?? "")

        let text = [
            context.textBeforeCursor,
            context.selectedText,
            context.textAfterCursor,
            context.nearbyText,
        ].joined(separator: "\n")

        for rawToken in text.components(separatedBy: .whitespacesAndNewlines) {
            let token = rawToken.trimmingCharacters(in: .punctuationCharacters)
            guard token.count >= 3 else { continue }
            let scalars = Array(token.unicodeScalars)
            let containsDigit = scalars.contains(where: CharacterSet.decimalDigits.contains)
            let startsUppercase = scalars.first.map(CharacterSet.uppercaseLetters.contains) ?? false
            let containsIdentifierPunctuation = token.rangeOfCharacter(
                from: CharacterSet(charactersIn: "@._/-")
            ) != nil
            let hasInternalUppercase = scalars.dropFirst().contains(
                where: CharacterSet.uppercaseLetters.contains
            )
            if containsDigit || startsUppercase || containsIdentifierPunctuation || hasInternalUppercase {
                append(token)
            }
            if result.count == 100 { break }
        }
        return result
    }
}

private struct UploadMetadata: Encodable {
    struct FileMetadata: Encodable {
        let displayName: String

        enum CodingKeys: String, CodingKey {
            case displayName = "display_name"
        }
    }

    let file: FileMetadata
}

private struct UploadEnvelope: Decodable {
    let file: GeminiFile
}

private struct GeminiFile: Decodable {
    let name: String
    let uri: String
    let mimeType: String
}

private struct InteractionRequest: Encodable {
    struct Input: Encodable {
        let type: String
        let uri: String
        let mimeType: String

        enum CodingKeys: String, CodingKey {
            case type
            case uri
            case mimeType = "mime_type"
        }
    }

    struct GenerationConfig: Encodable {
        struct TranscriptionConfig: Encodable {
            let customVocabulary: [String]?
            let mode: String

            enum CodingKeys: String, CodingKey {
                case customVocabulary = "custom_vocabulary"
                case mode
            }
        }

        let transcriptionConfig: TranscriptionConfig

        enum CodingKeys: String, CodingKey {
            case transcriptionConfig = "transcription_config"
        }
    }

    let model: String
    let input: [Input]
    let generationConfig: GenerationConfig

    enum CodingKeys: String, CodingKey {
        case model
        case input
        case generationConfig = "generation_config"
    }
}

private struct InteractionResponse: Decodable {
    struct Step: Decodable {
        struct Content: Decodable {
            let type: String
            let text: String?
        }

        let type: String
        let content: [Content]?
    }

    let status: String?
    let steps: [Step]
}

private struct GoogleErrorEnvelope: Decodable {
    struct APIError: Decodable { let message: String }
    let error: APIError
}

enum GeminiTranscriptionError: LocalizedError {
    case missingAPIKey
    case invalidUploadResponse
    case invalidResponse
    case emptyOutput
    case remote(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Pro Mode needs a Google API key."
        case .invalidUploadResponse:
            return "Google did not accept the audio upload."
        case .invalidResponse:
            return "Gemini returned an invalid transcription response."
        case .emptyOutput:
            return "Gemini completed the request but returned no transcript."
        case let .remote(message):
            return message
        }
    }
}
