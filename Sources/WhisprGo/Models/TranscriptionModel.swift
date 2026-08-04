import Foundation

enum TranscriptionBackend: Hashable, Sendable {
    case localParakeet(sizeMB: Int)
    case localWhisper(variant: String, sizeMB: Int)
    case openAI(model: String)
}

struct TranscriptionModel: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let detail: String
    let backend: TranscriptionBackend
    let languages: String
    let speed: String
    let recommended: Bool

    var isLocal: Bool {
        switch backend {
        case .localParakeet, .localWhisper:
            return true
        case .openAI:
            return false
        }
    }

    var providerName: String {
        switch backend {
        case .localParakeet, .localWhisper:
            return "On device"
        case .openAI:
            return "OpenAI"
        }
    }

    var sizeLabel: String? {
        let sizeMB: Int
        switch backend {
        case let .localParakeet(size), let .localWhisper(_, size):
            sizeMB = size
        case .openAI:
            return nil
        }
        return sizeMB >= 1_000
            ? String(format: "%.1f GB", Double(sizeMB) / 1_000)
            : "\(sizeMB) MB"
    }
}

enum ModelCatalog {
    static let defaultModelID = "local.parakeet.v3"

    static let all: [TranscriptionModel] = [
        TranscriptionModel(
            id: "local.parakeet.v3",
            name: "Parakeet TDT 0.6B v3",
            detail: "Ultra-fast multilingual dictation on Apple silicon",
            backend: .localParakeet(sizeMB: 483),
            languages: "25 European languages",
            speed: "Ultra fast",
            recommended: true
        ),
        TranscriptionModel(
            id: "local.tiny.en",
            name: "Whisper Tiny English",
            detail: "Smallest footprint and fastest response",
            backend: .localWhisper(variant: "openai_whisper-tiny.en", sizeMB: 75),
            languages: "English",
            speed: "Fastest",
            recommended: false
        ),
        TranscriptionModel(
            id: "local.base.en",
            name: "Whisper Base English",
            detail: "The best everyday speed and memory balance",
            backend: .localWhisper(variant: "openai_whisper-base.en", sizeMB: 145),
            languages: "English",
            speed: "Very fast",
            recommended: false
        ),
        TranscriptionModel(
            id: "local.small",
            name: "Whisper Small",
            detail: "More accurate multilingual dictation",
            backend: .localWhisper(variant: "openai_whisper-small", sizeMB: 488),
            languages: "Multilingual",
            speed: "Fast",
            recommended: false
        ),
        TranscriptionModel(
            id: "local.large.turbo",
            name: "Whisper Large v3 Turbo",
            detail: "Highest local accuracy with a larger memory cost",
            backend: .localWhisper(
                variant: "openai_whisper-large-v3-v20240930_turbo_632MB",
                sizeMB: 632
            ),
            languages: "Multilingual",
            speed: "Balanced",
            recommended: false
        ),
        TranscriptionModel(
            id: "openai.gpt-transcribe",
            name: "GPT Transcribe",
            detail: "OpenAI's recommended file transcription model",
            backend: .openAI(model: "gpt-transcribe"),
            languages: "Multilingual",
            speed: "Cloud",
            recommended: true
        ),
        TranscriptionModel(
            id: "openai.gpt-4o-mini-transcribe",
            name: "GPT-4o Mini Transcribe",
            detail: "A compact API-backed transcription option",
            backend: .openAI(model: "gpt-4o-mini-transcribe"),
            languages: "Multilingual",
            speed: "Cloud",
            recommended: false
        ),
        TranscriptionModel(
            id: "openai.whisper-1",
            name: "Whisper API",
            detail: "Compatibility model for existing OpenAI accounts",
            backend: .openAI(model: "whisper-1"),
            languages: "Multilingual",
            speed: "Cloud",
            recommended: false
        ),
    ]

    static let local = all.filter(\.isLocal)
    static let cloud = all.filter { !$0.isLocal }

    static func model(id: String) -> TranscriptionModel {
        all.first { $0.id == id }
            ?? all.first { $0.id == defaultModelID }
            ?? all[0]
    }
}
