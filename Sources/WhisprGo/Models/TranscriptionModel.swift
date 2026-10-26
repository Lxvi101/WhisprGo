import Foundation

enum TranscriptionBackend: Hashable, Sendable {
    case localPhonon(PhononVariant, sizeMB: Int)
    case localParakeet(sizeMB: Int)
    case localWhisper(variant: String, sizeMB: Int)
    case openAI(model: String)
}

enum ModelTier: Hashable, Sendable {
    /// The current on-device generation, shown first.
    case featured
    /// Older on-device engines, still supported for existing setups.
    case legacy
    case cloud
}

struct TranscriptionModel: Identifiable, Hashable, Sendable {
    /// Benchmark facts shown on featured model cards.
    struct Highlights: Hashable, Sendable {
        let languageCount: Int
        /// Average word error rate on the Open ASR Leaderboard's seven
        /// English test sets, in percent (lower is better).
        let englishWordErrorRate: Double
        let tagline: String
    }

    let id: String
    let name: String
    let detail: String
    let backend: TranscriptionBackend
    let languages: String
    let speed: String
    let tier: ModelTier
    var highlights: Highlights? = nil

    var isLocal: Bool {
        switch backend {
        case .localPhonon, .localParakeet, .localWhisper:
            return true
        case .openAI:
            return false
        }
    }

    var providerName: String {
        switch backend {
        case .localPhonon, .localParakeet, .localWhisper:
            return "On device"
        case .openAI:
            return "OpenAI"
        }
    }

    var sizeLabel: String? {
        let sizeMB: Int
        switch backend {
        case let .localPhonon(_, size), let .localParakeet(size), let .localWhisper(_, size):
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
    static let defaultModelID = "local.phonon.2.5"

    static let all: [TranscriptionModel] = [
        TranscriptionModel(
            id: "local.phonon.2.5",
            name: "Phonon 2.5",
            detail: "Accurate dictation in 25 languages, on device",
            backend: .localPhonon(.multilingual, sizeMB: 163),
            languages: "25 European languages",
            speed: "Very fast",
            tier: .featured,
            highlights: .init(
                languageCount: 25,
                englishWordErrorRate: 5.06,
                tagline: "Best all-rounder"
            )
        ),
        TranscriptionModel(
            id: "local.phonon.2.5.en",
            name: "Phonon 2.5 English",
            detail: "The most accurate on-device model for English",
            backend: .localPhonon(.english, sizeMB: 164),
            languages: "English",
            speed: "Very fast",
            tier: .featured,
            highlights: .init(
                languageCount: 1,
                englishWordErrorRate: 4.82,
                tagline: "Sharpest English"
            )
        ),
        TranscriptionModel(
            id: "local.parakeet.v3",
            name: "Parakeet TDT 0.6B v3",
            detail: "The previous default, on Core ML",
            backend: .localParakeet(sizeMB: 483),
            languages: "25 European languages",
            speed: "Ultra fast",
            tier: .legacy
        ),
        TranscriptionModel(
            id: "local.tiny.en",
            name: "Whisper Tiny English",
            detail: "Smallest footprint and fastest response",
            backend: .localWhisper(variant: "openai_whisper-tiny.en", sizeMB: 75),
            languages: "English",
            speed: "Fastest",
            tier: .legacy
        ),
        TranscriptionModel(
            id: "local.base.en",
            name: "Whisper Base English",
            detail: "The best everyday speed and memory balance",
            backend: .localWhisper(variant: "openai_whisper-base.en", sizeMB: 145),
            languages: "English",
            speed: "Very fast",
            tier: .legacy
        ),
        TranscriptionModel(
            id: "local.small",
            name: "Whisper Small",
            detail: "More accurate multilingual dictation",
            backend: .localWhisper(variant: "openai_whisper-small", sizeMB: 488),
            languages: "Multilingual",
            speed: "Fast",
            tier: .legacy
        ),
        TranscriptionModel(
            id: "local.large.turbo",
            name: "Whisper Large v3 Turbo",
            detail: "Highest Whisper accuracy with a larger memory cost",
            backend: .localWhisper(
                variant: "openai_whisper-large-v3-v20240930_turbo_632MB",
                sizeMB: 632
            ),
            languages: "Multilingual",
            speed: "Balanced",
            tier: .legacy
        ),
        TranscriptionModel(
            id: "openai.gpt-transcribe",
            name: "GPT Transcribe",
            detail: "OpenAI's recommended file transcription model",
            backend: .openAI(model: "gpt-transcribe"),
            languages: "Multilingual",
            speed: "Cloud",
            tier: .cloud
        ),
        TranscriptionModel(
            id: "openai.gpt-4o-mini-transcribe",
            name: "GPT-4o Mini Transcribe",
            detail: "A compact API-backed transcription option",
            backend: .openAI(model: "gpt-4o-mini-transcribe"),
            languages: "Multilingual",
            speed: "Cloud",
            tier: .cloud
        ),
        TranscriptionModel(
            id: "openai.whisper-1",
            name: "Whisper API",
            detail: "Compatibility model for existing OpenAI accounts",
            backend: .openAI(model: "whisper-1"),
            languages: "Multilingual",
            speed: "Cloud",
            tier: .cloud
        ),
    ]

    static let featured = all.filter { $0.tier == .featured }
    static let legacy = all.filter { $0.tier == .legacy }
    static let local = all.filter(\.isLocal)
    static let cloud = all.filter { $0.tier == .cloud }

    static func model(id: String) -> TranscriptionModel {
        all.first { $0.id == id }
            ?? all.first { $0.id == defaultModelID }
            ?? all[0]
    }
}
