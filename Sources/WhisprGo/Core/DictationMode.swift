import Foundation

enum DictationMode: String, CaseIterable, Identifiable, Sendable {
    case fast
    case pro

    var id: Self { self }

    var title: String {
        switch self {
        case .fast: return "Fast"
        case .pro: return "Pro"
        }
    }

    var detail: String {
        switch self {
        case .fast:
            return "Types the transcription immediately. No cleanup model or context reading."
        case .pro:
            return "GPT-5.6 Luna removes fillers and false starts, using nearby text when enabled."
        }
    }
}
